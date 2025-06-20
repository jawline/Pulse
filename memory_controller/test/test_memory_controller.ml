open! Core
open Hardcaml
open Hardcaml_test_harness
open Hardcaml_memory_controller
open! Bits

module Make_tests (C : sig
    val num_channels : int
  end) =
struct
  module Memory_controller = Memory_controller.Make (struct
      let capacity_in_bytes = 128
      let num_read_channels = C.num_channels
      let num_write_channels = C.num_channels
      let address_width = 32
      let data_bus_width = 32
    end)

  module Harness = Cyclesim_harness.Make (Memory_controller.I) (Memory_controller.O)

  let create_sim f =
    Harness.run
      ~create:
        (Memory_controller.hierarchical
           ~priority_mode:Priority_order
           ~request_delay:1
           ~read_latency:1)
      f
  ;;

  let rec wait_for_write_ack ~ch sim =
    let outputs : _ Memory_controller.O.t = Cyclesim.outputs ~clock_edge:Before sim in
    let ch_rx = List.nth_exn outputs.write_response ch in
    Cyclesim.cycle sim;
    if to_bool !(ch_rx.valid) then () else wait_for_write_ack ~ch sim
  ;;

  let rec write ~address ~value ~ch sim =
    (* Delay a cycle so we know we don't pick up the state of the previous read. *)
    Cyclesim.cycle sim;
    let inputs : _ Memory_controller.I.t = Cyclesim.inputs sim in
    let ch_tx = List.nth_exn inputs.write_to_controller ch in
    ch_tx.valid := vdd;
    ch_tx.data.address := of_unsigned_int ~width:32 address;
    ch_tx.data.write_data := of_unsigned_int ~width:32 value;
    let outputs : _ Memory_controller.O.t = Cyclesim.outputs ~clock_edge:Before sim in
    let ch_rx = List.nth_exn outputs.write_to_controller ch in
    Cyclesim.cycle sim;
    if to_bool !(ch_rx.ready)
    then (
      List.iteri
        ~f:(fun i rx ->
          if i <> ch
          then (
            if to_bool !(rx.ready)
            then
              print_s [%message "BUG: We only expect one channel to have a ready signal."];
            ())
          else ())
        outputs.write_to_controller;
      ch_tx.valid := gnd;
      wait_for_write_ack ~ch sim)
    else write ~address ~value ~ch sim
  ;;

  let read ~address ~ch sim =
    Cyclesim.cycle sim;
    let inputs : _ Memory_controller.I.t = Cyclesim.inputs sim in
    let outputs : _ Memory_controller.O.t = Cyclesim.outputs ~clock_edge:Before sim in
    let ch_rx = List.nth_exn outputs.read_response ch in
    let ch_rx_ack = List.nth_exn outputs.read_to_controller ch in
    let ch_tx = List.nth_exn inputs.read_to_controller ch in
    let rec wait_for_ready () =
      ch_tx.valid := vdd;
      ch_tx.data.address := of_unsigned_int ~width:32 address;
      Cyclesim.cycle sim;
      if to_bool !(ch_rx_ack.ready) then () else wait_for_ready ()
    in
    let rec wait_for_data () =
      Cyclesim.cycle sim;
      if to_bool !(ch_rx.valid)
      then (
        ch_tx.valid := gnd;
        to_int_trunc !(ch_rx.value.read_data))
      else wait_for_data ()
    in
    wait_for_ready ();
    wait_for_data ()
  ;;

  let read_and_assert ~address ~value ~ch sim =
    let result = read ~address ~ch sim in
    if result <> value
    then print_s [%message "BUG: Expected" (result : int) "received" (value : int)]
  ;;

  let debug = true

  let%expect_test "read/write" =
    create_sim (fun ~inputs:_ ~outputs:_ sim ->
      let random = Splittable_random.of_int 1 in
      for _i = 0 to 1000 do
        let next =
          Splittable_random.int ~lo:Int.min_value ~hi:Int.max_value random land 0xFFFFFFFF
        in
        let ch = Splittable_random.int ~lo:0 ~hi:(C.num_channels - 1) random in
        let address = Splittable_random.int ~lo:0 ~hi:127 random land lnot 0b11 in
        write ~address ~value:next ~ch sim;
        read_and_assert ~address ~value:next ~ch sim
      done;
      ());
    [%expect {| |}]
  ;;

  (* TODO: Fix error reporting 
  let%expect_test "read unaligned" =
    create_sim (fun ~inputs:_ ~outputs:_ sim ->
      let ch = 0 in
      read_and_assert ~assertion:`Error ~address:1 ~value:0 ~ch sim;
      read_and_assert ~assertion:`Error ~address:2 ~value:0 ~ch sim;
      read_and_assert ~assertion:`Error ~address:3 ~value:0 ~ch sim;
      read_and_assert ~assertion:`No_error ~address:4 ~value:0 ~ch sim;
      ());
    [%expect {| |}]
  ;;

  let%expect_test "write unaligned" =
    create_sim (fun ~inputs:_ ~outputs:_ sim ->
      let ch = 0 in
      write ~assertion:`Error ~address:1 ~value:0 ~ch sim;
      write ~assertion:`Error ~address:2 ~value:0 ~ch sim;
      write ~assertion:`Error ~address:3 ~value:0 ~ch sim;
      write ~assertion:`No_error ~address:4 ~value:0 ~ch sim;
      ());
    [%expect {| |}]
  ;; *)
end

include Make_tests (struct
    let num_channels = 1
  end)

include Make_tests (struct
    let num_channels = 2
  end)

include Make_tests (struct
    let num_channels = 3
  end)

(* TODO: Add errors to the memory controller and report them via a side channel. *)
