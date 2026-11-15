type t

exception Lib_err of int

val create : int -> t
val get : t -> int
val square : int -> int
val pair_sum : int * int -> int
val make_adder : int -> int -> int
val check : int -> int
