module Program_facts : sig
  type t = private {
    pure : Ident.Set.t;
    known_funs : int Ident.Map.t;
    yielding : Ident.Set.t;
    raising : Ident.Set.t;
    ordinary_raising : Ident.Set.t;
    imm_funs : int Ident.Map.t;
    typed_imm : Ident.Set.t;
    exported : Ident.Set.t;
  }

  val analyze : exported:(int list * Ident.t) list -> Anf.program -> t
  val with_worker : original:Ident.t -> worker:Ident.t -> arity:int -> t -> t
  val effects : t -> Ident.t -> bool * bool * Anf.exception_effect
end

val atom_vars : Anf.atom -> Ident.Set.t
val atoms_vars : Anf.atom list -> Ident.Set.t
val atom_operands : Anf.cexpr -> Ident.Set.t * Anf.atom list

val atom_is_imm : pure:Ident.Set.t -> Ident.Set.t -> Anf.atom -> bool
val cexpr_is_imm :
  pure:Ident.Set.t -> imm_funs:int Ident.Map.t -> Ident.Set.t -> Anf.cexpr -> bool

val imm_params_of : Anf.lfunction -> Ident.Set.t
val set_imm : Ident.Set.t -> Ident.t -> bool -> Ident.Set.t

val aexpr_returns_imm :
  typed_imm:Ident.Set.t -> pure:Ident.Set.t -> imm_funs:int Ident.Map.t ->
  Ident.Set.t -> Anf.aexpr -> bool

val handler_immediates :
  typed_imm:Ident.Set.t -> pure:Ident.Set.t -> imm_funs:int Ident.Map.t ->
  Ident.Set.t -> int -> Ident.t list -> Anf.aexpr -> Ident.Set.t

val mutlet_is_imm :
  typed_imm:Ident.Set.t -> pure:Ident.Set.t -> imm_funs:int Ident.Map.t ->
  Ident.Set.t -> Ident.t -> Anf.cexpr -> Anf.aexpr -> bool

val borrow_flags : Anf.lfunction -> Ident.Set.t -> bool list
val read_only_parameters :
  borrowed:(Ident.t -> bool list option) -> Anf.lfunction -> Ident.Set.t
val recursive_borrows :
  yielding:Ident.Set.t -> borrowed:(Ident.t -> bool list option) ->
  Anf.rec_binding list -> bool list Ident.Map.t

val operation_can_raise :
  finalizers:bool -> int Ident.Map.t -> Ident.Set.t -> Anf.cexpr -> bool
val call_can_suspend : int Ident.Map.t -> Ident.Set.t -> Anf.cexpr -> bool
val can_raise_with : (Anf.cexpr -> bool) -> Anf.aexpr -> bool
