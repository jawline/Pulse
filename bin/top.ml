open! Core
open Hardcaml
open Hardcaml_risc_v
open Hardcaml_risc_v_hart
module Report_synth = Hardcaml_xilinx_reports

module Make (C : sig
    val include_video_out : bool
    val hart_frequency : int
  end) =
struct
  module Design =
    System.Make
      (struct
        let register_width = Register_width.B32
        let num_registers = 32
        let design_frequency = C.hart_frequency
      end)
      (struct
        let num_bytes = 65536
      end)
      (struct
        let num_harts = 1

        let include_io_controller =
          Io_controller_config.Uart_controller
            { baud_rate = 9600
            ; clock_frequency = C.hart_frequency
            ; include_parity_bit = false
            ; stop_bits = 2
            }
        ;;

        let include_video_out =
          if C.include_video_out
          then
            Video_config.Video_out
              ( (module struct
                  let output_width = 1024
                  let output_height = 600
                  let input_width = 64
                  let input_height = 32
                  let framebuffer_address = 0x8000
                end : Video_out_intf.Config)
              , (module struct
                  (* TODO: Add a clock requirement *)

                  let h_active = 1024
                  let v_active = 600
                  let h_fp = 32
                  let h_sync = 48
                  let h_bp = 240
                  let v_fp = 10
                  let v_sync = 3
                  let v_bp = 12
                end : Video_signals.Config) )
          else No_video_out
        ;;
      end)

  module Report_command = Report_synth.Command.With_interface (Design.I) (Design.O)

  let report_command =
    Report_command.command_basic ~name:"Generate_top" Design.hierarchical
  ;;

  module Rtl = struct
    let emit () =
      let module M = Circuit.With_interface (Design.I) (Design.O) in
      let scope = Scope.create ~flatten_design:false () in
      let circuit = M.create_exn ~name:"top" (Design.hierarchical scope) in
      Rtl.print ~database:(Scope.circuit_database scope) Verilog circuit
    ;;
  end
end

let rtl_command =
  Command.basic
    ~summary:"generate RTL"
    (let open Command.Let_syntax in
     let open Command.Param in
     let%map include_video_out =
       flag
         "include-video-out"
         (required bool)
         ~doc:"include logic for generating a video signal"
     and hart_frequency =
       flag "hart-frequency" (required int) ~doc:"clock frequency in hz for the hart"
     in
     fun () ->
       let module M =
         Make (struct
           let include_video_out = include_video_out
           let hart_frequency = hart_frequency
         end)
       in
       M.Rtl.emit ())
;;

module Program = struct
  open Hardcaml_risc_v_test
  open Opcode_helper

  let read_packet t =
    let rec wait_for_header () =
      let header = In_channel.input_char t |> Option.value_exn in
      print_s [%message "RD" (header : char)];
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

  let device_file = "/dev/ttyUSB1"

  let do_write ~ch data =
    List.iter ~f:(fun byte -> Out_channel.output_byte ch byte) data;
    Out_channel.flush ch;
    let _ = Core_unix.nanosleep 1. in
    ()
  ;;

  let command =
    Command.basic
      ~summary:"program running design and then listen for output"
      (let open Command.Let_syntax in
       let open Command.Param in
       let%map program_filename = anon ("program-filename" %: string) in
       fun () ->
         printf "Opening out channel\n";
         let writer = Out_channel.create ~binary:true device_file in
         printf "Opening in channel\n%!";
         let reader = In_channel.create ~binary:true device_file in
         print_s [%message "Loading" (program_filename : string)];
         let program = In_channel.read_all program_filename in
         print_s [%message "Loaded" (String.length program : int)];
         let chunk_sz = 320000 in
         String.to_list program
         |> List.chunks_of ~length:chunk_sz
         |> List.iteri ~f:(fun index chunk ->
           print_s [%message "Sending chunk"];
           let address = index * chunk_sz in
           let program = String.of_char_list chunk in
           let formatted_packet = dma_packet ~address program in
           do_write ~ch:writer formatted_packet);
         printf "Sending clear signal via DMA\n%!";
         do_write ~ch:writer clear_packet;
         printf "Waiting\n%!";
         let rec loop () =
           let header, length, bytes_ = read_packet reader in
           printf "%c %i %s\n%!" header length bytes_;
           loop ()
         in
         loop ())
  ;;
end

module Without_video = Make (struct
    let include_video_out = false
    let hart_frequency = 100_000_000
  end)

module With_video = Make (struct
    let include_video_out = true
    let hart_frequency = 100_000_000
  end)

let all_commands =
  Command.group
    ~summary:"RTL tools"
    [ "report", With_video.report_command
    ; "report-novideo", Without_video.report_command
    ; "generate-rtl", rtl_command
    ; "program", Program.command
    ]
;;

let () = Command_unix.run all_commands
