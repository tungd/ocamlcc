(** Direct-call facts for separately linked stdlib archives. Unit records
    are produced with the SSA and collected when the archive is built. *)

val write_unit : prefix:string -> Anf.exports -> unit
val write_archive : archive:string -> units:string list -> unit
val find_archive : string -> string option

(** Missing, malformed, or mismatched metadata yields closure dispatch.
    The interface resolved in [include_dirs] must match the producer's. *)
val read_archive : include_dirs:string list -> string -> (string * Anf.exports) list
