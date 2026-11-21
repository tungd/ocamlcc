val entry_point : string list -> Qbe_il.func
(** Executable entry point for dependency-ordered compilation units. *)

val compile_program : ?emit_entry:bool -> Anf.program -> Qbe_il.module_
(** Lower an ANF program to a QBE module. Emits [$ocamlcc_global_<Mod>]
    and [$ocamlcc_init_<Mod>()]; when [~emit_entry] is true (default),
    also exports [$ocamlcc_module_init] for the C [main] shim. *)

val compile_with_exports :
  ?emit_entry:bool ->
  ?inline_single_thread_rc:bool ->
  exported:(int list * Ident.t) list ->
  effects:(Ident.t -> bool * bool * bool) ->
  inline_leaf:(Ident.t -> Anf.lfunction option) ->
  Anf.program -> Qbe_il.module_ * Anf.exports
