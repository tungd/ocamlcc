type error = { msg : string }

val compile_implementation :
  filename:string -> modname:string -> string -> (Lambda.program, error) result
(** Parse, typecheck, and translmod the given OCaml source. [modname] must be
    the capitalised module name implied by [filename]. *)
