(* QBE IL: data model and pretty-printer.

   Covers the subset of QBE IL that [Codegen] emits: functions over
   word/long integers (with an optional return class), straight-line blocks
   with arithmetic, comparisons, calls, phi nodes for loop headers and tail
   merges, and byte data definitions for string literals. Floating point and
   aggregate types are added as the compiler grows into them. *)

type ty =
  | Word  (* w: 32-bit *)
  | Long  (* l: 64-bit *)

type t =
  | Temp of string      (* %temp *)
  | Global of string    (* $global *)
  | Int of int64        (* immediate *)

module Binop : sig
  type t = Add | Sub | Mul | Div | Rem | And | Or | Xor | Shl | Sar

  val to_string : t -> string
end

module Cmp : sig
  type t = Eq | Ne | Slt | Sle | Sgt | Sge

  val to_string : t -> string
end

type call = { fn : t; args : (ty * t) list }

type inst =
  | Binop of Binop.t * ty * t * t * t  (* %dst =ty %a op %b *)
  | Cmp of Cmp.t * ty * t * t * t      (* %dst =ty ceq %a, %b *)
  | Phi of ty * t * (string * t) list  (* %dst =ty phi @l1 %v1, @l2 %v2 *)
  | Copy of ty * t * t                 (* %dst =ty copy %src *)
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

type data = {
  name : string;      (* global symbol, printed with a $ prefix *)
  items : data_item list;
}

type module_ = { funcs : func list; datas : data list }

val to_string : module_ -> string
