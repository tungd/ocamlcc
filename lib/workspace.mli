type options = {
  target : string;
  kind : Ocpkg_format.kind option;
  output : string option;
  single_thread : bool;
  verbose : bool;
  verify_cache : bool;
  xcframework : bool;
  emit_header : string option;
}

val defaults : options
val build : Pkg_project.t -> options -> (string, string) result
val run : Pkg_project.t -> options -> string list -> (unit, string) result
val test : Pkg_project.t -> options -> string list -> string list -> (unit, string) result
