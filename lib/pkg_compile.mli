type scope = {
  visible : string list;
  hidden : string list;
  archives : string list;
  package_keys : Sha256.t list;
}

type output = {
  objects : string list;
  units : string list;
  compiled : int;
  hits : int;
}

val compile :
  tools:Pkg_toolchain.t -> scope:scope -> wrapping:Ocpkg_format.wrapping ->
  exports:string list -> ?cache:string -> sources:string list -> c_sources:string list ->
  directory:string -> unit -> (output, string) result
