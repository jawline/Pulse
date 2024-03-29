(** A transaction encodes the desired state change from an opcode, including a
    finished flag to indicate the opcode is done if it spans multiple cycles. *)
open! Core

open! Hardcaml

module Make (Hart_config : Hart_config_intf.S) (Memory : Memory_bus_intf.S) = struct
  let register_width = Register_width.bits Hart_config.register_width

  type 'a t =
    { (* We could pull old_rd into decoded instruction to avoid the gate on committing *)
      finished : 'a
    ; set_rd : 'a
    ; new_rd : 'a [@bits register_width]
    ; new_pc : 'a [@bits register_width]
    ; error : 'a
    }
  [@@deriving sexp_of, hardcaml]
end
