external raise : exn -> 'a = "%raise"
external neg : int64 -> int64 = "%int64_neg"
external add : int64 -> int64 -> int64 = "%int64_add"
external sub : int64 -> int64 -> int64 = "%int64_sub"
external mul : int64 -> int64 -> int64 = "%int64_mul"
external div : int64 -> int64 -> int64 = "%int64_div"
external rem : int64 -> int64 -> int64 = "%int64_mod"
external logand : int64 -> int64 -> int64 = "%int64_and"
external logor : int64 -> int64 -> int64 = "%int64_or"
external logxor : int64 -> int64 -> int64 = "%int64_xor"
external shift_left : int64 -> int -> int64 = "%int64_lsl"
external shift_right : int64 -> int -> int64 = "%int64_asr"
external shift_right_logical : int64 -> int -> int64 = "%int64_lsr"
external of_int : int -> int64 = "%int64_of_int"
external to_int : int64 -> int = "%int64_to_int"
external of_int32 : int32 -> int64 = "%int64_of_int32"
external to_int32 : int64 -> int32 = "%int64_to_int32"
external of_nativeint : nativeint -> int64 = "%int64_of_nativeint"
external to_nativeint : int64 -> nativeint = "%int64_to_nativeint"
external of_float : float -> int64 = "caml_int64_of_float"
external to_float : int64 -> float = "caml_int64_to_float"
external bits_of_float : float -> int64 = "caml_int64_bits_of_float"
external float_of_bits : int64 -> float = "caml_int64_float_of_bits"
external of_string : string -> int64 = "caml_int64_of_string"
external format : string -> int64 -> string = "caml_int64_format"
external ( < ) : int64 -> int64 -> bool = "%lessthan"
external ( = ) : int64 -> int64 -> bool = "%equal"
external compare : int64 -> int64 -> int = "%compare"

type t = int64

let zero = 0L
let one = 1L
let minus_one = -1L
let max_int = 9223372036854775807L
let min_int = -9223372036854775808L

let succ n = add n 1L
let pred n = sub n 1L
let abs n = if n < 0L then neg n else n
let lognot n = logxor n minus_one
let to_string n = format "%d" n
let equal (a : t) (b : t) = a = b

let of_string_opt s =
  try Some (of_string s) with Failure _ -> None

let min (a : t) (b : t) = if a < b then a else b
let max (a : t) (b : t) = if a < b then b else a
