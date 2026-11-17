type arg_kind =
  | Int_arg    (* tagged 63-bit integer; codegen untags before the call *)
  | String_arg (* raw pointer to a NUL-terminated byte sequence *)

type builtin = { symbol : string; arg_kind : arg_kind }

type table

val load : ?include_dirs:string list -> unit -> table
(** [load ?include_dirs ()] reads [stdlib.cmi] from [include_dirs] (falling
    back to [Config.standard_library]) and computes the runtime slot indices
    for known [Stdlib] entry points directly from its signature without
    compiling probe snippets. *)

val resolve : ?table:table -> Lambda.lambda -> builtin option
(** [resolve ?table func] maps the Lambda expression [func] (the callee of an
    [Lapply]) to its ocamlcc runtime symbol and argument kind, for known
    Stdlib entry points. *)
