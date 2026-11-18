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
    Bigarray.Array1 and Bigarray.Array2 views, ARC retain/release,
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
