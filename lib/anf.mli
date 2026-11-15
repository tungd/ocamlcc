(* Administrative Normal Form (ANF) middle-end IR.

   Every non-trivial subexpression is bound to a named [Ident.t] so
   downstream passes (Perceus ARC dup/drop/reuse, exception lowering, and
   QBE codegen) see explicit evaluation order, liveness boundaries, and
   tail-call positions. *)

type const_item =
  | C_int of int
  | C_char of char
  | C_string of string
  | C_block of int * const_item list

type atom =
  | Var of Ident.t
  | MutVar of Ident.t
  | Int of int
  | Char of char
  | String of string
  | ConstBlock of int * const_item list
  | Unit

type binop =
  | Add
  | Sub
  | Mul
  | Div
  | Mod
  | And
  | Or
  | Xor
  | Lsl
  | Lsr
  | Asr
  | Cmp of Lambda.integer_comparison
  | Compare_ints
  | Isout

type unop =
  | Neg
  | Not
  | Offset of int
  | Isint
  | String_length
  | Array_length

type cexpr =
  | Atom of atom
  | Binop of binop * atom * atom
  | Unop of unop * atom
  | MakeBlock of int * atom list
  | AllocReuse of Ident.t * int * atom list
  | MakeArray of Lambda.array_kind * atom list
  | Field of int * atom
  | SetField of int * atom * atom
  | OffsetRef of int * atom
  | StringGet of bool * atom * atom
  | BytesSet of bool * atom * atom * atom
  | ArrayGet of bool * Lambda.array_kind * atom * atom
  | ArraySet of bool * Lambda.array_kind * atom * atom * atom
  | CreateBytes of atom
  | MakeArrayInit of atom * atom
  | App of atom * atom list
  | Builtin of string * Builtins.arg_kind * atom
  | Ccall of string * atom list
  | GetGlobal of string
  | Fun of lfunction
  | Assign of Ident.t * atom

and lfunction = {
  params : (Ident.t * Lambda.value_kind) list;
  body : aexpr;
}

and rec_binding = {
  id : Ident.t;
  def : lfunction;
}

and aexpr =
  | Halt of atom
  | Let of Ident.t * cexpr * aexpr
  | MutLet of Ident.t * cexpr * aexpr
  | LetJoin of Ident.t * aexpr * aexpr
  | LetRec of rec_binding list * aexpr
  | If of atom * aexpr * aexpr
  | Switch of atom * switch_cases
  | StringSwitch of atom * (string * aexpr) list * aexpr option
  | StaticCatch of aexpr * int * Ident.t list * aexpr
  | StaticRaise of int * atom list
  | While of aexpr * aexpr
  | For of Ident.t * atom * atom * Asttypes.direction_flag * aexpr
  | TryWith of aexpr * Ident.t * aexpr
  | Raise of atom
  | CheckExn of aexpr * aexpr
  | Unwind
  | Retain of Ident.t * aexpr
  | Release of Ident.t * aexpr
  | ReleaseMut of Ident.t * aexpr
  | DropReuse of Ident.t * Ident.t * aexpr
  | FreeReuse of Ident.t * aexpr
  | ShadowPush of Ident.t list * Ident.t list * Ident.t list * aexpr
  | ShadowPop of int * int * aexpr

and switch_cases = {
  consts : (int * aexpr) list;
  blocks : (int * aexpr) list;
  fail : aexpr option;
}

type program = {
  module_ident : Ident.t;
  code : aexpr;
}

val of_lambda : ?use_builtins:bool -> Lambda.program -> (program, string) result
val free_vars : aexpr -> Ident.Set.t
