open! Core
open Hardcaml
open Hardcaml_risc_v
open Hardcaml_risc_v_hart
open Hardcaml_uart_controller
open Hardcaml_risc_v_test
open Hardcaml_waveterm
open Opcode_helper
open! Bits

let debug = true
let output_width = 64
let output_height = 35

let uart_config =
  { Hardcaml_uart_controller.Config.clock_frequency = 200
  ; baud_rate = 50
  ; include_parity_bit = true
  ; stop_bits = 1
  }
;;

module Uart_rx = Uart_rx.Make (struct
    let config = uart_config
  end)

module Uart_tx = Uart_tx.Make (struct
    let config = uart_config
  end)

module Cpu_with_dma_memory =
  System.Make
    (struct
      let register_width = Register_width.B32
      let num_registers = 32
    end)
    (struct
      let num_bytes = 65536
    end)
    (struct
      let num_harts = 1
      let include_io_controller = Io_controller_config.Uart_controller uart_config

      let include_video_out =
        Video_config.Video_out
          ( (module struct
              let output_width = 64
              let output_height = 64
              let input_width = 32
              let input_height = 32
              let framebuffer_address = 0x8000
            end : Video_out.Config)
          , (module struct
              (* TODO: Add a clock requirement *)

              let h_active = 64
              let v_active = 64
              let h_fp = 1000
              let h_sync = 10
              let h_bp = 1000
              let v_fp = 1
              let v_sync = 1
              let v_bp = 0
            end : Video_signals.Config) )
      ;;
    end)

module With_transmitter = struct
  module I = struct
    type 'a t =
      { clock : 'a
      ; clear : 'a
      ; data_in_valid : 'a
      ; data_in : 'a [@bits 8]
      }
    [@@deriving sexp_of, hardcaml ~rtlmangle:"$"]
  end

  module O = struct
    type 'a t =
      { data_out_valid : 'a
      ; data_out : 'a [@bits 8]
      ; pixel : 'a
      ; registers : 'a Cpu_with_dma_memory.Registers.t list [@length 1]
      }
    [@@deriving sexp_of, hardcaml ~rtlmangle:"$"]
  end

  let create scope { I.clock; clear; data_in_valid; data_in } =
    let open Signal in
    let { Uart_tx.O.uart_tx; _ } =
      Uart_tx.hierarchical
        ~instance:"tx"
        scope
        { Uart_tx.I.clock; clear; data_in_valid; data_in }
    in
    let { Cpu_with_dma_memory.O.registers; uart_tx = cpu_uart_tx; video_out; _ } =
      Cpu_with_dma_memory.hierarchical
        ~instance:"cpu"
        scope
        { clock; clear; uart_rx = Some uart_tx }
    in
    let { Uart_rx.O.data_out_valid; data_out; _ } =
      Uart_rx.hierarchical
        ~instance:"rx"
        scope
        { Uart_rx.I.clock; clear; uart_rx = Option.value_exn cpu_uart_tx }
    in
    let video_out = Option.value_exn video_out in
    { O.registers; data_out_valid; data_out; pixel = video_out.video_data.vdata.:(0) }
  ;;
end

type sim =
  (Bits.t ref With_transmitter.I.t, Bits.t ref With_transmitter.O.t) Cyclesim.t
  * Waveform.t
  * string

let create_sim name : sim =
  let module Sim = Cyclesim.With_interface (With_transmitter.I) (With_transmitter.O) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (With_transmitter.create
         (Scope.create ~auto_label_hierarchical_ports:true ~flatten_design:true ()))
  in
  let waveform, sim = Waveform.create sim in
  sim, waveform, name
;;

let finalize_sim sim =
  if debug
  then (
    let _, waveform, name = sim in
    Waveform.Serialize.marshall waveform ("/tmp/programs_" ^ name))
  else ()
;;

let print_ram sim =
  let ram = Cyclesim.lookup_mem_by_name sim "main_memory_bram" |> Option.value_exn in
  let data =
    Cyclesim.Memory.read_all ram
    |> Array.to_list
    |> Bits.concat_lsb
    |> Bits.split_lsb ~part_width:8
    |> List.map ~f:Bits.to_char
    |> String.of_char_list
  in
  print_s [%message "" ~_:(data : String.Hexdump.t)]
;;

let clear_registers ~(inputs : Bits.t ref With_transmitter.I.t) sim =
  inputs.clear := Bits.one 1;
  Cyclesim.cycle sim;
  inputs.clear := Bits.zero 1
;;

