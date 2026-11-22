val collect_pure_defs : Anf.aexpr -> (Ident.t * Anf.lfunction) list

val free_vars_of :
  Codegen_ctx.t -> ?self_id:Ident.t -> Anf.lfunction -> Ident.t list

val tail_callees : ?arities:(Ident.t * int) list -> Anf.aexpr -> Ident.Set.t

val strongly_connected_components :
  Ident.t list -> (Ident.t -> Ident.Set.t) -> Ident.t list list

val collect_globals : string -> Anf.aexpr -> string list
