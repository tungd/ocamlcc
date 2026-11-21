val module_name_of_file : string -> string

val compile_source :
  ?include_dirs:string list ->
  ?stdlib_dir:string ->
  ?output_prefix:string ->
  ?emit_cmi:bool ->
  ?nopervasives:bool ->
  ?nostdlib:bool ->
  ?no_alias_deps:bool ->
  ?nolabels:bool ->
  ?open_modules:string list ->
  ?emit_entry:bool ->
  ?inline_single_thread_rc:bool ->
  filename:string ->
  modname:string ->
  ?imports:(string * Anf.exports) list ->
  ?load_exports:(unit_name:string -> cmi:string -> Anf.exports option) ->
  ?on_interface:(string -> unit) ->
  ?on_exports:(Anf.exports -> unit) ->
  ?seal_exports:bool ->
  string ->
  (string, string) result
(** Compile an in-memory OCaml source string to QBE IL text. *)

val compile_file :
  ?include_dirs:string list ->
  ?stdlib_dir:string ->
  ?output_prefix:string ->
  ?emit_cmi:bool ->
  ?nopervasives:bool ->
  ?nostdlib:bool ->
  ?no_alias_deps:bool ->
  ?nolabels:bool ->
  ?open_modules:string list ->
  ?emit_entry:bool ->
  ?inline_single_thread_rc:bool ->
  filename:string ->
  modname:string ->
  ?imports:(string * Anf.exports) list ->
  ?load_exports:(unit_name:string -> cmi:string -> Anf.exports option) ->
  ?on_interface:(string -> unit) ->
  ?on_exports:(Anf.exports -> unit) ->
  ?seal_exports:bool ->
  unit ->
  (string, string) result
(** Compile an OCaml source file to QBE IL text. [modname] defaults to
    [module_name_of_file filename] at the CLI layer. *)

val compile_interface_file :
  ?include_dirs:string list ->
  ?output_prefix:string ->
  ?nopervasives:bool ->
  ?nostdlib:bool ->
  ?no_alias_deps:bool ->
  ?nolabels:bool ->
  ?open_modules:string list ->
  filename:string ->
  modname:string ->
  unit ->
  (string, string) result
(** Compile an OCaml interface file ([.mli]) to a [.cmi] file. *)
