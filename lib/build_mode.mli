type t = Release | Debug

val to_string : t -> string
val optimize : t -> bool
val cflags : ?debug_info:bool -> t -> string list
