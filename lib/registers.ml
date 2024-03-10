module Make (Hart_config : Hart_config_intf.S) (Memory : Memory_bus.S) = struct
  let address_width = Address_width.bits Hart_config.address_width
  let register_width = Register_width.bits Hart_config.register_width

  type 'a t =
    { pc : 'a [@bits address_width]
    ; general : 'a list [@bits register_width] [@length Hart_config.num_registers]
    }
  [@@deriving sexp_op, hardcaml]
end
