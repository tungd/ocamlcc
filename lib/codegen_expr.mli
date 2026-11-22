type fn_hooks = {
  closure_value : Codegen_ctx.t -> Ident.t -> Qbe_il.t;
  compile_fun_binding :
    (Codegen_ctx.t -> bool -> Anf.aexpr -> Qbe_il.t) ->
    Codegen_ctx.t ->
    bool ->
    Ident.t ->
    Anf.lfunction ->
    Anf.aexpr ->
    Qbe_il.t;
  compile_letrec :
    (Codegen_ctx.t -> bool -> Anf.aexpr -> Qbe_il.t) ->
    Codegen_ctx.t ->
    bool ->
    Anf.rec_binding list ->
    Anf.aexpr ->
    Qbe_il.t;
}

val compile_aexpr : fn_hooks -> Codegen_ctx.t -> bool -> Anf.aexpr -> Qbe_il.t
