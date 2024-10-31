open Core
open Hardcaml
open Hardcaml_stream

module Make (M : sig
    val address_width : int
    val data_bus_width : int
  end) =
struct
  module Read = struct
    type 'a t = { address : 'a [@bits M.address_width] }
    [@@deriving hardcaml ~rtlmangle:"$"]
  end

  module Write = struct
    type 'a t =
      { address : 'a [@bits M.address_width]
      ; write_data : 'a [@bits M.data_bus_width]
      }
    [@@deriving hardcaml ~rtlmangle:"$"]
  end

  module Read_response = struct
    module T = struct
      type 'a t =
        { error : 'a
        ; read_data : 'a [@bits M.data_bus_width]
        }
      [@@deriving hardcaml ~rtlmangle:"$"]
    end

    include T
    module With_valid = With_valid.Wrap.Make (T)
  end

  module Write_response = struct
    module T = struct
      type 'a t = { error : 'a } [@@deriving hardcaml ~rtlmangle:"$"]
    end

    include T
    module With_valid = With_valid.Wrap.Make (T)
  end

  let data_bus_width = M.data_bus_width

  let address_is_word_aligned address =
    let open Signal in
    let unaligned_bits = Int.floor_log2 (M.data_bus_width / 8) in
    address &:. unaligned_bits ==:. 0
  ;;

  module Read_bus = Stream.Make (Read)
  module Write_bus = Stream.Make (Write)
end
