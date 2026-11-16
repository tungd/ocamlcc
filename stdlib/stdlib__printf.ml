external raise : exn -> 'a = "%raise"
external ( ~- ) : int -> int = "%negint"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( mod ) : int -> int -> int = "%modint"
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"
external not : bool -> bool = "%boolnot"
external ( land ) : int -> int -> int = "%andint"
external ( lsr ) : int -> int -> int = "%lsrint"
external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"
external caml_print_string : string -> unit = "ocamlcc_print_string_val"

open CamlinternalFormatBasics
module B = Stdlib__buffer
module S = Stdlib__string
module BY = Stdlib__bytes

type ('b, 'c) acc_elem =
  | Acc_formatting_lit of ('b, 'c) acc * formatting_lit
  | Acc_string_literal of ('b, 'c) acc * string
  | Acc_char_literal of ('b, 'c) acc * char
  | Acc_data_string of ('b, 'c) acc * string
  | Acc_data_char of ('b, 'c) acc * char
  | Acc_delay of ('b, 'c) acc * ('b -> 'c)
  | Acc_flush of ('b, 'c) acc
  | Acc_invalid_arg of ('b, 'c) acc * string
  | End_of_acc

and ('b, 'c) acc = ('b, 'c) acc_elem

let format_int iconv n =
  let base, upper, is_signed =
    match iconv with
    | Int_d | Int_pd | Int_sd | Int_i | Int_pi | Int_si -> (10, false, true)
    | Int_u -> (10, false, false)
    | Int_x | Int_Cx -> (16, false, false)
    | Int_X | Int_CX -> (16, true, false)
    | Int_o | Int_Co -> (8, false, false)
  in
  let sign_prefix =
    if is_signed then
      if n < 0 then "-"
      else
        match iconv with
        | Int_pd | Int_pi -> "+"
        | Int_sd | Int_si -> " "
        | _ -> ""
    else ""
  in
  let digit_char d =
    if d < 10 then char_of_int (48 + d)
    else if upper then char_of_int (55 + d)
    else char_of_int (87 + d)
  in
  let rec signed_neg_digits acc v =
    if v = 0 then acc
    else signed_neg_digits (digit_char (-(v mod base)) :: acc) (v / base)
  in
  let rec pos_digits acc v =
    if v = 0 then acc
    else pos_digits (digit_char (v mod base) :: acc) (v / base)
  in
  let unsigned_digits v =
    if v >= 0 then pos_digits [] v
    else
      (* v < 0 represents 2^63 + v; shift right by 1 to stay <= max_int. *)
      let h = v lsr 1 in
      let q0 = h / base in
      let r0 = h mod base in
      let rem2 = (2 * r0) + (v land 1) in
      let q = (q0 * 2) + (rem2 / base) in
      let d = rem2 mod base in
      pos_digits [ digit_char d ] q
  in
  let body =
    if n = 0 then "0"
    else
      let ds =
        if is_signed then signed_neg_digits [] (if n < 0 then n else -n)
        else unsigned_digits n
      in
      let b = BY.create (Stdlib__list.length ds) in
      let rec fill i = function
        | [] -> BY.unsafe_to_string b
        | c :: cs -> BY.unsafe_set b i c; fill (i + 1) cs
      in
      fill 0 ds
  in
  let alt_prefix =
    if n = 0 then ""
    else
      match iconv with
      | Int_Cx -> "0x"
      | Int_CX -> "0X"
      | Int_Co -> "0o"
      | _ -> ""
  in
  S.cat sign_prefix (S.cat alt_prefix body)

let pad_string pad_dir width fill_ch s =
  let len = S.length s in
  if width <= len then s
  else
    let pad = S.make (width - len) fill_ch in
    match pad_dir with
    | Left -> S.cat s pad
    | Right | Zeros -> S.cat pad s

let format_with_padding :
    type x y.
    (x, y) padding -> ((string -> string) -> y) -> x =
  fun pad k ->
  match pad with
  | No_padding -> k (fun s -> s)
  | Lit_padding (Zeros, width) -> k (fun s -> pad_string Zeros width '0' s)
  | Lit_padding ((Left | Right as dir), width) ->
      k (fun s -> pad_string dir width ' ' s)
  | Arg_padding Zeros ->
      fun width -> k (fun s -> pad_string Zeros width '0' s)
  | Arg_padding (Left | Right as dir) ->
      fun width -> k (fun s -> pad_string dir width ' ' s)

