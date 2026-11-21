(* Perceus ARC middle-end pass (design doc §4.2).

   Inserts static retain ([Retain]), release ([Release] / [ReleaseMut]),
   and in-place constructor reuse ([DropReuse] / [AllocReuse] / [FreeReuse])
   instructions over [Anf.program]. *)

val run : Anf.program -> Anf.program

val run_with_effects :
  ?exported:(int list * Ident.t) list -> Anf.program ->
  Anf.program * (Ident.t -> bool * bool * Anf.exception_effect) *
  (Ident.t -> (Ident.t * bool list) option)
(** Look up call effects and the exported alternate entry's ownership mask. *)
