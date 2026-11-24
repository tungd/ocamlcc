type hasher = {
  file : string -> (Sha256.t, string) result;
  tree : string -> (Sha256.t, string) result;
}

val key : (string * string) list -> Sha256.t
(** Hash ordered, length-prefixed names and values. *)

val fingerprints : ?hasher:hasher -> string list -> ((string * string) list, string) result

type entry = { directory : string; hit : bool }

val peek :
  ?hasher:hasher -> store:string -> key:Sha256.t -> unit -> entry option
(** Check whether a complete, verified entry already exists without creating
    the store or invoking a builder. *)

val ensure :
  ?hasher:hasher -> store:string -> key:Sha256.t -> (string -> (unit, string) result) ->
  (entry, string) result
(** Reuse a complete, verified entry or populate it in a private directory
    and publish it atomically. Builders write their artifacts into the
    supplied directory. *)
