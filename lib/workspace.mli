type options = {
  target : string;
  kind : Ocpkg_format.kind option;
  output : string option;
  single_thread : bool;
  verbose : bool;
}

val defaults : options
val build : Pkg_project.t -> options -> (string, string) result
val run : Pkg_project.t -> options -> string list -> (unit, string) result
val test : Pkg_project.t -> options -> string list -> (unit, string) result
