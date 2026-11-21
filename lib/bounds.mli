val remove_redundant_checks :
  ?is_array_initializer:(Lambda.lambda -> bool) -> Lambda.lambda -> Lambda.lambda
(** Turn guarded indexing into unchecked indexing when the same immutable
    receiver and index are proved in bounds on the current branch. *)
