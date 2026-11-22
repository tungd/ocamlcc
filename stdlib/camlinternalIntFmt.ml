(**************************************************************************)
(*                                                                        *)
(*   Pure OCaml integer formatting and parsing for ocamlcc                *)
(*   Compiled with --nopervasives right after CamlinternalFormatBasics.   *)
(*                                                                        *)
(**************************************************************************)

external raise : exn -> 'a = "%raise"
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external not : bool -> bool = "%boolnot"
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"
external ( ~- ) : int -> int = "%negint"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( lsl ) : int -> int -> int = "%lslint"

external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"

external string_length : string -> int = "%string_length"
external string_unsafe_get : string -> int -> char = "%string_unsafe_get"
external bytes_create : int -> bytes = "caml_create_bytes"
external bytes_unsafe_get : bytes -> int -> char = "%bytes_unsafe_get"
external bytes_unsafe_set : bytes -> int -> char -> unit = "%bytes_unsafe_set"
external bytes_unsafe_to_string : bytes -> string = "%bytes_to_string"

external i64_neg : int64 -> int64 = "%int64_neg"
external i64_add : int64 -> int64 -> int64 = "%int64_add"
external i64_sub : int64 -> int64 -> int64 = "%int64_sub"
external i64_mul : int64 -> int64 -> int64 = "%int64_mul"
external i64_div : int64 -> int64 -> int64 = "%int64_div"
external i64_rem : int64 -> int64 -> int64 = "%int64_mod"
external i64_and : int64 -> int64 -> int64 = "%int64_and"
external i64_xor : int64 -> int64 -> int64 = "%int64_xor"
external i64_lsr : int64 -> int -> int64 = "%int64_lsr"
external i64_of_int : int -> int64 = "%int64_of_int"
external i64_to_int : int64 -> int = "%int64_to_int"
external i64_of_int32 : int32 -> int64 = "%int64_of_int32"
external i64_to_int32 : int64 -> int32 = "%int64_to_int32"
external i64_of_nativeint : nativeint -> int64 = "%int64_of_nativeint"
external i64_to_nativeint : int64 -> nativeint = "%int64_to_nativeint"

let i64_min_int = -9223372036854775808L

let u64_lt (a : int64) (b : int64) =
  i64_xor a i64_min_int < i64_xor b i64_min_int

let u64_le (a : int64) (b : int64) =
  not (u64_lt b a)

let u64_divmod10 (u : int64) : int64 * int =
  if u >= 0L then (i64_div u 10L, i64_to_int (i64_rem u 10L))
  else
    let q = i64_div (i64_lsr u 1) 5L in
    let r = i64_sub u (i64_mul q 10L) in
    (q, i64_to_int r)

let digit_char upper d =
  if d < 10 then char_of_int (48 + d)
  else if upper then char_of_int (65 + d - 10)
  else char_of_int (97 + d - 10)

type unsigned_width = Word | Bits32 | Bits64

