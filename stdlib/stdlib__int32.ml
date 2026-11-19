external raise : exn -> 'a = "%raise"
external neg : int32 -> int32 = "%int32_neg"
external add : int32 -> int32 -> int32 = "%int32_add"
external sub : int32 -> int32 -> int32 = "%int32_sub"
external mul : int32 -> int32 -> int32 = "%int32_mul"
external div : int32 -> int32 -> int32 = "%int32_div"
external rem : int32 -> int32 -> int32 = "%int32_mod"
external logand : int32 -> int32 -> int32 = "%int32_and"
external logor : int32 -> int32 -> int32 = "%int32_or"
external logxor : int32 -> int32 -> int32 = "%int32_xor"
external shift_left : int32 -> int -> int32 = "%int32_lsl"
external shift_right : int32 -> int -> int32 = "%int32_asr"
external shift_right_logical : int32 -> int -> int32 = "%int32_lsr"
external of_int : int -> int32 = "%int32_of_int"
external to_int : int32 -> int = "%int32_to_int"
external of_float : float -> int32 = "caml_int32_of_float"
external to_float : int32 -> float = "caml_int32_to_float"
external bits_of_float : float -> int32 = "caml_int32_bits_of_float"
external float_of_bits : int32 -> float = "caml_int32_float_of_bits"
let of_string = CamlinternalIntFmt.parse_int32
let format = CamlinternalIntFmt.format_int32
external ( < ) : int32 -> int32 -> bool = "%lessthan"
external ( = ) : int32 -> int32 -> bool = "%equal"
external compare : int32 -> int32 -> int = "%compare"

type t = int32

let zero = 0l
let one = 1l
let minus_one = -1l
let max_int = 2147483647l
let min_int = -2147483648l

let succ n = add n 1l
let pred n = sub n 1l
let abs n = if n < 0l then neg n else n
let lognot n = logxor n minus_one
let to_string n = format "%d" n
let equal (a : t) (b : t) = a = b

let of_string_opt s =
  try Some (of_string s) with Failure _ -> None

let min (a : t) (b : t) = if a < b then a else b
let max (a : t) (b : t) = if a < b then b else a
