type fetch = url:string -> destination:string -> (unit, string) result

val resolve :
  catalog:Ocpkg_format.recipe list ->
  Ocpkg_format.requirement list -> (Ocpkg_format.recipe list, string) result
(** Return dependencies before their users. *)

val pin :
  project_root:string -> catalog_root:string ->
  replacements:(Ocpkg_format.Package_name.t * string) list ->
  Ocpkg_format.recipe list -> (Ocpkg_format.recipe list, string) result
(** Verify curated local sources and pin explicit project replacements. *)

val archive :
  fetch:fetch -> offline:bool -> cache:string -> Ocpkg_format.archive ->
  (string, string) result

val verify : vendor:string -> Ocpkg_format.recipe list -> (unit, string) result

val vendor :
  fetch:fetch -> offline:bool -> cache:string -> vendor:string ->
  project_root:string -> catalog_root:string ->
  Ocpkg_format.recipe list -> (unit, string) result