let send_dma_message ~address ~packet sim =
  let inputs : _ With_transmitter.I.t = Cyclesim.inputs sim in
  let whole_packet = dma_packet ~address packet in
  (* Send the DMA message through byte by byte. Uart_tx will transmit a
     byte once every ~10 cycles (this is dependent on the number of stop
     bits and the parity bit. *)
  let rec loop_for n =
    if n = 0
    then ()
    else (
      Cyclesim.cycle sim;
      loop_for (n - 1))
  in
  List.iter
    ~f:(fun input ->
      inputs.data_in_valid := vdd;
      inputs.data_in := of_int ~width:8 input;
      Cyclesim.cycle sim;
      inputs.data_in_valid := of_int ~width:1 0;
      loop_for 44)
    whole_packet
;;

let which_cycle = ref 0
let which_px = ref 0
let frames = ref []
let current_frame = Array.init ~f:(fun _ -> false) (output_width * output_height)
let cycles_per_pixel = 20

let clear_video_state () =
  frames := [];
  which_cycle := 0;
  which_px := 0
;;

let consider_collecting_frame_buffer (outputs : Bits.t ref With_transmitter.O.t) =
  let write_framebuffer () =
    Array.set current_frame !which_px (Bits.to_bool !(outputs.pixel))
  in
  let emit_frame () = frames := Array.copy current_frame :: !frames in
  (* On a sampling cycle, store the pixel to the framebuffer. *)
  if !which_cycle % cycles_per_pixel = cycles_per_pixel - 1 then write_framebuffer ();
  (* On the last cycle, save the frame. *)
  if !which_cycle % cycles_per_pixel = 0 && !which_px = (output_width * output_height) - 1
  then emit_frame ()
;;

let test ~print_frames ~cycles ~data sim =
  let sim, _, _ = sim in
  let inputs : _ With_transmitter.I.t = Cyclesim.inputs sim in
  (* Initialize the main memory to some known values for testing. *)
  let initial_ram =
    Cyclesim.lookup_mem_by_name sim "main_memory_bram" |> Option.value_exn
  in
  Sequence.range 0 (Cyclesim.Memory.size_in_words initial_ram)
  |> Sequence.iter ~f:(fun i ->
    Cyclesim.Memory.of_bits ~address:i initial_ram (Bits.zero 32));
  (* Send a clear signal to initialize any CPU IO controller state back to
   * default so we're ready to receive. *)
  clear_registers ~inputs sim;
  send_dma_message ~address:0 ~packet:data sim;
  let _outputs_before : _ With_transmitter.O.t =
    Cyclesim.outputs ~clock_edge:Side.Before sim
  in
  let outputs : _ With_transmitter.O.t = Cyclesim.outputs sim in
  (* Wait some arbitrary number of cycles for the actual DMA to proceed. This is hard to guess, since the memory controller can push back. *)
  Sequence.range 0 100 |> Sequence.iter ~f:(fun _ -> Cyclesim.cycle sim);
  (* Send a clear signal and then start the vsync logic *)
  clear_registers ~inputs sim;
  clear_video_state ();
  print_s [%message "Printing RAM before registers"];
  let rec loop_for cycles =
    if cycles = 0
    then ()
    else (
      Cyclesim.cycle sim;
      consider_collecting_frame_buffer outputs;
      incr which_cycle;
      if Bits.to_bool !(outputs.data_out_valid)
      then printf "%c" (Bits.to_char !(outputs.data_out));
      loop_for (cycles - 1))
  in
  printf "RECEIVED FROM CPU VIA DMA: ";
  loop_for cycles;
  printf "\n";
  if print_frames
  then
    List.iteri
      ~f:(fun idx frame ->
        printf "Framebuffer %i\n" idx;
        Sequence.range 0 output_height
        |> Sequence.iter ~f:(fun y ->
          Sequence.range 0 output_width
          |> Sequence.iter ~f:(fun x ->
            let px = Array.get frame ((y * output_width) + x) in
            printf "%s" (if px then "*" else "-"));
          printf "\n"))
      (* Frames are in reverse order because we're prepending. *)
      (List.rev !frames);
  match outputs.registers with
  | [ outputs ] ->
    let outputs =
      Cpu_with_dma_memory.Registers.map ~f:(fun t -> Bits.to_int !t) outputs
    in
    print_s [%message "" ~_:(outputs : int Cpu_with_dma_memory.Registers.t)];
    print_ram sim
  | _ -> raise_s [%message "BUG: Unexpected number of harts"]
;;

let%expect_test "Hello world (Rust)" =
  let program =
    In_channel.read_all "../test-programs/hello-world-rust/hello-world-rust"
  in
  let sim = create_sim "test_dma_hello_world_rust" in
  test ~print_frames:false ~cycles:5000 ~data:program sim;
  finalize_sim sim;
  [%expect
    {|
    "Printing RAM before registers"
    RECEIVED FROM CPU VIA DMA:
    ((pc 20)
     (general (0 0 0 0 0 1 0 0 0 0 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)))
    ("00000000  93 02 05 00 13 83 05 00  93 03 06 00 73 00 00 00  |............s...|"
     "00000010  13 85 02 00 67 80 00 00  93 00 00 00 13 01 00 00  |....g...........|"
     "00000020  93 01 00 00 13 02 00 00  93 02 00 00 13 03 00 00  |................|"
     "00000030  93 03 00 00 13 04 00 00  93 04 00 00 13 05 00 00  |................|"
     "00000040  93 05 00 00 13 06 00 00  93 06 00 00 13 07 00 00  |................|"
     "00000050  93 07 00 00 13 08 00 00  93 08 00 00 13 09 00 00  |................|"
     "00000060  93 09 00 00 13 0a 00 00  93 0a 00 00 13 0b 00 00  |................|"
     "00000070  93 0b 00 00 13 0c 00 00  93 0c 00 00 13 0d 00 00  |................|"
     "00000080  93 0d 00 00 13 0e 00 00  93 0e 00 00 13 0f 00 00  |................|"
     "00000090  93 0f 00 00 17 41 00 00  13 01 c1 f6 ef 00 80 00  |.....A..........|"
     "000000a0  6f 00 00 00 13 01 01 ff  23 26 11 00 23 24 81 00  |o.......#&..#$..|"
     "000000b0  37 05 00 00 13 04 45 0d  13 06 b0 00 13 05 00 00  |7.....E.........|"
     "000000c0  93 05 04 00 97 00 00 00  e7 80 c0 f3 e3 06 05 fe  |................|"
     "000000d0  6f 00 00 00 48 45 4c 4c  4f 20 57 4f 52 4c 44 4f  |o...HELLO WORLDO|"
     "000000e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000000f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000100  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000110  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000120  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000130  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000140  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000150  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000160  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000170  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000180  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000190  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000001a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000001b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000001c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000001d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000001e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000001f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000200  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000210  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000220  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000230  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000240  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000250  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000260  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000270  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000280  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000290  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000002a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000002b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000002c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000002d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000002e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000002f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000300  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000310  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000320  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000330  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000340  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000350  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000360  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000370  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000380  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000390  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000003a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000003b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000003c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000003d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000003e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000003f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000400  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000410  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000420  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000430  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000440  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000450  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000460  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000470  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000480  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000490  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000004a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000004b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000004c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000004d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000004e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000004f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000500  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000510  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000520  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000530  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000540  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000550  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000560  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000570  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000580  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000590  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000005a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000005b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000005c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000005d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000005e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000005f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000600  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000610  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000620  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000630  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000640  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000650  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000660  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000670  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000680  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000690  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000006a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000006b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000006c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000006d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000006e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000006f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000700  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000710  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000720  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000730  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000740  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000750  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000760  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000770  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000780  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000790  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000007a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000007b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000007c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000007d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000007e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000007f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     ...
     "0000f800  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f810  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f820  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f830  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f840  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f850  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f860  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f870  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f880  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f890  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f8a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f8b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f8c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f8d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f8e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f8f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f900  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f910  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f920  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f930  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f940  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f950  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f960  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f970  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f980  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f990  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f9a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f9b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f9c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f9d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f9e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000f9f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fa00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fa10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fa20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fa30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fa40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fa50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fa60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fa70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fa80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fa90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000faa0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fab0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fac0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fad0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fae0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000faf0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fb00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fb10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fb20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fb30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fb40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fb50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fb60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fb70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fb80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fb90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fba0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fbb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fbc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fbd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fbe0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fbf0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fc00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fc10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fc20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fc30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fc40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fc50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fc60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fc70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fc80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fc90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fca0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fcb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fcc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fcd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fce0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fcf0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fd00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fd10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fd20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fd30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fd40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fd50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fd60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fd70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fd80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fd90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fda0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fdb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fdc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fdd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fde0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fdf0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fe00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fe10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fe20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fe30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fe40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fe50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fe60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fe70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fe80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fe90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fea0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000feb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fec0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fed0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fee0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000fef0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ff00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ff10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ff20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ff30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ff40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ff50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ff60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ff70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ff80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ff90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ffa0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ffb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "0000ffc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    |}]
;;
