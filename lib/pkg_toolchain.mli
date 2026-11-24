type t = {
  target : Target.t;
  commands : Target.Toolchain.t;
  qbe : string;
  stdlib : string;
  fingerprint : Sha256.t;
  single_thread : bool;
  mode : Build_mode.t;
  debug_info : bool;
  cflags : string list;
  verbose : bool;
  cache : string;
  index : Digest_index.t;
  pool : Pkg_parallel.Pool.t;
  progress : Pkg_progress.t;
}

val compiler_binary : unit -> string option
val prepare :
  index:Digest_index.t -> cache:string -> target:string -> single_thread:bool -> cflags:string list -> verbose:bool ->
  ?mode:Build_mode.t -> ?debug_info:bool ->
  ?pool:Pkg_parallel.Pool.t -> ?held:bool -> ?progress:Pkg_progress.t -> unit ->
  (t, string) result

val runtime : ?held:bool -> t -> include_main:bool -> (string list, string) result
val stdlib_link_inputs : t -> archive:bool -> string list
val assemble : t -> string -> string -> (unit, string) result
val compile_c : t -> flags:string list -> string -> string -> (unit, string) result
val archive : t -> string -> string list -> (unit, string) result
