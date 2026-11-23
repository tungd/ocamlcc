(* Administrative Normal Form (ANF) middle-end IR.

   Every non-trivial subexpression is bound to a named [Ident.t] so
   downstream passes (Perceus ARC dup/drop/reuse, exception lowering, and
   QBE codegen) see explicit evaluation order, liveness boundaries, and
   tail-call positions. ARC may fuse an immutable projection into a read
   operand while keeping its owner live. *)

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

type exception_effect = No_raise | Finalizer_raise | May_raise

type atom =
  | Var of Ident.t
  | MutVar of Ident.t
  | ModuleSlot of Ident.t * Lambda.value_kind
  | BorrowedField of int * atom
      (** Read-only operand introduced by ARC. Its base stays live through
          the operation that reads it. It carries no reference of its own. *)
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

type integer_arithmetic = Add_int | Sub_int | Mul_int | Div_int | Rem_int | And_int | Or_int | Xor_int

type integer_shift = Left_shift | Logical_right | Arithmetic_right

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
  | Bint_arith of Lambda.boxed_integer * integer_arithmetic
  | Bint_shift of Lambda.boxed_integer * integer_shift
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

(* Unboxed scalars are compiler temporaries. Only scalar operations can consume them. *)
type scalar_rep = Double_scalar | Integer_scalar of Lambda.boxed_integer

type integer_relation = Predicate of Lambda.integer_comparison | Three_way

type scalar_operand = Boxed_scalar of atom | Raw_scalar of Ident.t

module Byte_store : sig
  type t = Uint16 of atom | Int32 of scalar_operand | Int64 of scalar_operand

  val width : t -> int
end

module Byte_load : sig
  type t =
    | Uint16
    | Boxed_word of Builtins.Byte_access.word
    | Raw_word of Builtins.Byte_access.word
end

type field_kind = Immediate_field | Immutable_field | Mutable_field
type block_scan = Scan_all | Scan_if_managed | Scan_none

type reuse = { primary : Ident.t; fallback : Ident.t option }

type cexpr =
  | Atom of atom
  | Binop of binop * atom * atom
  | IntSelect of Builtins.int_selection * atom * atom
  | Unop of unop * atom
  | MakeBlock of int * block_scan * atom list
  | AllocReuse of reuse * int * block_scan * atom list
  | MakeArray of Lambda.array_kind * atom list
  | Field of int * field_kind * atom
  | SetField of int * Lambda.immediate_or_pointer * atom * atom
  | FloatField of int * atom
  | SetFloatField of int * atom * scalar_operand
  | SetBoxedFloatField of int * atom * scalar_operand
  | OffsetRef of int * atom
  | StringGet of bool * atom * atom
  | BytesSet of bool * atom * atom * atom
  | BytesGetN of bool * Byte_load.t * atom * atom
  | BytesSetN of bool * atom * atom * Byte_store.t
  | Bswap16 of atom
  | BswapBint of Lambda.boxed_integer * atom
  | ArrayGet of bool * Lambda.array_kind * atom * atom
  | ArraySet of bool * Lambda.array_kind * atom * atom * atom
  | BigarrayAccess of bigarray_access * atom list
  | ScalarLoad of bigarray_access * atom * atom
  | ScalarStore of bigarray_access * atom * atom * scalar_operand
  | ScalarValue of scalar_rep * scalar_operand
  | BoxScalar of scalar_rep * scalar_operand
  | FloatArrayGet of bool * atom * atom
  | FloatArraySet of bool * atom * atom * scalar_operand
  | FloatOfInt of atom
  | IntOfFloat of scalar_operand
  | FloatSign of [ `Neg | `Abs ] * scalar_operand
  | FloatCompare of Lambda.float_comparison * scalar_operand * scalar_operand
  | FloatBinop of float_arithmetic * scalar_operand * scalar_operand
  | IntegerBinop of Lambda.boxed_integer * integer_arithmetic * scalar_operand * scalar_operand
  | IntegerCompare of Lambda.boxed_integer * integer_relation * scalar_operand * scalar_operand
  | IntegerOfInt of Lambda.boxed_integer * atom
  | IntOfInteger of Lambda.boxed_integer * scalar_operand
  | IntegerConvert of Lambda.boxed_integer * Lambda.boxed_integer * scalar_operand
  | IntegerNeg of Lambda.boxed_integer * scalar_operand
  | IntegerShift of Lambda.boxed_integer * integer_shift * scalar_operand * atom
  | CreateBytes of atom
  | MakeArrayInit of atom * atom
  | App of atom * atom list
  | Recur of atom list
  | KeepAlive of atom list
  | DirectApp of imported_function * atom list
  | Builtin of string * Builtins.arg_kind * atom
  | Ccall of string * atom list
  | PollFinalizers
  | LoopPollDue of atom * atom
  | NativeCcall of Primitive.description * atom list
  | GetGlobal of string
  | ImportDependency of string
  | StoreModuleSlot of Ident.t * atom
  | Fun of lfunction
  | Assign of Ident.t * atom
  | AssignImm of Ident.t * atom
  | ReadScalarSlot of scalar_rep * Ident.t
  | AssignScalar of Ident.t * scalar_rep * scalar_operand

