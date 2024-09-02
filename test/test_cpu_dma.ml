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
      let num_bytes = 32
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
    Waveform.Serialize.marshall waveform ("/tmp/dma_" ^ name))
  else ()
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

let test ~data sim =
  let sim, _, _ = sim in
  let inputs : _ With_transmitter.I.t = Cyclesim.inputs sim in
  (* Send a clear signal to initialize any CPU IO controller state back to
     default so we're ready to receive. *)
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
  loop_for 1000;
  printf "\n";
  match outputs.registers with
  | [ outputs ] ->
    let outputs =
      Cpu_with_dma_memory.Registers.map ~f:(fun t -> Bits.to_int !t) outputs
    in
    print_s [%message "" ~_:(outputs : int Cpu_with_dma_memory.Registers.t)];
    Test_util.print_ram sim
  | _ -> raise_s [%message "BUG: Unexpected number of harts"]
;;

let%expect_test "hello world via DMA round-trip" =
  let hello_world_program = hello_world_program in
  let sim = create_sim "test_dma_hello_world" in
  test ~data:hello_world_program sim;
  finalize_sim sim;
  [%expect.unreachable]
[@@expect.uncaught_exn {|
  (* CR expect_test_collector: This test expectation appears to contain a backtrace.
     This is strongly discouraged as backtraces are fragile.
     Please change this test to not include a backtrace. *)
  ("circuit input signal must have a port name (unassigned wire?)"
    (input_signal (wire (width 1) (data_in empty))))
  Raised at Base__Error.raise in file "src/error.ml", line 9, characters 72-88
  Called from Base__Error.raise in file "src/error.ml" (inlined), line 20, characters 30-37
  Called from Base__Or_error.ok_exn in file "src/or_error.ml" (inlined), line 124, characters 17-32
  Called from Hardcaml__Circuit.create_exn in file "src/circuit.ml", line 191, characters 15-56
  Called from Hardcaml__Circuit.With_interface.create_exn in file "src/circuit.ml", line 442, characters 6-82
  Called from Hardcaml__Cyclesim.With_interface.create in file "src/cyclesim.ml", line 146, characters 18-81
  Called from Hardcaml_risc_v_test__Test_cpu_dma.create_sim in file "test/test_cpu_dma.ml", lines 93-96, characters 4-84
  Called from Hardcaml_risc_v_test__Test_cpu_dma.(fun) in file "test/test_cpu_dma.ml", line 176, characters 12-45
  Called from Ppx_expect_runtime__Test_block.Configured.dump_backtrace in file "runtime/test_block.ml", line 142, characters 10-28
  |}]
;;
