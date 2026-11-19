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
external caml_format_float : string -> float -> string = "caml_format_float"
let caml_int32_format = CamlinternalIntFmt.format_int32
let caml_int64_format = CamlinternalIntFmt.format_int64
let caml_nativeint_format = CamlinternalIntFmt.format_nativeint
external caml_print_string : string -> unit = "ocamlcc_print_string_val"
external caml_prerr_string : string -> unit = "ocamlcc_prerr_string_val"

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

let pad_string pad_dir width fill_ch s =
  let len = S.length s in
  if width <= len then s
  else
    let pad = S.make (width - len) fill_ch in
    match pad_dir with
    | Left -> S.cat s pad
    | Right | Zeros -> S.cat pad s

let format_int_padded iconv pad_opt prec n =
  let base, upper, is_signed =
    match iconv with
    | Int_d | Int_pd | Int_sd | Int_i | Int_pi | Int_si | Int_Cd | Int_Ci ->
        (10, false, true)
    | Int_u | Int_Cu -> (10, false, false)
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
  let prec_abs = if prec < 0 then -prec else prec in
  let blen = S.length body in
  let digits =
    if prec_abs <= blen then body
    else S.cat (S.make (prec_abs - blen) '0') body
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
  let prefix = S.cat sign_prefix alt_prefix in
  match pad_opt with
  | None -> S.cat prefix digits
  | Some (dir, width) -> (
      if width < 0 then pad_string Left (-width) ' ' (S.cat prefix digits)
      else
        match dir with
        | Left | Right -> pad_string dir width ' ' (S.cat prefix digits)
        | Zeros ->
            let plen = S.length prefix in
            let dlen = S.length digits in
            if width <= plen + dlen then S.cat prefix digits
            else S.cat prefix (S.cat (S.make (width - plen - dlen) '0') digits))

let with_pad_spec :
    type x y.
    (x, y) padding -> ((padty * int) option -> y) -> x =
  fun pad k ->
  match pad with
  | No_padding -> k None
  | Lit_padding (dir, width) -> k (Some (dir, width))
  | Arg_padding dir -> fun width -> k (Some (dir, width))

let with_prec_spec :
    type x y.
    (x, y) precision -> (int -> y) -> x =
  fun prec k ->
  match prec with
  | No_precision -> k 0
  | Lit_precision p -> k p
  | Arg_precision -> fun p -> k p

let with_opt_prec_spec :
    type x y.
    (x, y) precision -> (int option -> y) -> x =
  fun prec k ->
  match prec with
  | No_precision -> k None
  | Lit_precision p -> k (Some p)
  | Arg_precision -> fun p -> k (Some p)

let pos_int_str n =
  let rec go acc v =
    let d = v mod 10 in
    let acc' = char_of_int (48 + d) :: acc in
    if v < 10 then acc' else go acc' (v / 10)
  in
  let cs = go [] n in
  let b = BY.create (Stdlib__list.length cs) in
  let rec fill i = function
    | [] -> BY.unsafe_to_string b
    | c :: rest -> BY.unsafe_set b i c; fill (i + 1) rest
  in
  fill 0 cs

let build_c_fmt flag spec pad_opt prec_opt =
  let b = B.create 16 in
  B.add_char b '%';
  B.add_string b flag;
  (match pad_opt with
  | None -> ()
  | Some (dir, width) ->
      let dir, w = if width < 0 then (Left, -width) else (dir, width) in
      (match dir with
      | Left -> B.add_char b '-'
      | Zeros -> B.add_char b '0'
      | Right -> ());
      B.add_string b (pos_int_str w));
  (match prec_opt with
  | Some p when p >= 0 ->
      B.add_char b '.';
      B.add_string b (pos_int_str p)
  | _ -> ());
  B.add_char b spec;
  B.contents b

let int_conv_c_spec = function
  | Int_d | Int_i | Int_Cd | Int_Ci -> ("", 'd')
  | Int_pd | Int_pi -> ("+", 'd')
  | Int_sd | Int_si -> (" ", 'd')
  | Int_u | Int_Cu -> ("", 'u')
  | Int_x -> ("", 'x')
  | Int_Cx -> ("#", 'x')
  | Int_X -> ("", 'X')
  | Int_CX -> ("#", 'X')
  | Int_o | Int_Co -> ("", 'o')

let format_boxed_int fmt_fn iconv pad_opt prec n =
  let flag, spec_ch = int_conv_c_spec iconv in
  let prec_opt = if prec > 0 then Some prec else None in
  let fmt = build_c_fmt flag spec_ch pad_opt prec_opt in
  let s = fmt_fn fmt n in
  match iconv with
  | Int_Co when s <> "0" -> S.cat "0o" s
  | _ -> s

let valid_float_lexem s =
  let len = S.length s in
  let rec has_dot_or_exp i =
    if i >= len then false
    else
      let c = S.unsafe_get s i in
      c = '.' || c = 'e' || c = 'E' || has_dot_or_exp (i + 1)
  in
  if s = "inf" then "infinity"
  else if s = "-inf" then "neg_infinity"
  else if s = "+inf" then "+infinity"
  else if s = "nan" || s = "-nan" then "nan"
  else if has_dot_or_exp 0 then s
  else S.cat s "."

