(** Direct-call facts for separately linked units. *)

(** Give externally consumed entries implementation-specific link symbols. *)
val seal : ?dbgfile:string -> Qbe_il.module_ -> Anf.exports -> string * Anf.exports

val write_unit : prefix:string -> Anf.exports -> unit
val write_archive : archive:string -> units:string list -> unit
val write_unit_object : string -> unit
val publish_object : unit_name:string -> cmi:string -> obj:string -> Anf.exports -> unit
val find_archive : string -> string option

module Loader : sig
  type t

  val create : ?archive:string -> ?archives:string list -> ?exclude_units:string list -> unit -> t

  val lookup : t -> unit_name:string -> cmi:string -> Anf.exports option
  (** Read on demand using the CMI selected by the frontend. Missing, malformed
      or mismatched metadata leaves a call on the closure path. *)
end
