(* QBE IL: data model and pretty-printer.

   Covers the subset of QBE IL that [Codegen] emits today: functions over
   word/long integers, straight-line blocks with arithmetic, comparisons,
   calls, and the three-way branch terminator. Data definitions, floating
   point, and aggregate types are added as the compiler grows into them. *)

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
  | Copy of ty * t * t                 (* %dst =ty copy %src *)
  | Call of ty * t * call              (* %dst =ty call $f(...) *)
  | Call_void of call                  (* call $f(...) *)

type term =
  | Ret of t option
  | Jmp of string                      (* jmp @label *)
  | Br of t * string * string          (* jnz %c, @tlabel, @flabel *)

type block = { label : string; insts : inst list; term : term }

type func = {
  name : string;      (* global symbol, printed with a $ prefix *)
  export : bool;
  params : (ty * string) list;
  blocks : block list;
}

type module_ = { funcs : func list }

val to_string : module_ -> string
