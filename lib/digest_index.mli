(** Memoize file digests using filesystem identity and change timestamps. *)
type t

val with_index :
  cache:string -> workspace:string -> verify:bool -> (t -> 'a) -> 'a

val file : t -> string -> (Sha256.t, string) result
val tree : t -> string -> (Sha256.t, string) result

type delta

val reset_updates : t -> unit
val take_updates : t -> delta
val merge_updates : t -> delta -> unit
