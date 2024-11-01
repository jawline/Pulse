open! Core
open Hardcaml
open Hardcaml_risc_v
open Hardcaml_risc_v_hart
open Hardcaml_uart_controller
open Hardcaml_waveterm
open Opcode_helper
open! Bits

let debug = true

let uart_config =
  { Hardcaml_uart_controller.Config.clock_frequency = 200
  ; baud_rate = 200
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
  Cpu.Make
    (struct
      let register_width = Register_width.B32
      let num_registers = 32
    end)
    (struct
      let num_bytes = 4096
    end)
    (struct
      let num_harts = 1
      let include_io_controller = Io_controller_config.Uart_controller uart_config
    end)

module With_transmitter = struct
  module I = struct
    type 'a t =
      { clock : 'a
      ; clear : 'a
      ; data_in_valid : 'a
      ; data_in : 'a [@bits 8]
      }
    [@@deriving sexp_of, hardcaml]
  end

  module O = struct
    type 'a t =
      { data_out_valid : 'a
      ; data_out : 'a [@bits 8]
      ; registers : 'a Cpu_with_dma_memory.Registers.t list [@length 1]
      }
    [@@deriving sexp_of, hardcaml]
  end

  let create scope { I.clock; clear; data_in_valid; data_in } =
    let { Uart_tx.O.uart_tx; _ } =
      Uart_tx.hierarchical
        ~instance:"tx"
        scope
        { Uart_tx.I.clock; clear; data_in_valid; data_in }
    in
    let { Cpu_with_dma_memory.O.registers; uart_tx = cpu_uart_tx; _ } =
      Cpu_with_dma_memory.hierarchical
        ~instance:"cpu"
        scope
        { clock; clear; uart_rx = uart_tx }
    in
    let { Uart_rx.O.data_out_valid; data_out; _ } =
      Uart_rx.hierarchical
        ~instance:"rx"
        scope
        { Uart_rx.I.clock; clear; uart_rx = cpu_uart_tx }
    in
    { O.registers; data_out_valid; data_out }
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
   * byte once every ~10 cycles (this is dependent on the number of stop
   * bits and the parity bit. *)
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
      (* TODO: Tighter loop *)
      loop_for 20)
    whole_packet
;;

let test ~cycles ~data sim =
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
  clear_registers ~inputs sim;
  let rec loop_for cycles =
    if cycles = 0
    then ()
    else (
      Cyclesim.cycle sim;
      if Bits.to_bool !(outputs.data_out_valid)
      then printf "%c" (Bits.to_char !(outputs.data_out));
      loop_for (cycles - 1))
  in
  printf "RECEIVED FROM CPU VIA DMA: ";
  loop_for cycles;
  printf "\n";
  match outputs.registers with
  | [ outputs ] ->
    let outputs =
      Cpu_with_dma_memory.Registers.map ~f:(fun t -> Bits.to_int !t) outputs
    in
    print_s [%message "" ~_:(outputs : int Cpu_with_dma_memory.Registers.t)];
    print_ram sim
  | _ -> raise_s [%message "BUG: Unexpected number of harts"]
;;

