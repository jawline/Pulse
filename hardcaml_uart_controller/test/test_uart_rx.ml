open! Core
open Hardcaml
open Hardcaml_uart_controller
open! Bits

let test ~clock_frequency ~baud_rate ~include_parity_bit ~stop_bits ~input =
  let module Config = struct
    (* This should trigger a switch every other cycle. *)
    let clock_frequency = clock_frequency
    let baud_rate = baud_rate
    let include_parity_bit = include_parity_bit
    let stop_bits = stop_bits
  end
  in
  let module Uart_tx = Uart_tx.Make (Config) in
  let module Uart_rx = Uart_rx.Make (Config) in
  let module Machine = struct
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
        }
      [@@deriving sexp_of, hardcaml]
    end

    let create (scope : Scope.t) { I.clock; clear; data_in_valid; data_in } =
      let { Uart_tx.O.uart_tx; _ } =
        Uart_tx.hierarchical
          ~instance:"tx"
          scope
          { Uart_tx.I.clock; clear; data_in_valid; data_in }
      in
      let { Uart_rx.O.data_out_valid; data_out } =
        Uart_rx.hierarchical
          ~instance:"rx"
          scope
          { Uart_rx.I.clock; clear; uart_rx = uart_tx }
      in
      { O.data_out_valid; data_out }
    ;;
  end
  in
  let create_sim () =
    let module Sim = Cyclesim.With_interface (Machine.I) (Machine.O) in
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Machine.create
         (Scope.create ~auto_label_hierarchical_ports:true ~flatten_design:true ()))
  in
  let sim = create_sim () in
  let inputs : _ Machine.I.t = Cyclesim.inputs sim in
  let outputs : _ Machine.O.t = Cyclesim.outputs sim in
  inputs.data_in_valid := of_int ~width:1 1;
  inputs.data_in := of_int ~width:8 input;
  Cyclesim.cycle sim;
  inputs.data_in_valid := of_int ~width:1 0;
  let rec loop_until_finished acc n =
    if n = 0
    then List.rev acc
    else (
      Cyclesim.cycle sim;
      let acc =
        if Bits.to_bool !(outputs.data_out_valid)
        then Bits.to_int !(outputs.data_out) :: acc
        else acc
      in
      loop_until_finished acc (n - 1))
  in
  let outputs = loop_until_finished [] 100 in
  print_s [%message (outputs : int list)]
;;

let%expect_test "test" =
  test
    ~clock_frequency:200
    ~baud_rate:100
    ~include_parity_bit:false
    ~stop_bits:1
    ~input:100;
  [%expect
    {|
      (outputs (1)) |}]
;;