and unicode_validation = Unicode_test | Unicode_check

and imported_function = {
  unit_name : string;
  symbol : string;
  arity : int;
  yields : bool;
  raises : exception_effect;
  returns_immediate : bool;
  borrowed_entry : (string * bool list) option;
  inline_leaf : lfunction option;
  inline_lambda : Lambda.lfunction option;
  unicode_validation : unicode_validation option;
}

and lfunction = {
  params : (Ident.t * Lambda.value_kind) list;
  return : Lambda.value_kind;
  private_entry : bool;
  periodic_poll : bool;
  loop_scalars : (Ident.t * (scalar_rep * Ident.t)) list;
  body : aexpr;
}

and rec_binding = {
  id : Ident.t;
  def : lfunction;
}

and aexpr =
  | Halt of atom
  | HaltScalar of Ident.t
  | Let of Ident.t * cexpr * aexpr
  | MutLet of Ident.t * cexpr * aexpr
  | LetJoin of Ident.t * aexpr * aexpr
  | LetRec of rec_binding list * aexpr
  | If of atom * aexpr * aexpr
  | ScalarIf of scalar_rep * atom * aexpr * aexpr
  | Switch of atom * switch_cases
  | StringSwitch of atom * (string * aexpr) list * aexpr option
  | StaticCatch of aexpr * int * Ident.t list * aexpr * scalar_rep option
  | StaticRaise of int * atom list
  | While of aexpr * aexpr
  | For of Ident.t * atom * atom * Asttypes.direction_flag * aexpr
  | TryWith of aexpr * Ident.t * aexpr
  | Raise of atom
  | CheckExn of exception_effect * aexpr * aexpr
  | Unwind
  | Retain of Ident.t * aexpr
  | Release of Ident.t * aexpr
  | ReleaseMut of Ident.t * aexpr
  | DropReuse of Ident.t * Ident.t * aexpr
  | FreeReuse of Ident.t * aexpr
  | ShadowPush of Ident.t list * Ident.t list * Ident.t list * aexpr
  | ShadowPop of int * int * aexpr

and switch_cases = {
  result_rep : scalar_rep option;
  consts : (int * aexpr) list;
  blocks : (int * aexpr) list;
  fail : aexpr option;
}

type exports = (int list * imported_function) list

val native_scalar : Primitive.native_repr -> scalar_rep option

type program = {
  module_ident : Ident.t;
  code : aexpr;
  value_kinds : Lambda.value_kind Ident.Map.t;
  inline_bodies : Lambda.lfunction Ident.Map.t;
}

val scalar_rep : Lambda.bigarray_kind -> scalar_rep option
val scalar_operand_vars : Ident.Set.t -> scalar_operand -> Ident.Set.t
val byte_store_vars : ?include_raw:bool -> Ident.Set.t -> Byte_store.t -> Ident.Set.t
val returns_scalar : aexpr -> bool
val free_vars : aexpr -> Ident.Set.t
val bound_parameters : lfunction -> Ident.t list

val pure_defs : aexpr -> (Ident.t * lfunction) list

val scalar_layout : Lambda.bigarray_layout -> bool
module Variables : sig
  val atom : Ident.Set.t -> atom -> Ident.Set.t
  val computation :
    ?include_raw:bool ->
    (aexpr -> Ident.Set.t) ->
    Ident.Set.t ->
    cexpr ->
    Ident.Set.t
end
