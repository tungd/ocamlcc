type t
type point = { x : float; y : float }
type user = { name : string; age : int }

exception Bad_arg of int

val create : int -> t
val get : t -> int
val add_pt : point -> point -> point
val greet : user -> string
val opt_inc : int option -> int option
val flip : bool -> bool
val sum_i32_i64 : int32 -> int64 -> int64
val pair_sum : int * int -> int
val check_pos : int -> int
