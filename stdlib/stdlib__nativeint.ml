external raise : exn -> 'a = "%raise"
external neg : nativeint -> nativeint = "%nativeint_neg"
external add : nativeint -> nativeint -> nativeint = "%nativeint_add"
external sub : nativeint -> nativeint -> nativeint = "%nativeint_sub"
external mul : nativeint -> nativeint -> nativeint = "%nativeint_mul"
external div : nativeint -> nativeint -> nativeint = "%nativeint_div"
external rem : nativeint -> nativeint -> nativeint = "%nativeint_mod"
external logand : nativeint -> nativeint -> nativeint = "%nativeint_and"
external logor : nativeint -> nativeint -> nativeint = "%nativeint_or"
external logxor : nativeint -> nativeint -> nativeint = "%nativeint_xor"
external shift_left : nativeint -> int -> nativeint = "%nativeint_lsl"
external shift_right : nativeint -> int -> nativeint = "%nativeint_asr"
external shift_right_logical : nativeint -> int -> nativeint = "%nativeint_lsr"
external of_int : int -> nativeint = "%nativeint_of_int"
external to_int : nativeint -> int = "%nativeint_to_int"
external of_int32 : int32 -> nativeint = "%nativeint_of_int32"
external to_int32 : nativeint -> int32 = "%nativeint_to_int32"
external of_float : float -> nativeint = "caml_nativeint_of_float"
external to_float : nativeint -> float = "caml_nativeint_to_float"
external of_string : string -> nativeint = "caml_nativeint_of_string"
external format : string -> nativeint -> string = "caml_nativeint_format"
external ( < ) : nativeint -> nativeint -> bool = "%lessthan"
external ( = ) : nativeint -> nativeint -> bool = "%equal"
external compare : nativeint -> nativeint -> int = "%compare"

type t = nativeint

let size = 64
let zero = 0n
let one = 1n
let minus_one = -1n
let max_int = shift_right_logical minus_one 1
let min_int = add max_int 1n

let succ n = add n 1n
let pred n = sub n 1n
let abs n = if n < 0n then neg n else n
let lognot n = logxor n minus_one
let to_string n = format "%d" n
let equal (a : t) (b : t) = a = b

let of_string_opt s =
  try Some (of_string s) with Failure _ -> None

let min (a : t) (b : t) = if a < b then a else b
let max (a : t) (b : t) = if a < b then b else a
