type t

val compile :
  ?on_step:(int -> int -> string -> unit) ->
  ?mode:Build_mode.t ->
  ?debug_info:bool ->
  directory:string ->
  string ->
  (t, string) result

val prepare :
  disabled:bool -> prefer_prebuilt:bool -> prefer_archive:bool ->
  sources:string option -> prebuilt:string option -> work_dir:string ->
  (t, string) result

val prepare_cached :
  ?mode:Build_mode.t ->
  ?debug_info:bool ->
  ?cflags:string list ->
  ?cache_dir:string ->
  ?compiler:string ->
  ?qbe:string ->
  ?target:Target.t ->
  ?toolchain:Target.Toolchain.t ->
  ?verbose:bool ->
  disabled:bool -> prefer_prebuilt:bool -> prefer_archive:bool ->
  sources:string option -> prebuilt:string option -> work_dir:string -> unit ->
  (t, string) result

val interface_dir : t -> string option
val archive : t -> string option
val imports : t -> (string * Anf.exports) list

val link_inputs :
  ?parallel:((string * (unit -> (string, string) result)) list -> (string list, string) result) ->
  ?mode:Build_mode.t ->
  ?debug_info:bool ->
  ?cflags:string list ->
  verbose:bool -> qbe:string -> target:Target.t -> toolchain:Target.Toolchain.t ->
  t -> (string list, string) result
