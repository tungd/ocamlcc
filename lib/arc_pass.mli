(* Perceus ARC middle-end pass (design doc §4.2).

   Inserts static retain ([Retain]), release ([Release] / [ReleaseMut]),
   and in-place constructor reuse ([DropReuse] / [AllocReuse] / [FreeReuse])
   instructions over [Anf.program]. *)

val run : Anf.program -> Anf.program

val run_with_effects : Anf.program -> Anf.program * (Ident.t -> bool * bool)
(** The returned lookup reports suspension and immediate result, respectively. *)