let%expect_test "Hello world" =
  let program = In_channel.read_all "../test-programs/hello_world_c/hello_world" in
  let sim = create_sim "test_dma_hello_world" in
  test ~cycles:5000 ~data:program sim;
  finalize_sim sim;
  [%expect
    {|
   RECEIVED FROM CPU VIA DMA: D Hello world!D In the middle!D Goodbye
   ((pc 272)
    (general
     (0 264 2032 0 0 1 308 7 0 0 1 308 7 0 315 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
      0)))
   ("00000000  13 01 f0 7f 13 01 11 00  ef 00 80 0b 6f 00 00 00  |............o...|"
    "00000010  13 01 01 ff 23 26 a1 00  23 24 b1 00 23 22 c1 00  |....#&..#$..#\"..|"
    "00000020  83 22 c1 00 03 23 81 00  83 23 41 00 73 00 00 00  |.\"...#...#A.s...|"
    "00000030  93 87 02 00 13 85 07 00  13 01 01 01 67 80 00 00  |............g...|"
    "00000040  13 01 01 fe 23 26 a1 00  83 27 c1 00 23 2e f1 00  |....#&...'..#...|"
    "00000050  6f 00 00 01 83 27 c1 00  93 87 17 00 23 26 f1 00  |o....'......#&..|"
    "00000060  83 27 c1 00 83 c7 07 00  e3 96 07 fe 03 27 c1 00  |.'...........'..|"
    "00000070  83 27 c1 01 b3 07 f7 40  13 85 07 00 13 01 01 02  |.'.....@........|"
    "00000080  67 80 00 00 13 01 01 fe  23 2e 11 00 23 26 a1 00  |g.......#...#&..|"
    "00000090  03 25 c1 00 ef f0 df fa  93 07 05 00 13 86 07 00  |.%..............|"
    "000000a0  83 25 c1 00 13 05 00 00  ef f0 9f f6 93 07 05 00  |.%..............|"
    "000000b0  13 85 07 00 83 20 c1 01  13 01 01 02 67 80 00 00  |..... ......g...|"
    "000000c0  13 01 01 ff 23 26 11 00  13 00 00 00 83 27 c0 13  |....#&.......'..|"
    "000000d0  13 85 07 00 ef f0 1f fb  93 07 05 00 e3 88 07 fe  |................|"
    "000000e0  13 00 00 00 83 27 00 14  13 85 07 00 ef f0 9f f9  |.....'..........|"
    "000000f0  93 07 05 00 e3 88 07 fe  13 00 00 00 83 27 40 14  |.............'@.|"
    "00000100  13 85 07 00 ef f0 1f f8  93 07 05 00 e3 88 07 fe  |................|"
    "00000110  6f 00 00 00 48 65 6c 6c  6f 20 77 6f 72 6c 64 21  |o...Hello world!|"
    "00000120  00 00 00 00 49 6e 20 74  68 65 20 6d 69 64 64 6c  |....In the middl|"
    "00000130  65 21 00 00 47 6f 6f 64  62 79 65 00 14 01 00 00  |e!..Goodbye.....|"
    "00000140  24 01 00 00 34 01 00 00  00 00 00 00 00 00 00 00  |$...4...........|"
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
    "000007b0  00 00 00 00 00 00 00 00  00 00 00 00 3b 01 00 00  |............;...|"
    "000007c0  00 00 00 00 07 00 00 00  34 01 00 00 00 00 00 00  |........4.......|"
    "000007d0  00 00 00 00 00 00 00 00  00 00 00 00 34 01 00 00  |............4...|"
    "000007e0  00 00 00 00 00 00 00 00  00 00 00 00 08 01 00 00  |................|"
    "000007f0  00 00 00 00 00 00 00 00  00 00 00 00 0c 00 00 00  |................|"
    "00000800  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000810  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000820  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000830  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000840  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000850  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000860  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000870  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000880  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000890  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000008a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000008b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000008c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000008d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000008e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000008f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000900  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000910  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000920  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000930  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000940  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000950  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000960  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000970  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000980  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000990  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000009a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000009b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000009c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000009d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000009e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "000009f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000a00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000a10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000a20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000a30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000a40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000a50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000a60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000a70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000a80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000a90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000aa0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ab0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ac0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ad0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ae0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000af0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000b00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000b10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000b20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000b30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000b40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000b50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000b60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000b70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000b80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000b90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ba0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000bb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000bc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000bd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000be0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000bf0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000c00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000c10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000c20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000c30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000c40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000c50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000c60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000c70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000c80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000c90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ca0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000cb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000cc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000cd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ce0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000cf0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000d00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000d10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000d20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000d30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000d40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000d50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000d60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000d70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000d80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000d90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000da0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000db0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000dc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000dd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000de0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000df0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000e00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000e10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000e20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000e30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000e40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000e50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000e60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000e70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000e80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000e90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ea0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000eb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ec0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ed0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ee0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ef0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000f00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000f10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000f20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000f30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000f40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000f50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000f60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000f70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000f80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000f90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000fa0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000fb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000fc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000fd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000fe0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
    "00000ff0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|") |}]
;;

