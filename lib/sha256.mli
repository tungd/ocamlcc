type t

val of_hex : string -> (t, string) result
val to_hex : t -> string
val equal : t -> t -> bool

val string : string -> t
val file : string -> (t, string) result

val tree_hash : ?file:(string -> (t, string) result) -> string -> (t, string) result
(** Hash the sorted relative paths, executable bits, and file digests of a
    directory tree. Reject symlinks and special files. *)
