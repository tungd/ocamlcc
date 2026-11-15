val module_name_of_file : string -> string

val compile_file :
  ?include_dirs:string list ->
  ?output_prefix:string ->
  ?emit_cmi:bool ->
  ?nopervasives:bool ->
  ?nostdlib:bool ->
  ?emit_entry:bool ->
  filename:string ->
  modname:string ->
  unit ->
  (string, string) result
(** Compile an OCaml source file to QBE IL text. [modname] defaults to
    [module_name_of_file filename] at the CLI layer. *)

val compile_interface_file :
  ?include_dirs:string list ->
  ?output_prefix:string ->
  ?nopervasives:bool ->
  ?nostdlib:bool ->
  filename:string ->
  modname:string ->
  unit ->
  (string, string) result
(** Compile an OCaml interface file ([.mli]) to a [.cmi] file. *)
