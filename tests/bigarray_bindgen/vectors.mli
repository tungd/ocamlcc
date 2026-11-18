type vector = (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t
val create : int -> vector
val sub : vector -> int -> int -> vector
val fortran : unit -> (float, Bigarray.float64_elt, Bigarray.fortran_layout) Bigarray.Array1.t
val singles : (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array1.t
val live : unit -> int
