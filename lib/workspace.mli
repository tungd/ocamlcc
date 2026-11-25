module Product : sig
  type t =
    | Native of { target : string; kind : Ocpkg_format.kind option }
    | Xcframework
end

type options = {
  product : Product.t;
  output : string option;
  single_thread : bool;
  verbose : bool;
  verify_cache : bool;
  emit_header : string option;
  jobs : int;
  progress : bool;
  mode : Build_mode.t;
  debug_info : bool option;
}

val defaults : options
val build : Pkg_project.t -> options -> (string, string) result
val publish : Pkg_project.t -> options -> into:string -> names:string list ->
  (string list, string) result
(** Build the locked dependency packages and copy their artifacts into
    [into/<name>/]: per-unit [.cmi]/[.o]/[.exports]/[.opt] files, the package
    archive with its [.a.opt] summary, the [units] list, and an [ldflags] file
    carrying the recipe link flags. With [names = []] every locked package is
    published; otherwise the named packages (which must be in the lock). *)
val run : Pkg_project.t -> options -> string list -> (unit, string) result
val test : Pkg_project.t -> options -> string list -> string list -> (unit, string) result
