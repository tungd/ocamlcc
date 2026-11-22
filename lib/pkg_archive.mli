val unpack :
  archive:string -> root:Ocpkg_format.Rel_path.t -> into:string ->
  (string, string) result
(** Inspect the complete archive and then extract it into a fresh directory.
    The result names the extracted root. *)
