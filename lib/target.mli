type os = Darwin | Linux | Ios | Ios_sim | Android | Windows

type t = {
  name : string;
  qbe_target : string;
  os : os;
  arch : string;
}

val resolve : string -> (t, string) result
val is_host : t -> bool

module Toolchain : sig
  type t = {
    cc_prog : string;
    cc_base_args : string list;
    ar_prog : string;
  }
end

val toolchain :
  ?cc_path:string -> ?ar_path:string -> ?sysroot:string -> t ->
  (Toolchain.t, string) result

val qbe : string option -> (string, string) result
val runtime_sources : string option -> string option
val prebuilt_runtime : string option -> string option
val stdlib_sources : string option -> string option
val prebuilt_stdlib : string option -> string option