let format_u64 fmt (v : int64) unsigned_width : string =
  let len = string_length fmt in
  if len < 2 || string_unsafe_get fmt 0 <> '%' then ""
  else
    let rec check_nul i =
      if i >= len then false
      else if string_unsafe_get fmt i = '\000' then true
      else check_nul (i + 1)
    in
    if check_nul 0 then ""
    else
      let rec parse_flags i left plus space alt zero =
        if i >= len then (i, left, plus, space, alt, zero)
        else
          match string_unsafe_get fmt i with
          | '-' -> parse_flags (i + 1) true plus space alt zero
          | '+' -> parse_flags (i + 1) left true space alt zero
          | ' ' -> parse_flags (i + 1) left plus true alt zero
          | '#' -> parse_flags (i + 1) left plus space true zero
          | '0' -> parse_flags (i + 1) left plus space alt true
          | _ -> (i, left, plus, space, alt, zero)
      in
      let rec parse_num i acc overflow =
        if i >= len then (i, acc, overflow)
        else
          let c = string_unsafe_get fmt i in
          if c >= '0' && c <= '9' then
            let d = int_of_char c - 48 in
            if acc > 1000000 then parse_num (i + 1) acc true
            else parse_num (i + 1) (acc * 10 + d) overflow
          else (i, acc, overflow)
      in
      let i, left, plus, space, alt, zero =
        parse_flags 1 false false false false false
      in
      let i, width, width_ovr = parse_num i 0 false in
      let i, has_prec, prec, prec_ovr =
        if i < len && string_unsafe_get fmt i = '.' then
          let i2, p, pov = parse_num (i + 1) 0 false in
          (i2, true, p, pov)
        else (i, false, 0, false)
      in
      if width_ovr || prec_ovr || width > 1000000 || prec > 1000000 then ""
      else
        let i =
          if i + 1 < len
             && string_unsafe_get fmt i = 'l'
             && string_unsafe_get fmt (i + 1) = 'l'
          then i + 2
          else if i < len then
            match string_unsafe_get fmt i with
            | 'l' | 'L' | 'n' -> i + 1
            | _ -> i
          else i
        in
        if i + 1 <> len then ""
        else
          let conv = string_unsafe_get fmt i in
          let valid_conv, is_signed, base, upper =
            match conv with
            | 'd' | 'i' -> (true, true, 10, false)
            | 'u' -> (true, false, 10, false)
            | 'x' -> (true, false, 16, false)
            | 'X' -> (true, false, 16, true)
            | 'o' -> (true, false, 8, false)
            | _ -> (false, false, 10, false)
          in
          if not valid_conv then ""
          else
            let neg, mag =
              if is_signed then
                if v < 0L then (true, i64_neg v) else (false, v)
              else
                let magnitude = match unsigned_width with
                  | Word -> i64_and v 0x7FFFFFFFFFFFFFFFL
                  | Bits32 -> i64_and v 0xFFFFFFFFL
                  | Bits64 -> v
                in
                (false, magnitude)
            in
            let digits_rev, ndigits =
              if mag = 0L then
                if has_prec && prec = 0 then ([], 0) else ([ '0' ], 1)
              else
                let rec extract u acc n =
                  if u = 0L then (acc, n)
                  else if base = 10 then
                    let q, r = u64_divmod10 u in
                    extract q (digit_char upper r :: acc) (n + 1)
                  else if base = 16 then
                    let r = i64_to_int (i64_and u 15L) in
                    extract (i64_lsr u 4) (digit_char upper r :: acc) (n + 1)
                  else
                    let r = i64_to_int (i64_and u 7L) in
                    extract (i64_lsr u 3) (digit_char upper r :: acc) (n + 1)
                in
                extract mag [] 0
            in
            let zero_digits = if prec > ndigits then prec - ndigits else 0 in
            let oct_leading_zero =
              alt && conv = 'o'
              && zero_digits = 0
              && (match digits_rev with '0' :: _ -> false | _ -> true)
            in
            let zero_digits =
              if oct_leading_zero then zero_digits + 1 else zero_digits
            in
            let pfx_len, pfx0, pfx1 =
              if is_signed then
                if neg then (1, '-', '\000')
                else if plus then (1, '+', '\000')
                else if space then (1, ' ', '\000')
                else (0, '\000', '\000')
              else if alt && mag <> 0L && conv = 'x' then (2, '0', 'x')
              else if alt && mag <> 0L && conv = 'X' then (2, '0', 'X')
              else (0, '\000', '\000')
            in
            let core_len = pfx_len + zero_digits + ndigits in
            let pad_len = if width > core_len then width - core_len else 0 in
            let zero_pad = zero && (not left) && (not has_prec) in
            let left_spaces = if (not left) && (not zero_pad) then pad_len else 0 in
            let pad_zeros = if zero_pad then pad_len else 0 in
            let right_spaces = if left then pad_len else 0 in
            let total_len = core_len + pad_len in
            let out = bytes_create total_len in
            let rec fill_char idx n ch =
              if n <= 0 then idx
              else (
                bytes_unsafe_set out idx ch;
                fill_char (idx + 1) (n - 1) ch)
            in
            let rec fill_list idx = function
              | [] -> idx
              | ch :: rest ->
                  bytes_unsafe_set out idx ch;
                  fill_list (idx + 1) rest
            in
            let pos = fill_char 0 left_spaces ' ' in
            let pos =
              if pfx_len = 1 then (bytes_unsafe_set out pos pfx0; pos + 1)
              else if pfx_len = 2 then (
                bytes_unsafe_set out pos pfx0;
                bytes_unsafe_set out (pos + 1) pfx1;
                pos + 2)
              else pos
            in
            let pos = fill_char pos (pad_zeros + zero_digits) '0' in
            let pos = fill_list pos digits_rev in
            let _ = fill_char pos right_spaces ' ' in
            bytes_unsafe_to_string out

