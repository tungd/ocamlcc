val encode : Lambda.lfunction -> string option
val decode : arity:int -> string -> Lambda.lfunction option
(** Closed, bounded Lambda expressions in an export summary. *)
