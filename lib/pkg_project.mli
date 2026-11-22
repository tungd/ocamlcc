type t = { root : string; manifest : Ocpkg_format.manifest }
module Catalog : sig
  type t
end

val open_workspace : unit -> (t, string) result
val catalog : t -> (Catalog.t, string) result
val root_catalog : unit -> string option
val cache_dir : unit -> (string, string) result
val vendor_dir : t -> string
val make_lock : t -> Catalog.t -> (Ocpkg_format.lock, string) result
val read_lock : ?missing:Ocpkg_format.lock -> t -> (Ocpkg_format.lock, string) result
val write_lock : t -> Ocpkg_format.lock -> (unit, string) result

val initialize : name:string option -> (t, string) result

val with_dependencies : t -> (t -> ('a, string) result) -> ('a, string) result
(** Read the manifest and use the dependency tree under a shared project lock. *)

val add : fetch:Pkg_vendor.fetch -> t -> string list -> (Ocpkg_format.requirement list, string) result
val remove : t -> string list -> (unit, string) result
val upgrade : fetch:Pkg_vendor.fetch -> t -> string list -> (unit, string) result
val tidy : t -> (unit, string) result
val vendor : fetch:Pkg_vendor.fetch -> offline:bool -> t -> (int, string) result
