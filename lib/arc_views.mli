val can_borrow_arguments :
  is_immediate:(Anf.atom -> bool) -> is_borrowed:(Ident.t -> bool) ->
  Ident.Set.t -> bool list -> Anf.atom list -> bool

val fuse_field_read :
  can_borrow:(Ident.Set.t -> bool list -> Anf.atom list -> bool) ->
  borrowed_flags:(Ident.t -> bool list option) -> yielding:Ident.Set.t ->
  stable:bool -> Ident.t -> int -> Anf.atom -> Anf.aexpr -> Anf.aexpr option

val field_is_read_only_in_loop : Ident.t -> Anf.aexpr -> bool
val read_only_slot_snapshot : Ident.t -> Ident.t -> Anf.aexpr -> bool

val mutable_slot_result :
  Ident.t Ident.Map.t -> Anf.aexpr -> (Ident.t * int option * Anf.aexpr) option

val inject_reuse : Ident.t -> Anf.aexpr -> Anf.aexpr option
