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

type event =
  | Start of int * string
  | Finish of int * string * bool

val compile :
  tools:Pkg_toolchain.t -> scope:scope -> wrapping:Ocpkg_format.wrapping ->
  exports:string list -> ?cache:string -> ?cflags:string list ->
  ?held:bool -> ?on_event:(int -> event -> unit) ->
  sources:string list -> c_sources:string list ->
  directory:string -> unit -> (output, string) result
