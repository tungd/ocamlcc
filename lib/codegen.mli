val compile_program : ?emit_entry:bool -> Anf.program -> Qbe_il.module_
(** Lower an ANF program to a QBE module. Emits [$ocamlcc_global_<Mod>]
    and [$ocamlcc_init_<Mod>()]; when [~emit_entry] is true (default),
    also exports [$ocamlcc_module_init] for the C [main] shim. *)
