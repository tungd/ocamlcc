type t = { root : string; manifest : Ocpkg_format.manifest }
type catalog = {
  root : string;
  digest : Sha256.t;
  recipes : Ocpkg_format.recipe list;
}

val open_workspace : unit -> (t, string) result
val catalog : t -> (catalog, string) result
val root_catalog : unit -> string option
val cache_dir : unit -> (string, string) result
val vendor_dir : t -> string
val make_lock : t -> catalog -> (Ocpkg_format.lock, string) result
val read_lock : t -> (Ocpkg_format.lock, string) result
val write_lock : t -> Ocpkg_format.lock -> (unit, string) result
val write_manifest : t -> (unit, string) result
val archive_cache : unit -> (string, string) result

val initialize : name:string option -> (t, string) result
