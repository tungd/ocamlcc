(* Administrative Normal Form (ANF) middle-end IR.

   Every non-trivial subexpression is bound to a named [Ident.t] so
   downstream passes (Perceus ARC dup/drop/reuse, exception lowering, and
   QBE codegen) see explicit evaluation order, liveness boundaries, and
   tail-call positions. *)

type const_item =
  | C_int of int
  | C_char of char
  | C_string of string
  | C_float of float
  | C_int32 of int32
  | C_int64 of int64
  | C_nativeint of nativeint
  | C_float_array of float list
  | C_block of int * const_item list

type atom =
  | Var of Ident.t
  | MutVar of Ident.t
  | Int of int
  | Char of char
  | String of string
  | Float of float
  | Int32 of int32
  | Int64 of int64
  | Nativeint of nativeint
  | ConstFloatArray of float list
  | ConstBlock of int * const_item list
  | Unit

type float_arithmetic = Addf | Subf | Mulf | Divf

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
  | Float_arithmetic of float_arithmetic
  | Fcmp of Lambda.float_comparison
  | Compare_floats
  | Bint_add of Lambda.boxed_integer
  | Bint_sub of Lambda.boxed_integer
  | Bint_mul of Lambda.boxed_integer
  | Bint_div of Lambda.boxed_integer
  | Bint_mod of Lambda.boxed_integer
  | Bint_and of Lambda.boxed_integer
  | Bint_or of Lambda.boxed_integer
  | Bint_xor of Lambda.boxed_integer
  | Bint_lsl of Lambda.boxed_integer
  | Bint_lsr of Lambda.boxed_integer
  | Bint_asr of Lambda.boxed_integer
  | Bint_cmp of Lambda.boxed_integer * Lambda.integer_comparison
  | Compare_bints of Lambda.boxed_integer

type unop =
  | Neg
  | Not
  | Offset of int
  | Isint
  | String_length
  | Array_length
  | Float_of_int
  | Int_of_float
  | Fneg
  | Fabs
  | Bint_of_int of Lambda.boxed_integer
  | Int_of_bint of Lambda.boxed_integer
  | Bint_cvt of Lambda.boxed_integer * Lambda.boxed_integer
  | Bint_neg of Lambda.boxed_integer

type bigarray_access = {
  operation : [ `Get | `Set ];
  rank : int;
  kind : Lambda.bigarray_kind;
  layout : Lambda.bigarray_layout;
  checked : bool;
}

(* Raw doubles are compiler temporaries. Only scalar operations can consume them. *)
type float_operand = Boxed_float of atom | Raw_float of Ident.t

type cexpr =
  | Atom of atom
  | Binop of binop * atom * atom
  | Unop of unop * atom
  | MakeBlock of int * atom list
  | AllocReuse of Ident.t * int * atom list
  | MakeArray of Lambda.array_kind * atom list
  | Field of int * atom
  | SetField of int * atom * atom
  | FloatField of int * atom
  | SetFloatField of int * atom * atom
  | OffsetRef of int * atom
  | StringGet of bool * atom * atom
  | BytesSet of bool * atom * atom * atom
  | ArrayGet of bool * Lambda.array_kind * atom * atom
  | ArraySet of bool * Lambda.array_kind * atom * atom * atom
  | BigarrayAccess of bigarray_access * atom list
  | Float64Load of bigarray_access * atom * atom
  | Float64Store of bigarray_access * atom * atom * float_operand
  | FloatValue of float_operand
  | FloatBinop of float_arithmetic * float_operand * float_operand
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
  | HaltFloat of Ident.t
  | Let of Ident.t * cexpr * aexpr
  | MutLet of Ident.t * cexpr * aexpr
  | LetJoin of Ident.t * aexpr * aexpr
  | LetRec of rec_binding list * aexpr
  | If of atom * aexpr * aexpr
  | FloatIf of atom * aexpr * aexpr
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

val of_lambda :
  ?use_builtins:bool ->
  ?include_dirs:string list ->
  Lambda.program ->
  (program, string) result
val float_operand_vars : Ident.Set.t -> float_operand -> Ident.Set.t
val returns_raw_float : aexpr -> bool
val free_vars : aexpr -> Ident.Set.t
val pure_defs : aexpr -> (Ident.t * lfunction) list
