val key : (string * string) list -> Sha256.t
(** Hash ordered, length-prefixed names and values. *)

val fingerprints : ?index:Digest_index.t -> string list -> ((string * string) list, string) result

type entry = { directory : string; hit : bool }

val ensure :
  ?index:Digest_index.t -> store:string -> key:Sha256.t -> (string -> (unit, string) result) ->
  (entry, string) result
(** Reuse a complete, verified entry or populate it in a private directory
    and publish it atomically. Builders write their artifacts into the
    supplied directory. *)
