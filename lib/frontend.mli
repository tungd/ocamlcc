type error = { msg : string }

val compile_implementation :
  ?include_dirs:string list ->
  ?output_prefix:string ->
  ?emit_cmi:bool ->
  ?nopervasives:bool ->
  ?nostdlib:bool ->
  filename:string ->
  modname:string ->
  string ->
  (Lambda.program, error) result
(** Parse, typecheck, and translmod the given OCaml source. [modname] must be
    the capitalised module name implied by [filename]. *)

val compile_interface :
  ?include_dirs:string list ->
  ?output_prefix:string ->
  ?nopervasives:bool ->
  ?nostdlib:bool ->
  filename:string ->
  modname:string ->
  string ->
  (string, error) result
(** Parse, typecheck, and write [.cmi] for an OCaml [.mli] interface file.
    Returns the path to the written [.cmi] file. *)
