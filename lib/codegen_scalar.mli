open Qbe_il

val load_double : Codegen_ctx.t -> t -> t
val box_double : Codegen_ctx.t -> t -> t
val unbox_bint : Codegen_ctx.t -> Lambda.boxed_integer -> t -> t
val box_bint : Codegen_ctx.t -> Lambda.boxed_integer -> t -> t

val scalar_type : Anf.scalar_rep -> ty
val scalar_store : ty -> store_op

val float_binop : Codegen_ctx.t -> boxed:bool -> Anf.float_arithmetic -> t -> t -> t
val float_compare : Codegen_ctx.t -> boxed:bool -> Lambda.float_comparison -> t -> t -> t
val compare_floats : Codegen_ctx.t -> t -> t -> t
val float_sign : Codegen_ctx.t -> [ `Neg | `Abs ] -> t -> t
val float_of_int : Codegen_ctx.t -> t -> t
val int_of_float : Codegen_ctx.t -> t -> t

val integer_binop :
  Codegen_ctx.t -> boxed:bool -> Lambda.boxed_integer -> Anf.integer_arithmetic ->
  t -> t -> t

val integer_compare :
  Codegen_ctx.t -> boxed:bool -> Lambda.boxed_integer -> Anf.integer_relation ->
  t -> t -> t

val integer_shift :
  Codegen_ctx.t -> boxed:bool -> Lambda.boxed_integer -> Anf.integer_shift -> t -> t -> t

val integer_neg : Codegen_ctx.t -> boxed:bool -> Lambda.boxed_integer -> t -> t
val integer_of_int : Codegen_ctx.t -> Lambda.boxed_integer -> t -> t
val int_of_integer : Codegen_ctx.t -> Lambda.boxed_integer -> t -> t
val convert_integer : Codegen_ctx.t -> Lambda.boxed_integer -> Lambda.boxed_integer -> t -> t

val load_bigarray : Codegen_ctx.t -> Anf.bigarray_access -> (ty * t) list -> t
val store_bigarray :
  Codegen_ctx.t -> Anf.bigarray_access -> (ty * t) list -> Anf.scalar_rep -> t -> t