let format_int fmt n = format_u64 fmt (i64_of_int n) Word
let format_int32 fmt n = format_u64 fmt (i64_of_int32 n) Bits32
let format_int64 fmt n = format_u64 fmt n Bits64
let format_nativeint fmt n = format_u64 fmt (i64_of_nativeint n) Bits64

let parse_digit c =
  let k = int_of_char c in
  if k >= 48 && k <= 57 then k - 48
  else if k >= 65 && k <= 90 then k - 55
  else if k >= 97 && k <= 122 then k - 87
  else -1

let max_div_base base =
  if base = 10 then (1844674407370955161L, 5)
  else if base = 16 then (0x0fffffffffffffffL, 15)
  else if base = 8 then (0x1fffffffffffffffL, 7)
  else (0x7fffffffffffffffL, 1)

let parse_u64 (s : string) (err_msg : string) : bool * bool * int64 =
  let len = string_length s in
  if len = 0 then raise (Failure err_msg);
  let c0 = string_unsafe_get s 0 in
  let neg, i =
    if c0 = '-' then (true, 1)
    else if c0 = '+' then (false, 1)
    else (false, 0)
  in
  if i >= len then raise (Failure err_msg);
  let base, unsigned_mode, i =
    if i + 1 < len && string_unsafe_get s i = '0' then
      match string_unsafe_get s (i + 1) with
      | 'x' | 'X' -> (16, true, i + 2)
      | 'o' | 'O' -> (8, true, i + 2)
      | 'b' | 'B' -> (2, true, i + 2)
      | 'u' | 'U' -> (10, true, i + 2)
      | _ -> (10, false, i)
    else (10, false, i)
  in
  let limit_q, limit_r = max_div_base base in
  let base64 = i64_of_int base in
  let rec loop pos seen acc =
    if pos >= len then
      if not seen then raise (Failure err_msg) else acc
    else
      let c = string_unsafe_get s pos in
      if c = '_' then
        if not seen then raise (Failure err_msg) else loop (pos + 1) seen acc
      else
        let d = parse_digit c in
        if d < 0 || d >= base then raise (Failure err_msg)
        else if u64_lt limit_q acc || (acc = limit_q && d > limit_r) then
          raise (Failure err_msg)
        else
          let next = i64_add (i64_mul acc base64) (i64_of_int d) in
          loop (pos + 1) true next
  in
  let uv = loop i false 0L in
  (neg, unsigned_mode, uv)

let parse_int s =
  let neg, unsigned_mode, uv = parse_u64 s "int_of_string" in
  let limit =
    if unsigned_mode then 0x7FFFFFFFFFFFFFFFL
    else if neg then 0x4000000000000000L
    else 0x3FFFFFFFFFFFFFFFL
  in
  if not (u64_le uv limit) then raise (Failure "int_of_string");
  let sv = if neg then i64_neg uv else uv in
  i64_to_int sv

let parse_int32 s =
  let neg, unsigned_mode, uv = parse_u64 s "Int32.of_string" in
  let limit =
    if unsigned_mode then 0xFFFFFFFFL
    else if neg then 0x80000000L
    else 0x7FFFFFFFL
  in
  if not (u64_le uv limit) then raise (Failure "Int32.of_string");
  let sv = if neg then i64_neg uv else uv in
  i64_to_int32 sv

let parse_int64 s =
  let neg, unsigned_mode, uv = parse_u64 s "Int64.of_string" in
  (if not unsigned_mode then
     let limit = if neg then 0x8000000000000000L else 0x7FFFFFFFFFFFFFFFL in
     if not (u64_le uv limit) then raise (Failure "Int64.of_string"));
  if neg then i64_neg uv else uv

let parse_nativeint s =
  let neg, unsigned_mode, uv = parse_u64 s "Nativeint.of_string" in
  (if not unsigned_mode then
     let limit = if neg then 0x8000000000000000L else 0x7FFFFFFFFFFFFFFFL in
     if not (u64_le uv limit) then raise (Failure "Nativeint.of_string"));
  let sv = if neg then i64_neg uv else uv in
  i64_to_nativeint sv
