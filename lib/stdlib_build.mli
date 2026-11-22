type t

val prepare :
  disabled:bool -> prefer_prebuilt:bool -> prefer_archive:bool ->
  sources:string option -> prebuilt:string option -> work_dir:string ->
  (t, string) result

val interface_dir : t -> string option
val archive : t -> string option
val imports : t -> (string * Anf.exports) list

val link_inputs :
  verbose:bool -> qbe:string -> target:Target.t -> toolchain:Target.Toolchain.t ->
  t -> (string list, string) result
