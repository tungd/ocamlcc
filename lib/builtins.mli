val resolve : Lambda.lambda -> string option
(** [resolve func] maps the Lambda expression [func] (the callee of an
    [Lapply]) to its ocamlcc runtime symbol, for known Stdlib entry points. *)