let format_float_padded (fflag, fkind) pad_opt prec_opt f =
  let sign_flag =
    match fflag with
    | Float_flag_ -> ""
    | Float_flag_p -> "+"
    | Float_flag_s -> " "
  in
  match fkind with
  | Float_F | Float_CF ->
      let prec =
        match prec_opt with Some p when p >= 0 -> p | _ -> 12
      in
      let cfmt = build_c_fmt sign_flag 'g' None (Some prec) in
      let raw = valid_float_lexem (caml_format_float cfmt f) in
      (match pad_opt with
      | None -> raw
      | Some (dir, width) ->
          let dir, w = if width < 0 then (Left, -width) else (dir, width) in
          let ch = match dir with Zeros -> '0' | Left | Right -> ' ' in
          pad_string dir w ch raw)
  | _ ->
      let spec =
        match fkind with
        | Float_f -> 'f'
        | Float_e -> 'e'
        | Float_E -> 'E'
        | Float_g -> 'g'
        | Float_G -> 'G'
        | Float_h -> 'a'
        | Float_H -> 'A'
        | Float_F | Float_CF -> 'g'
      in
      let fmt = build_c_fmt sign_flag spec pad_opt prec_opt in
      caml_format_float fmt f

let format_with_padding :
    type x y.
    (x, y) padding -> ((string -> string) -> y) -> x =
  fun pad k ->
  with_pad_spec pad (fun pad_opt ->
      let pfn s =
        match pad_opt with
        | None -> s
        | Some (dir, width) ->
            if width < 0 then pad_string Left (-width) ' ' s
            else
              let ch = match dir with Zeros -> '0' | Left | Right -> ' ' in
              pad_string dir width ch s
      in
      k pfn)

let add_escaped_char ~in_string buf c =
  match c with
  | '"' when in_string -> B.add_string buf "\\\""
  | '\'' when not in_string -> B.add_string buf "\\'"
  | '\\' -> B.add_string buf "\\\\"
  | '\n' -> B.add_string buf "\\n"
  | '\r' -> B.add_string buf "\\r"
  | '\t' -> B.add_string buf "\\t"
  | '\b' -> B.add_string buf "\\b"
  | _ ->
      let code = int_of_char c in
      if code >= 32 && code <= 126 then B.add_char buf c
      else begin
        B.add_char buf '\\';
        B.add_char buf (char_of_int (48 + (code / 100)));
        B.add_char buf (char_of_int (48 + ((code / 10) mod 10)));
        B.add_char buf (char_of_int (48 + (code mod 10)))
      end

let format_caml_char c =
  let b = B.create 6 in
  B.add_char b '\'';
  add_escaped_char ~in_string:false b c;
  B.add_char b '\'';
  B.contents b

let format_caml_string s =
  let len = S.length s in
  let b = B.create (len + 2) in
  B.add_char b '"';
  for i = 0 to len - 1 do
    add_escaped_char ~in_string:true b (S.unsafe_get s i)
  done;
  B.add_char b '"';
  B.contents b

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
      fun c -> make_printf k (Acc_data_string (acc, format_caml_char c)) rest
  | String (pad, rest) ->
      format_with_padding pad (fun pfn s ->
          make_printf k (Acc_data_string (acc, pfn s)) rest)
  | Caml_string (pad, rest) ->
      format_with_padding pad (fun pfn s ->
          make_printf k (Acc_data_string (acc, pfn (format_caml_string s))) rest)
  | Bool (pad, rest) ->
      format_with_padding pad (fun pfn b ->
          let s = if b then "true" else "false" in
          make_printf k (Acc_data_string (acc, pfn s)) rest)
  | Int (iconv, pad, prec, rest) ->
      with_pad_spec pad (fun pad_opt ->
          with_prec_spec prec (fun p n ->
              let s = format_int_padded iconv pad_opt p n in
              make_printf k (Acc_data_string (acc, s)) rest))
  | Int32 (iconv, pad, prec, rest) ->
      with_pad_spec pad (fun pad_opt ->
          with_prec_spec prec (fun p n ->
              let s = format_boxed_int caml_int32_format iconv pad_opt p n in
              make_printf k (Acc_data_string (acc, s)) rest))
  | Nativeint (iconv, pad, prec, rest) ->
      with_pad_spec pad (fun pad_opt ->
          with_prec_spec prec (fun p n ->
              let s = format_boxed_int caml_nativeint_format iconv pad_opt p n in
              make_printf k (Acc_data_string (acc, s)) rest))
  | Int64 (iconv, pad, prec, rest) ->
      with_pad_spec pad (fun pad_opt ->
          with_prec_spec prec (fun p n ->
              let s = format_boxed_int caml_int64_format iconv pad_opt p n in
              make_printf k (Acc_data_string (acc, s)) rest))
  | Float (fconv, pad, prec, rest) ->
      with_pad_spec pad (fun pad_opt ->
          with_opt_prec_spec prec (fun prec_opt f ->
              let s = format_float_padded fconv pad_opt prec_opt f in
              make_printf k (Acc_data_string (acc, s)) rest))
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

let printf_to out_fn (Format (fmt, _)) =
  let b = B.create 64 in
  make_printf
    (fun acc ->
      output_to_buffer b acc;
      out_fn (B.contents b))
    End_of_acc fmt

let printf fmt = printf_to caml_print_string fmt

let eprintf fmt = printf_to caml_prerr_string fmt
