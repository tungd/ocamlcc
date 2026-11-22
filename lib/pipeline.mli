val module_name_of_file : string -> string

module Request : sig
  type export_policy = Omit | Collect | Seal

  type t = {
    filename : string;
    modname : string;
    include_dirs : string list;
    stdlib_dir : string option;
    output_prefix : string option;
    emit_cmi : bool;
    nopervasives : bool;
    nostdlib : bool;
    no_alias_deps : bool;
    nolabels : bool;
    open_modules : string list;
    emit_entry : bool;
    inline_single_thread_rc : bool;
    imports : (string * Anf.exports) list;
    summaries : Export_summary.Loader.t option;
    export_policy : export_policy;
  }

  val create : filename:string -> modname:string -> t
end

module Output : sig
  type t = {
    ssa : string;
    interface : string option;
    exports : Anf.exports;
  }
end

val compile_source : Request.t -> string -> (Output.t, string) result
(** Compile an in-memory OCaml implementation. The output includes its emitted
    or selected CMI, when present, and the requested cross-unit facts. *)

val compile_file : Request.t -> (Output.t, string) result
(** Read and compile an OCaml implementation file. *)

val compile_interface_file : Request.t -> (string, string) result
(** Compile an OCaml interface file and return the path to its CMI. *)
