val remove_redundant_checks : Lambda.lambda -> Lambda.lambda
(** Turn guarded indexing into unchecked indexing when the same immutable
    receiver and index are proved in bounds on the current branch. *)