let%expect_test "Game of life" =
  let program = In_channel.read_all "../test-programs/game_of_life/game_of_life" in
  let sim = create_sim "test_dma_game_of_life" in
  test ~cycles:100_000 ~data:program sim;
  finalize_sim sim;
  [%expect
    {|
    RECEIVED FROM CPU VIA DMA: D Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Starting upD Star
    ((pc 60)
     (general
      (0 1804 2032 0 0 0 1812 11 1812 0 0 1812 11 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
       0 0 0)))
    ("00000000  13 01 f0 7f 13 01 11 00  ef 00 40 6e 6f 00 00 00  |..........@no...|"
     "00000010  13 01 01 ff 23 26 a1 00  23 24 b1 00 23 22 c1 00  |....#&..#$..#\"..|"
     "00000020  83 22 c1 00 03 23 81 00  83 23 41 00 73 00 00 00  |.\"...#...#A.s...|"
     "00000030  93 87 02 00 13 85 07 00  13 01 01 01 67 80 00 00  |............g...|"
     "00000040  13 01 01 ff 23 24 81 00  23 22 91 00 23 26 11 00  |....#$..#\"..#&..|"
     "00000050  93 04 05 00 13 84 05 00  13 06 04 00 93 85 04 00  |................|"
     "00000060  13 05 00 00 ef f0 df fa  e3 08 05 fe 83 20 c1 00  |............. ..|"
     "00000070  03 24 81 00 83 24 41 00  13 01 01 01 67 80 00 00  |.$...$A.....g...|"
     "00000080  63 8e 05 0c 33 07 a0 40  93 86 f5 ff 13 08 50 00  |c...3..@......P.|"
     "00000090  93 77 37 00 63 76 d8 0c  93 06 00 00 63 86 07 02  |.w7.cv......c...|"
     "000000a0  23 00 c5 00 13 77 27 00  93 06 10 00 63 0e 07 00  |#....w'.....c...|"
     "000000b0  a3 00 c5 00 13 07 30 00  93 06 20 00 63 96 e7 00  |......0... .c...|"
     "000000c0  23 01 c5 00 93 06 30 00  13 17 86 00 33 83 f5 40  |#.....0.....3..@|"
     "000000d0  93 18 06 01 33 67 e6 00  13 18 86 01 33 67 17 01  |....3g......3g..|"
     "000000e0  b3 07 f5 00 93 78 c3 ff  33 67 07 01 33 88 17 01  |.....x..3g..3...|"
     "000000f0  23 a0 e7 00 93 87 47 00  e3 9c 07 ff b3 87 16 01  |#.....G.........|"
     "00000100  63 0e 13 05 33 07 f5 00  23 00 c7 00 13 87 17 00  |c...3...#.......|"
     "00000110  63 76 b7 04 33 07 e5 00  23 00 c7 00 13 87 27 00  |cv..3...#.....'.|"
     "00000120  63 7e b7 02 33 07 e5 00  23 00 c7 00 13 87 37 00  |c~..3...#.....7.|"
     "00000130  63 76 b7 02 33 07 e5 00  23 00 c7 00 13 87 47 00  |cv..3...#.....G.|"
     "00000140  63 7e b7 00 33 07 e5 00  23 00 c7 00 93 87 57 00  |c~..3...#.....W.|"
     "00000150  63 f6 b7 00 33 05 f5 00  23 00 c5 00 67 80 00 00  |c...3...#...g...|"
     "00000160  93 07 00 00 6f f0 1f fa  93 07 a0 00 63 ec b7 00  |....o.......c...|"
     "00000170  63 ea c7 00 93 d5 35 00  33 86 c5 00 33 05 c5 00  |c.....5.3...3...|"
     "00000180  67 80 00 00 13 05 00 00  67 80 00 00 93 07 10 00  |g.......g.......|"
     "00000190  13 75 75 00 33 95 a7 00  67 80 00 00 93 07 a0 00  |.uu.3...g.......|"
     "000001a0  63 ea b7 02 63 e8 c7 02  93 d7 35 00 b3 87 c7 00  |c...c.....5.....|"
     "000001b0  33 06 f5 00 13 05 00 00  63 00 06 02 83 47 06 00  |3.......c....G..|"
     "000001c0  93 f5 75 00 13 05 10 00  33 15 b5 00 33 75 f5 00  |..u.....3...3u..|"
     "000001d0  67 80 00 00 13 05 00 00  67 80 00 00 93 07 a0 00  |g.......g.......|"
     "000001e0  63 ee b7 02 63 ec c7 02  93 d7 35 00 b3 87 c7 00  |c...c.....5.....|"
     "000001f0  33 05 f5 00 63 04 05 02  63 80 06 02 03 47 05 00  |3...c...c....G..|"
     "00000200  93 f5 75 00 93 07 10 00  b3 97 b7 00 b3 e7 e7 00  |..u.............|"
     "00000210  23 00 f5 00 67 80 00 00  23 00 05 00 67 80 00 00  |#...g...#...g...|"
     "00000220  63 d4 a5 00 13 85 05 00  67 80 00 00 63 54 b5 00  |c.......g...cT..|"
     "00000230  13 85 05 00 67 80 00 00  13 01 01 ff 23 26 11 00  |....g.......#&..|"
     "00000240  23 24 81 00 23 22 91 00  93 06 f6 ff 63 54 d6 00  |#$..#\"......cT..|"
     "00000250  93 06 06 00 13 0f 16 00  93 07 a0 00 63 d4 e7 01  |............c...|"
     "00000260  13 0f a0 00 63 4a df 0c  93 8e f5 ff 63 cc d5 0b  |....cJ......c...|"
     "00000270  93 8f 15 00 93 07 a0 00  63 c8 f7 09 13 0f 1f 00  |........c.......|"
     "00000280  13 04 00 00 13 03 a0 00  93 88 1f 00 13 0e 10 00  |................|"
     "00000290  63 c2 df 05 63 80 c6 04  63 6e d3 02 93 87 0e 00  |c...c...cn......|"
     "000002a0  13 d7 37 00 33 07 d7 00  33 07 e5 00 63 80 b7 02  |..7.3...3...c...|"
     "000002b0  13 f8 77 00 33 18 0e 01  63 6a f3 00 63 08 07 00  |..w.3...cj..c...|"
     "000002c0  03 47 07 00 33 78 e8 00  33 04 04 01 93 87 17 00  |.G..3x..3.......|"
     "000002d0  e3 98 f8 fc 93 86 16 00  e3 9c e6 fb 13 06 10 00  |................|"
     "000002e0  93 05 00 71 13 05 00 00  ef f0 9f d2 e3 08 05 fe  |...q............|"
     "000002f0  83 20 c1 00 13 05 04 00  03 24 81 00 83 24 41 00  |. .......$...$A.|"
     "00000300  13 01 01 01 67 80 00 00  93 0f a0 00 13 0f 1f 00  |....g...........|"
     "00000310  13 04 00 00 13 03 a0 00  93 88 1f 00 13 0e 10 00  |................|"
     "00000320  6f f0 1f f7 93 8f 15 00  93 07 a0 00 93 8e 05 00  |o...............|"
     "00000330  e3 d6 f7 f5 6f f0 5f fd  13 04 00 00 6f f0 1f fa  |....o._.....o...|"
     "00000340  13 01 01 fe 23 2a 91 00  23 28 21 01 23 26 31 01  |....#*..#(!.#&1.|"
     "00000350  23 24 41 01 23 22 51 01  23 2e 11 00 23 2c 81 00  |#$A.#\"Q.#...#,..|"
     "00000360  93 09 05 00 13 89 05 00  93 0a 00 00 93 04 10 00  |................|"
     "00000370  13 0a a0 00 13 04 00 00  6f 00 80 01 83 c6 07 00  |........o.......|"
     "00000380  33 67 d7 00 23 80 e7 00  13 04 14 00 63 00 44 05  |3g..#.......c.D.|"
     "00000390  13 86 0a 00 93 05 04 00  13 05 09 00 ef f0 df e9  |................|"
     "000003a0  93 57 34 00 b3 87 57 01  b3 87 f9 00 13 05 e5 ff  |.W4...W.........|"
     "000003b0  e3 8c 07 fc 13 77 74 00  33 97 e4 00 e3 f0 a4 fc  |.....wt.3.......|"
     "000003c0  23 80 07 00 13 04 14 00  e3 14 44 fd 93 8a 1a 00  |#.........D.....|"
     "000003d0  e3 92 8a fa 83 20 c1 01  03 24 81 01 83 24 41 01  |..... ...$...$A.|"
     "000003e0  03 29 01 01 83 29 c1 00  03 2a 81 00 83 2a 41 00  |.)...)...*...*A.|"
     "000003f0  13 01 01 02 67 80 00 00  93 07 a0 00 63 e0 c7 14  |....g.......c...|"
     "00000400  b3 87 c5 00 63 88 07 10  03 c7 07 00 93 06 a0 02  |....c...........|"
     "00000410  13 77 17 00 13 07 f7 ff  13 77 67 ff 13 07 a7 02  |.w.......wg.....|"
     "00000420  23 00 e5 00 03 c7 07 00  13 77 27 00 13 37 17 00  |#........w'..7..|"
     "00000430  33 07 e0 40 13 77 67 ff  13 07 a7 02 a3 00 e5 00  |3..@.wg.........|"
     "00000440  03 c7 07 00 13 77 47 00  13 37 17 00 33 07 e0 40  |.....wG..7..3..@|"
     "00000450  13 77 67 ff 13 07 a7 02  23 01 e5 00 03 c7 07 00  |.wg.....#.......|"
     "00000460  13 77 87 00 13 37 17 00  33 07 e0 40 13 77 67 ff  |.w...7..3..@.wg.|"
     "00000470  13 07 a7 02 a3 01 e5 00  03 c7 07 00 13 77 07 01  |.............w..|"
     "00000480  13 37 17 00 33 07 e0 40  13 77 67 ff 13 07 a7 02  |.7..3..@.wg.....|"
     "00000490  23 02 e5 00 03 c7 07 00  13 77 07 02 13 37 17 00  |#........w...7..|"
     "000004a0  33 07 e0 40 13 77 67 ff  13 07 a7 02 a3 02 e5 00  |3..@.wg.........|"
     "000004b0  03 c7 07 00 13 77 07 04  13 37 17 00 33 07 e0 40  |.....w...7..3..@|"
     "000004c0  13 77 67 ff 13 07 a7 02  23 03 e5 00 83 87 07 00  |.wg.....#.......|"
     "000004d0  63 d2 07 06 13 06 16 00  a3 03 d5 00 b3 85 c5 00  |c...............|"
     "000004e0  83 c7 05 00 93 f7 17 00  93 87 f7 ff 93 f7 67 ff  |..............g.|"
     "000004f0  93 87 a7 02 23 04 f5 00  83 c7 05 00 93 97 e7 01  |....#...........|"
     "00000500  93 d7 f7 41 93 f7 a7 00  93 87 07 02 a3 04 f5 00  |...A............|"
     "00000510  67 80 00 00 93 07 00 02  23 00 f5 00 a3 00 f5 00  |g.......#.......|"
     "00000520  23 01 f5 00 a3 01 f5 00  23 02 f5 00 a3 02 f5 00  |#.......#.......|"
     "00000530  23 03 f5 00 93 06 00 02  6f f0 df f9 93 07 00 02  |#.......o.......|"
     "00000540  23 00 f5 00 a3 00 f5 00  23 01 f5 00 a3 01 f5 00  |#.......#.......|"
     "00000550  23 02 f5 00 a3 02 f5 00  23 03 f5 00 a3 03 f5 00  |#.......#.......|"
     "00000560  23 04 f5 00 a3 04 f5 00  67 80 00 00 13 01 01 ff  |#.......g.......|"
     "00000570  23 24 81 00 23 26 11 00  93 06 05 00 13 07 40 74  |#$..#&........@t|"
     "00000580  93 05 00 02 63 02 05 14  83 47 05 00 13 06 a0 02  |....c....G......|"
     "00000590  93 f7 17 00 b3 07 f0 40  93 f7 a7 00 93 87 07 02  |.......@........|"
     "000005a0  23 00 f7 00 83 47 05 00  93 f7 27 00 63 8a 07 0a  |#....G....'.c...|"
     "000005b0  a3 00 c7 00 83 47 05 00  93 f7 47 00 63 8a 07 0a  |.....G....G.c...|"
     "000005c0  23 01 c7 00 83 c7 06 00  93 f7 87 00 63 8a 07 0a  |#...........c...|"
     "000005d0  a3 01 c7 00 83 c7 06 00  93 f7 07 01 63 8a 07 0a  |............c...|"
     "000005e0  23 02 c7 00 83 c7 06 00  93 f7 07 02 63 8a 07 0a  |#...........c...|"
     "000005f0  a3 02 c7 00 83 c7 06 00  93 f7 07 04 63 8a 07 0a  |............c...|"
     "00000600  93 07 a0 02 23 03 f7 00  83 87 06 00 63 da 07 0a  |....#.......c...|"
     "00000610  93 07 a0 02 a3 03 f7 00  83 c7 16 00 93 f7 17 00  |................|"
     "00000620  93 87 f7 ff 93 f7 67 ff  93 87 a7 02 23 04 f7 00  |......g.....#...|"
     "00000630  83 c7 16 00 93 f7 27 00  93 b7 17 00 b3 07 f0 40  |......'........@|"
     "00000640  93 f7 67 ff 93 87 a7 02  a3 04 f7 00 13 06 a0 00  |..g.............|"
     "00000650  93 05 40 74 13 05 00 00  ef f0 9f 9b 6f f0 1f ff  |..@t........o...|"
     "00000660  a3 00 b7 00 83 47 05 00  93 f7 47 00 e3 9a 07 f4  |.....G....G.....|"
     "00000670  23 01 b7 00 83 c7 06 00  93 f7 87 00 e3 9a 07 f4  |#...............|"
     "00000680  a3 01 b7 00 83 c7 06 00  93 f7 07 01 e3 9a 07 f4  |................|"
     "00000690  23 02 b7 00 83 c7 06 00  93 f7 07 02 e3 9a 07 f4  |#...............|"
     "000006a0  a3 02 b7 00 83 c7 06 00  93 f7 07 04 e3 9a 07 f4  |................|"
     "000006b0  93 07 00 02 23 03 f7 00  83 87 06 00 e3 ca 07 f4  |....#...........|"
     "000006c0  93 07 00 02 6f f0 1f f5  37 28 20 20 b7 27 00 00  |....o...7(  .'..|"
     "000006d0  93 87 07 02 13 08 08 02  23 12 f7 00 23 20 07 01  |........#...# ..|"
     "000006e0  23 03 b7 00 93 07 00 02  6f f0 df f2 13 01 01 ff  |#.......o.......|"
     "000006f0  23 24 81 00 23 26 11 00  13 04 40 71 13 06 b0 00  |#$..#&....@q....|"
     "00000700  93 05 04 00 13 05 00 00  ef f0 9f 90 6f f0 1f ff  |............o...|"
     "00000710  46 00 00 00 53 74 61 72  74 69 6e 67 20 75 70 00  |F...Starting up.|"
     "00000720  45 6e 74 65 72 69 6e 67  20 6c 6f 6f 70 00 00 00  |Entering loop...|"
     "00000730  43 6c 65 61 72 65 64 00  43 6f 6d 70 75 74 65 64  |Cleared.Computed|"
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
     "000007e0  00 00 00 00 0b 00 00 00  14 07 00 00 00 00 00 00  |................|"
     "000007f0  00 00 00 00 00 00 00 00  00 00 00 00 0c 00 00 00  |................|"
     "00000800  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000810  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000820  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000830  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000840  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000850  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000860  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000870  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000880  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000890  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000008a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000008b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000008c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000008d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000008e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000008f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000900  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000910  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000920  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000930  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000940  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000950  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000960  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000970  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000980  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000990  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000009a0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000009b0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000009c0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000009d0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000009e0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "000009f0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000a00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000a10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000a20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000a30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000a40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000a50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000a60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000a70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000a80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000a90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000aa0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ab0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ac0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ad0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ae0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000af0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000b00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000b10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000b20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000b30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000b40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000b50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000b60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000b70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000b80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000b90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ba0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000bb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000bc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000bd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000be0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000bf0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000c00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000c10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000c20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000c30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000c40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000c50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000c60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000c70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000c80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000c90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ca0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000cb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000cc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000cd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ce0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000cf0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000d00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000d10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000d20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000d30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000d40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000d50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000d60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000d70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000d80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000d90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000da0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000db0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000dc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000dd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000de0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000df0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000e00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000e10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000e20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000e30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000e40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000e50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000e60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000e70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000e80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000e90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ea0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000eb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ec0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ed0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ee0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ef0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000f00  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000f10  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000f20  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000f30  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000f40  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000f50  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000f60  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000f70  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000f80  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000f90  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000fa0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000fb0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000fc0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000fd0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000fe0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|"
     "00000ff0  00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|")
    |}]
;;
