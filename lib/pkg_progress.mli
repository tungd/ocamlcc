type t
type scope

val create : enabled:bool -> verbose:bool -> t
val is_tty : t -> bool
val finish : t -> unit
val milestone : t -> string -> unit
val format_duration : float -> string

val start_scope : t -> prefix:string -> total:int -> scope
val task_started : scope -> id:int -> name:string -> unit
val task_detail : scope -> id:int -> string -> unit
val task_finished : ?milestone:string -> id:int -> cached:bool -> scope -> unit
val end_scope : ?summary:string -> scope -> unit
