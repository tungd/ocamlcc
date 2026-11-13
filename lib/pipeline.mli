val module_name_of_file : string -> string

val compile_file :
  filename:string -> modname:string -> (string, string) result
(** Compile an OCaml source file to QBE IL text. [modname] defaults to
    [module_name_of_file filename] at the CLI layer. *)
