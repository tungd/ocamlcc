val compile_program : Lambda.program -> (Qbe_il.module_, string) result
(** Lower a Lambda program to a QBE module. The module body is emitted as the
    exported function [$ocamlcc_module_init]; unsupported Lambda constructs
    return a descriptive error. *)
