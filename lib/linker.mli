type mode = Static | Executable | Shared of string list option

module Request : sig
  type t = {
    mode : mode;
    target : Target.t;
    toolchain : Target.Toolchain.t;
    work_dir : string;
    output : string;
    user_objects : string list;
    internal_objects : string list;
    extra_ldflags : string list;
    verbose : bool;
  }
end

val compile_source :
  verbose:bool -> Target.Toolchain.t -> string list -> string -> string ->
  (unit, string) result

val link : Request.t -> (string, string) result

val xcframework :
  verbose:bool -> work_dir:string -> output:string -> header:string option ->
  string list -> (string, string) result
