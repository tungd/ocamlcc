(* Perceus ARC middle-end pass (design doc §4.2).

   Inserts static retain ([Retain]), release ([Release] / [ReleaseMut]),
   and in-place constructor reuse ([DropReuse] / [AllocReuse] / [FreeReuse])
   instructions over [Anf.program]. *)

val run : Anf.program -> Anf.program
