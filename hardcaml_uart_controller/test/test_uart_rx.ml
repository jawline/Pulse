open! Core
open Hardcaml
open Hardcaml_waveterm
open Hardcaml_uart_controller
open! Bits

let debug = true

let test ~name ~clock_frequency ~baud_rate ~include_parity_bit ~stop_bits ~all_inputs =
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
        ; parity_error : 'a
        ; stop_bit_unstable : 'a
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
      let { Uart_rx.O.data_out_valid; data_out; parity_error; stop_bit_unstable } =
        Uart_rx.hierarchical
          ~instance:"rx"
          scope
          { Uart_rx.I.clock; clear; uart_rx = uart_tx }
      in
      { O.data_out_valid; data_out; parity_error; stop_bit_unstable }
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
  let waveform, sim = Waveform.create sim in
  let inputs : _ Machine.I.t = Cyclesim.inputs sim in
  let outputs : _ Machine.O.t = Cyclesim.outputs sim in
  let all_outputs = ref [] in
  List.iter
    ~f:(fun input ->
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
               || Bits.to_bool !(outputs.parity_error)
            then Bits.to_int !(outputs.data_out) :: acc
            else acc
          in
          loop_until_finished acc (n - 1))
      in
      let outputs = loop_until_finished [] 100 in
      all_outputs := !all_outputs @ outputs)
    all_inputs;
  print_s [%message "" ~_:(!all_outputs : int list)];
  if debug
  then Waveform.expect ~serialize_to:name ~display_width:150 ~display_height:100 waveform
  else ();
  if not (List.equal Int.( = ) !all_outputs all_inputs)
  then raise_s [%message "outputs did not match inputs"]
;;

let%expect_test "test" =
  test
    ~name:"/tmp/one_stop_bit_no_parity"
    ~clock_frequency:200
    ~baud_rate:200
    ~include_parity_bit:false
    ~stop_bits:1
    ~all_inputs:[ 0b1010; 0b111; 0b1001_1001; 0b1111_1111; 0b0000_0000; 0b1010_1010 ];
  [%expect
    {|
     (10 7 153 255 0 170)
     ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
     │clock             ││┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   │
     │                  ││    └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───┘   └───│
     │clear             ││                                                                                                                                │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │data_in           ││ 0A                                                                                                                             │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │data_in_valid     ││────────┐                                                                                                                       │
     │                  ││        └───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │                  ││────────────────────────────────┬───────────────┬───────────────────────────────────────────────────────┬───────────────────────│
     │data_out          ││ 00                             │02             │0A                                                     │00                     │
     │                  ││────────────────────────────────┴───────────────┴───────────────────────────────────────────────────────┴───────────────────────│
     │data_out_valid    ││                                                                                        ┌───────┐                               │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────┘       └───────────────────────────────│
     │parity_error      ││                                                                                                                                │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │stop_bit_unstable ││                                                                                                                                │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │                  ││────────────────┬───────────────────────────────────────────────────────────────┬───────────────┬───────────────────────────────│
     │rx$current_state  ││ 0              │1                                                              │3              │0                              │
     │                  ││────────────────┴───────────────────────────────────────────────────────────────┴───────────────┴───────────────────────────────│
     │                  ││────────┬───────────────┬───────────────┬───────────────────────────────────────┬───────────────────────┬───────────────────────│
     │rx$data_with_new_b││ 01     │00             │02             │0A                                     │0B                     │01                     │
     │                  ││────────┴───────────────┴───────────────┴───────────────────────────────────────┴───────────────────────┴───────────────────────│
     │rx$i$clear        ││                                                                                                                                │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │rx$i$clock        ││                                                                                                                                │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │rx$i$uart_rx      ││────────┐               ┌───────┐       ┌───────┐                               ┌───────────────────────────────────────────────│
     │                  ││        └───────────────┘       └───────┘       └───────────────────────────────┘                                               │
     │                  ││────────────────────────────────┬───────────────┬───────────────────────────────────────────────────────┬───────────────────────│
     │rx$o$data_out     ││ 00                             │02             │0A                                                     │00                     │
     │                  ││────────────────────────────────┴───────────────┴───────────────────────────────────────────────────────┴───────────────────────│
     │rx$o$data_out_vali││                                                                                        ┌───────┐                               │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────┘       └───────────────────────────────│
     │rx$o$parity_error ││                                                                                                                                │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │rx$o$stop_bit_unst││                                                                                                                                │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │rx$switch_cycle   ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │                  ││                                                                                                                                │
     │                  ││────────────────────────┬───────┬───────┬───────┬───────┬───────┬───────┬───────┬───────────────────────────────────────────────│
     │rx$which_data_bit ││ 0                      │1      │2      │3      │4      │5      │6      │7      │0                                              │
     │                  ││────────────────────────┴───────┴───────┴───────┴───────┴───────┴───────┴───────┴───────────────────────────────────────────────│
     │                  ││────────┬───────┬───────────────────────────────────────────────────────────────┬───────────────┬───────────────────────────────│
     │tx$current_state  ││ 0      │1      │2                                                              │4              │0                              │
     │                  ││────────┴───────┴───────────────────────────────────────────────────────────────┴───────────────┴───────────────────────────────│
     │tx$i$clear        ││                                                                                                                                │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │tx$i$clock        ││                                                                                                                                │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │tx$i$data_in      ││ 0A                                                                                                                             │
     │                  ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │tx$i$data_in_valid││────────┐                                                                                                                       │
     │                  ││        └───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │tx$next_data_bit  ││                        ┌───────┐       ┌───────┐                                                                               │
     │                  ││────────────────────────┘       └───────┘       └───────────────────────────────────────────────────────────────────────────────│
     │tx$o$uart_tx      ││────────┐               ┌───────┐       ┌───────┐                               ┌───────────────────────────────────────────────│
     │                  ││        └───────────────┘       └───────┘       └───────────────────────────────┘                                               │
     │tx$switch_cycle   ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │                  ││                                                                                                                                │
     │vdd               ││────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     │                  ││                                                                                                                                │
     └──────────────────┘└────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
     b86c2921e3c4630e9064474184e1db21 |}]
;;
