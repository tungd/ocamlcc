include module type of struct include Anf_ir end

val lower :
  ?use_builtins:bool ->
  ?include_dirs:string list ->
  ?stdlib_dir:string ->
  ?imports:(string * exports) list ->
  ?load_exports:(string -> exports option) ->
  ?nonsuspending_externals:string list ->
  collect_exports:bool ->
  Lambda.program ->
  (program * (int list * Ident.t) list, string) result

val of_lambda :
  ?use_builtins:bool ->
  ?include_dirs:string list ->
  ?stdlib_dir:string ->
  Lambda.program ->
  (program, string) result
