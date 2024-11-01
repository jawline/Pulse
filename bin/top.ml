open! Core
open Hardcaml
open Hardcaml_risc_v
open Hardcaml_risc_v_hart
module Report_synth = Hardcaml_xilinx_reports

let mhz i = i * 1_000_000
let design_frequency = 150 |> mhz

module Design =
  Cpu.Make
    (struct
      let register_width = Register_width.B32
      let num_registers = 32
    end)
    (struct
      let num_bytes = 1024 * 16
    end)
    (struct
      let num_harts = 1

      let include_io_controller =
        Io_controller_config.Uart_controller
          { baud_rate = 9600
          ; clock_frequency = design_frequency
          ; include_parity_bit = false
          ; stop_bits = 1
          }
      ;;
    end)

module Report_command = Report_synth.Command.With_interface (Design.I) (Design.O)

let report_command = Report_command.command_basic ~name:"Generate_top" Design.create

module Rtl (I : Interface.S) (O : Interface.S) = struct
  let emit ~name ~directory (create : Scope.t -> Signal.t I.t -> Signal.t O.t) =
    let module M = Circuit.With_interface (I) (O) in
    printf "Emitting %s\n" name;
    Core_unix.mkdir_p directory;
    let scope = Scope.create ~flatten_design:false () in
    let circuit = M.create_exn ~name:"top" (create scope) in
    Rtl.output
      ~database:(Scope.circuit_database scope)
      ~output_mode:(In_directory directory)
      Verilog
      circuit
  ;;
end

let rtl_command =
  let module M = Rtl (Design.I) (Design.O) in
  Command.basic
    ~summary:"generate RTL"
    (Command.Param.return (fun () ->
       M.emit
         ~name:"cpu_top"
         ~directory:"./rtl/cpu/"
         (Design.hierarchical ~instance:"cpu_top")))
;;

module Program = struct
  open Hardcaml_risc_v_test
  open Opcode_helper

  let read_packet t =
    let rec wait_for_header () =
      let header = In_channel.input_char t |> Option.value_exn in
      if Char.(header <> 'D') then wait_for_header () else header
    in
    let header = wait_for_header () in
    let length_msb = In_channel.input_byte t |> Option.value_exn in
    let length_lsb = In_channel.input_byte t |> Option.value_exn in
    let length = (length_msb lsl 8) lor length_lsb in
    let bytes_ =
      List.init ~f:(fun _ -> In_channel.input_char t |> Option.value_exn) length
      |> List.rev
      |> String.of_char_list
    in
    header, length, bytes_
  ;;

  let command =
    Command.basic
      ~summary:"program running design and then listen for output"
      (Command.Param.return (fun () ->
         let whole_packet = dma_packet ~address:0 hello_world_program in
         printf "Sending program via DMA\n%!";
         Out_channel.write_all
           "/dev/ttyUSB0"
           ~data:(List.map ~f:Char.of_int_exn whole_packet |> String.of_char_list);
         printf "Opening in channel\n%!";
         let reader = In_channel.create ~binary:true "/dev/ttyUSB0" in
         printf "Sending clear signal via DMA\n%!";
         Out_channel.write_all
           "/dev/ttyUSB0"
           ~data:(List.map ~f:Char.of_int_exn clear_packet |> String.of_char_list);
         printf "Waiting\n%!";
         let rec loop () =
           let header, length, bytes_ = read_packet reader in
           printf "%c %i %s\n%!" header length bytes_;
           loop ()
         in
         loop ()))
  ;;
end

let all_commands =
  Command.group
    ~summary:"RTL tools"
    [ "report", report_command; "generate-rtl", rtl_command; "program", Program.command ]
;;

let () = Command_unix.run all_commands
