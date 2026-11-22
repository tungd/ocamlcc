type generated = {
  header : string; (* C99 .h header *)
  shim_c : string; (* C99 FFI shim implementation *)
  exported_symbols : string list; (* public C API symbols declared in header *)
}

val generate :
  ?include_dirs:string list ->
  ?nopervasives:bool ->
  ?nostdlib:bool ->
  ?header_include:string ->
  filename:string ->
  modname:string ->
  string ->
  (generated, string) result
(** Walk a typed [.mli] signature via [Typemod.type_interface] and emit a C99
    header + FFI shim covering exported [val]s, basic types, [option], tuples,
    records (regular and all-float), opaque abstract types, direct concrete
    Bigarray Array1, Array2, Array3, and Genarray views, ARC retain/release,
    module initialization, and an explicit [ocamlcc_error_t *] out-parameter. *)

val generate_file :
  ?include_dirs:string list ->
  ?nopervasives:bool ->
  ?nostdlib:bool ->
  ?header_include:string ->
  filename:string ->
  modname:string ->
  unit ->
  (generated, string) result
(** Convenience wrapper reading [filename] from disk before calling [generate]. *)

type headers = { shim_files : string list; symbols : string list }

val generate_headers :
  include_dirs:string list -> nopervasives:bool -> nostdlib:bool ->
  work_dir:string -> output:string -> (string * string) list ->
  (headers, string) result
(** Generate headers and shims for ordered [(module_name, filename)] pairs.
    With multiple interfaces, [output] is an umbrella header. *)
