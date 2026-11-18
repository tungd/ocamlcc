type vector = (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t
type matrix = (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array2.t
val matrix : int -> int -> matrix
val row : matrix -> int -> vector
val create : int -> vector
val sub : vector -> int -> int -> vector
val fortran : unit -> (float, Bigarray.float64_elt, Bigarray.fortran_layout) Bigarray.Array1.t
val singles : (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array1.t
val live : unit -> int