let rec make_printf :
    type a b c d e f.
    ((b, c) acc -> f) ->
    (b, c) acc ->
    (a, b, c, d, e, f) fmt ->
    a =
  fun k acc fmt ->
  match fmt with
  | Char rest ->
      fun c -> make_printf k (Acc_data_char (acc, c)) rest
  | Caml_char rest ->
      fun c -> make_printf k (Acc_data_string (acc, S.make 1 c)) rest
  | String (pad, rest) ->
      format_with_padding pad (fun pfn s ->
          make_printf k (Acc_data_string (acc, pfn s)) rest)
  | Caml_string (pad, rest) ->
      format_with_padding pad (fun pfn s ->
          let q = S.cat "\"" (S.cat s "\"") in
          make_printf k (Acc_data_string (acc, pfn q)) rest)
  | Bool (pad, rest) ->
      format_with_padding pad (fun pfn b ->
          let s = if b then "true" else "false" in
          make_printf k (Acc_data_string (acc, pfn s)) rest)
  | Int (iconv, pad, No_precision, rest) ->
      format_with_padding pad (fun pfn n ->
          make_printf k (Acc_data_string (acc, pfn (format_int iconv n))) rest)
  | Int (iconv, pad, Lit_precision _, rest) ->
      format_with_padding pad (fun pfn n ->
          make_printf k (Acc_data_string (acc, pfn (format_int iconv n))) rest)
  | Int (iconv, pad, Arg_precision, rest) ->
      format_with_padding pad (fun pfn _prec n ->
          make_printf k (Acc_data_string (acc, pfn (format_int iconv n))) rest)
  | Flush rest ->
      make_printf k (Acc_flush acc) rest
  | String_literal (s, rest) ->
      make_printf k (Acc_string_literal (acc, s)) rest
  | Char_literal (c, rest) ->
      make_printf k (Acc_char_literal (acc, c)) rest
  | Alpha rest ->
      fun pr x ->
        make_printf k (Acc_delay (acc, fun b -> pr b x)) rest
  | Theta rest ->
      fun pr ->
        make_printf k (Acc_delay (acc, fun b -> pr b)) rest
  | Formatting_lit (flit, rest) ->
      make_printf k (Acc_formatting_lit (acc, flit)) rest
  | End_of_format -> k acc
  | Int32 _ | Nativeint _ | Int64 _ | Float _
  | Format_arg _ | Format_subst _ | Formatting_gen _
  | Reader _ | Scan_char_set _ | Scan_get_counter _ | Scan_next_char _
  | Ignored_param _ | Custom _ ->
      raise (Invalid_argument "Printf: unsupported format specifier")

let emit_formatting_lit b = function
  | Close_box | Close_tag | FFlush | Magic_size _ | Scan_indic _ -> ()
  | Break (s, _, _) -> B.add_string b s
  | Force_newline | Flush_newline -> B.add_char b '\n'
  | Escaped_at -> B.add_char b '@'
  | Escaped_percent -> B.add_char b '%'

let rec output_to_buffer b = function
  | End_of_acc -> ()
  | Acc_formatting_lit (p, flit) ->
      output_to_buffer b p;
      emit_formatting_lit b flit
  | Acc_string_literal (p, s) -> output_to_buffer b p; B.add_string b s
  | Acc_char_literal (p, c) -> output_to_buffer b p; B.add_char b c
  | Acc_data_string (p, s) -> output_to_buffer b p; B.add_string b s
  | Acc_data_char (p, c) -> output_to_buffer b p; B.add_char b c
  | Acc_delay (p, f) -> output_to_buffer b p; f b
  | Acc_flush p -> output_to_buffer b p
  | Acc_invalid_arg (p, msg) -> output_to_buffer b p; raise (Invalid_argument msg)

let rec output_to_string_acc b = function
  | End_of_acc -> ()
  | Acc_formatting_lit (p, flit) ->
      output_to_string_acc b p;
      emit_formatting_lit b flit
  | Acc_string_literal (p, s) -> output_to_string_acc b p; B.add_string b s
  | Acc_char_literal (p, c) -> output_to_string_acc b p; B.add_char b c
  | Acc_data_string (p, s) -> output_to_string_acc b p; B.add_string b s
  | Acc_data_char (p, c) -> output_to_string_acc b p; B.add_char b c
  | Acc_delay (p, f) -> output_to_string_acc b p; B.add_string b (f ())
  | Acc_flush p -> output_to_string_acc b p
  | Acc_invalid_arg (p, msg) -> output_to_string_acc b p; raise (Invalid_argument msg)

let kbprintf k b (Format (fmt, _)) =
  make_printf (fun acc -> output_to_buffer b acc; k b) End_of_acc fmt

let bprintf b fmt = kbprintf (fun _ -> ()) b fmt

let ksprintf k (Format (fmt, _)) =
  let b = B.create 64 in
  make_printf (fun acc -> output_to_string_acc b acc; k (B.contents b)) End_of_acc fmt

let sprintf fmt = ksprintf (fun s -> s) fmt

let kprintf k fmt = ksprintf k fmt

let printf (Format (fmt, _)) =
  let b = B.create 64 in
  make_printf
    (fun acc ->
      output_to_buffer b acc;
      caml_print_string (B.contents b))
    End_of_acc fmt

let eprintf fmt = printf fmt
