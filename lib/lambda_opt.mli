module Optimized : sig
  type t = private {
    code : Lambda.lambda;
    scalars : Anf_ir.scalar_rep Ident.Map.t;
    slots : Lambda.value_kind Ident.Map.t;
    value_kinds : Lambda.value_kind Ident.Map.t;
    inline_bodies : Lambda.lfunction Ident.Map.t;
    export_ids : (int list * Ident.t) list;
  }
end

val optimize :
  imports:(string -> Anf_ir.exports option) ->
  selectors:Builtins.int_selection_table Lazy.t option ->
  is_array_initializer:(Lambda.lambda -> bool) ->
  collect_exports:bool ->
  Lambda.lambda ->
  Optimized.t
(** Optimize Lambda and record the representation and export facts ANF needs. *)

val imported_callee_and_unit :
  (string -> Anf_ir.exports option) ->
  Lambda.lambda ->
  (Anf_ir.imported_function * Ident.t) option

val unicode_validations : Lambda.lambda -> Ident.t -> Anf_ir.unicode_validation option
val inline_export_leaves :
  Lambda.lambda -> Anf_ir.aexpr -> Ident.t -> Anf_ir.lfunction option
