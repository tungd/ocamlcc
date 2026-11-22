(* QBE IL: data model and pretty-printer.

   Covers the subset of QBE IL that [Codegen] emits: functions over
   word/long integers (with an optional return class), straight-line blocks
   with arithmetic, comparisons, calls, phi nodes for loop headers and tail
   merges, and byte data definitions for string literals. Floating point and
   aggregate types are added as the compiler grows into them. *)

type ty =
  | Word    (* w: 32-bit *)
  | Long    (* l: 64-bit *)
  | Double  (* d: IEEE 754 64-bit float *)

type t =
  | Temp of string      (* %temp *)
  | Global of string    (* $global *)
  | Extern of string    (* extern $global *)
  | Int of int64        (* immediate *)

module Binop : sig
  type t = Add | Sub | Mul | Div | Rem | And | Or | Xor | Shl | Shr | Sar

  val to_string : t -> string
end

module Cmp : sig
  type t = Eq | Ne | Slt | Sle | Sgt | Sge | Ult

  val to_string : t -> string
end

module Fcmp : sig
  type t = Feq | Fne | Flt | Fle | Fgt | Fge | Fuo | Fo
end

type load_op = Loadl | Loadw | Loaduh | Loadub | Loadsw | Loaduw | Loadd
type store_op = Storel | Storew | Storeh | Storeb | Stored

type call = { fn : t; args : (ty * t) list }

type inst =
  | Binop of Binop.t * ty * t * t * t  (* %dst =ty %a op %b *)
  | Neg of ty * t * t                  (* %dst =ty neg %a *)
  | Cmp of Cmp.t * ty * t * t * t      (* %dst =ty cmp %a, %b *)
  | Fcmp of Fcmp.t * ty * t * t * t    (* %dst =ty fcmpd %a, %b *)
  | Cast of ty * t * t                 (* %dst =ty cast %a *)
  | Extsw of t * t                     (* %dst =l extsw %a *)
  | Sltof of ty * t * t                (* %dst =d sltof %a *)
  | Dtosi of ty * t * t                (* %dst =ty dtosi %a *)
  | Phi of ty * t * (string * t) list  (* %dst =ty phi @l1 %v1, @l2 %v2 *)
  | Copy of ty * t * t                 (* %dst =ty copy %src *)
  | Load of load_op * ty * t * t       (* %dst =ty loadop %addr *)
  | Store of store_op * t * t          (* storeop %val, %addr *)
  | Alloc8 of t * t                    (* %dst =l alloc8 size *)
  | Call of ty * t * call              (* %dst =ty call $f(...) *)
  | Call_void of call                  (* call $f(...) *)

type term =
  | Ret of t option
  | Jmp of string                      (* jmp @label *)
  | Br of t * string * string          (* jnz %c, @tlabel, @flabel *)
  | Hlt                                (* hlt: unreachable / abort *)

type block = { label : string; insts : inst list; term : term }

type func = {
  name : string;      (* global symbol, printed with a $ prefix *)
  export : bool;
  retty : ty option;  (* return class; [None] means a void function *)
  params : (ty * string) list;
  blocks : block list;
}

(* Data definition items; string bytes that need no escaping are grouped. *)
type data_item =
  | D_str of string
  | D_byte of int
  | D_half of int
  | D_word of int32
  | D_long of int64
  | D_ref of string * int64

type data = {
  name : string;      (* global symbol, printed with a $ prefix *)
  export : bool;
  align : int option;
  items : data_item list;
}

type module_ = { funcs : func list; datas : data list }

val to_string : ?pic:bool -> ?name:(string -> string) -> module_ -> string

module Names : sig
  type t = { temp_counter : int; label_counter : int }
end

val optimize_blocks : Names.t -> block list -> block list * Names.t
(** Simplify branch conditions and split wide phi nodes. Take the fresh-name
    counters from the caller and return their updated values. *)
