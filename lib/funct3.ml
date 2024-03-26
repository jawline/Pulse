open Core

module Op_imm = struct
  (* TODO: A dedicated path for op_imm is not necessary since it's the
     same table as Op *)
  type t =
    | Addi
    | Slli
    | Slti
    | Xori
    | Sltiu
    | Ori
    | Andi
    | (* Depending on the upper 7 bits of the imm this is either SRAI or SRLI *)
      Srli_or_srai

  let of_int_exn i =
    match i with
    | 0b000 -> Addi
    | 0b001 -> Slli
    | 0b010 -> Slti
    | 0b100 -> Xori
    | 0b011 -> Sltiu
    | 0b110 -> Ori
    | 0b111 -> Andi
    | 0b101 -> Srli_or_srai
    | _ -> raise_s [%message "BUG: Funct3 should be 3 bits wide"]
  ;;
end

module Op = struct
  type t =
    | (* These seem identical to the op_imm versions but I'll leave it for
         clarity in use. *)
      Add_or_sub
    | Sll
    | Slt
    | Xor
    | Sltu
    | Or
    | And
    | (* Depending on the upper 7 bits of the imm this is either SRAI or SRLI *)
      Srl_or_sra

  let to_int t =
    match t with
    | Add_or_sub -> 0b000
    | Sll -> 0b001
    | Slt -> 0b010
    | Xor -> 0b100
    | Sltu -> 0b011
    | Or -> 0b110
    | And -> 0b111
    | Srl_or_sra -> 0b101
  ;;

  let of_int_exn i =
    match i with
    | 0b000 -> Add_or_sub
    | 0b001 -> Sll
    | 0b010 -> Slt
    | 0b100 -> Xor
    | 0b011 -> Sltu
    | 0b110 -> Or
    | 0b111 -> And
    | 0b101 -> Srl_or_sra
    | _ -> raise_s [%message "BUG: Funct3 should be 3 bits wide"]
  ;;
end

module Branch = struct
  type t =
    | Beq
    | Bne
    | Blt
    | Bge
    | Bltu
    | Bgeu
    | Invalid

  let to_int t =
    match t with
    | Beq -> 0b000
    | Bne -> 0b001
    | Blt -> 0b100
    | Bge -> 0b101
    | Bltu -> 0b110
    | Bgeu -> 0b111
    | Invalid -> raise_s [%message "BUG: No single representation"]
  ;;

  let of_int_exn i =
    match i with
    | 0b000 -> Beq
    | 0b001 -> Bne
    | 0b100 -> Blt
    | 0b101 -> Bge
    | 0b110 -> Bltu
    | 0b111 -> Bgeu
    | _ -> Invalid
  ;;
end

module Load = struct
  type t =
    | Lb
    | Lh
    | Lw
    | Lbu
    | Lhu
  [@@deriving enumerate]

  let to_int = function
    | Lb -> 0b000
    | Lh -> 0b001
    | Lw -> 0b010
    | Lbu -> 0b100
    | Lhu -> 0b101
  ;;

  let of_int = function
    | 0b000 -> Some Lb
    | 0b001 -> Some Lh
    | 0b010 -> Some Lw
    | 0b100 -> Some Lbu
    | 0b101 -> Some Lhu
    | _ -> None
  ;;
end

module Store = struct
  let sb = 0b000
  let sh = 0b001
  let sw = 0b010
end

module System = struct
  (** If the last 12 bits are 0 then this is ECALL otherwise it is EBREAK *)
  let ecall_or_ebreak = 0b000

  let csrrw = 0b001
  let csrrs = 0b010
  let csrrc = 0b011
  let csrrwi = 0b101
  let csrrsi = 0b110
  let csrrci = 0b111
end
