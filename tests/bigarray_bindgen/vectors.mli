type vector = (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t
type single_vector = (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array1.t
type int64_vector = (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t
type int32_vector = (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t
type matrix = (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array2.t
type cube = (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array3.t
type generic = (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Genarray.t
val matrix : int -> int -> matrix
val cube : int -> int -> int -> cube
val as_genarray : cube -> generic
val generic_rank : generic -> int
val plane : generic -> int -> matrix
val row : matrix -> int -> vector
val create : int -> vector
val sub : vector -> int -> int -> vector
val scale_words : vector -> vector -> float -> int -> float
val conditional_scale_words : vector -> vector -> float -> int -> float
val single_words : single_vector -> int -> float
val create_singles : int -> single_vector
val create_nativeints : int -> (nativeint, Bigarray.nativeint_elt, Bigarray.c_layout) Bigarray.Array1.t
val nativeint_words : (nativeint, Bigarray.nativeint_elt, Bigarray.c_layout) Bigarray.Array1.t -> nativeint -> int -> float
val create_int64 : int -> int64_vector
val create_int32 : int -> int32_vector
val int32_words : int32_vector -> int32 -> int -> float
val int32_bit_words : int32_vector -> int -> float
val int64_words : int64_vector -> int64 -> int -> float
val int64_div_words : int64_vector -> int64 -> int -> float
val save : vector -> unit
val write_saved : float -> unit
val clear : unit -> unit
val leave_cycle : vector -> unit
val collect : unit -> int
val fortran : unit -> (float, Bigarray.float64_elt, Bigarray.fortran_layout) Bigarray.Array1.t
val singles : (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array1.t
val live : unit -> int
