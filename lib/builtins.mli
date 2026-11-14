type arg_kind =
  | Int_arg    (* tagged 63-bit integer; codegen untags before the call *)
  | String_arg (* raw pointer to a NUL-terminated byte sequence *)

type builtin = { symbol : string; arg_kind : arg_kind }

val resolve : Lambda.lambda -> builtin option
(** [resolve func] maps the Lambda expression [func] (the callee of an
    [Lapply]) to its ocamlcc runtime symbol and argument kind, for known
    Stdlib entry points. *)
