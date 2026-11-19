external raise : exn -> 'a = "%raise"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"
external not : bool -> bool = "%boolnot"
external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"

external length : bytes -> int = "%bytes_length"
external string_length : string -> int = "%string_length"
external get : bytes -> int -> char = "%bytes_safe_get"
external unsafe_get : bytes -> int -> char = "%bytes_unsafe_get"
external string_unsafe_get : string -> int -> char = "%string_unsafe_get"
external set : bytes -> int -> char -> unit = "%bytes_safe_set"
external unsafe_set : bytes -> int -> char -> unit = "%bytes_unsafe_set"
external create : int -> bytes = "caml_create_bytes"
let unsafe_blit = CamlinternalBulkOps.blit_bytes
let unsafe_blit_string = CamlinternalBulkOps.blit_string
let unsafe_fill = CamlinternalBulkOps.fill_bytes
external unsafe_to_string : bytes -> string = "%bytes_to_string"
external unsafe_of_string : string -> bytes = "%bytes_of_string"
let equal = CamlinternalBulkOps.bytes_equal
let compare = CamlinternalBulkOps.bytes_compare

let invalid_arg s = raise (Invalid_argument s)

let make n c =
  let s = create n in
  unsafe_fill s 0 n c;
  s

let init n f =
  let s = create n in
  for i = 0 to n - 1 do
    unsafe_set s i (f i)
  done;
  s

let empty = create 0

let copy s =
  let len = length s in
  let r = create len in
  unsafe_blit s 0 r 0 len;
  r

let to_string b = unsafe_to_string (copy b)

let of_string s =
  let n = string_length s in
  let b = create n in
  unsafe_blit_string s 0 b 0 n;
  b

let sub s ofs len =
  if ofs < 0 || len < 0 || ofs > length s - len then
    invalid_arg "String.sub / Bytes.sub"
  else begin
    let r = create len in
    unsafe_blit s ofs r 0 len;
    r
  end

let sub_string b ofs len = unsafe_to_string (sub b ofs len)

let fill s ofs len c =
  if ofs < 0 || len < 0 || ofs > length s - len then
    invalid_arg "String.fill / Bytes.fill"
  else
    unsafe_fill s ofs len c

let blit src srcoff dst dstoff len =
  if len < 0 || srcoff < 0 || srcoff > length src - len
     || dstoff < 0 || dstoff > length dst - len
  then invalid_arg "Bytes.blit"
  else unsafe_blit src srcoff dst dstoff len

let blit_string src srcoff dst dstoff len =
  if len < 0 || srcoff < 0 || srcoff > string_length src - len
     || dstoff < 0 || dstoff > length dst - len
  then invalid_arg "Bytes.blit_string"
  else unsafe_blit_string src srcoff dst dstoff len

let cat s1 s2 =
  let l1 = length s1 and l2 = length s2 in
  let r = create (l1 + l2) in
  unsafe_blit s1 0 r 0 l1;
  unsafe_blit s2 0 r l1 l2;
  r

let concat sep l =
  match l with
  | [] -> empty
  | hd :: tl ->
      let seplen = length sep in
      let rec total_len acc = function
        | [] -> acc
        | x :: xs -> total_len (acc + seplen + length x) xs
      in
      let dst = create (total_len (length hd) tl) in
      let hlen = length hd in
      unsafe_blit hd 0 dst 0 hlen;
      let rec copy_rest pos = function
        | [] -> ()
        | x :: xs ->
            unsafe_blit sep 0 dst pos seplen;
            let pos = pos + seplen in
            let xlen = length x in
            unsafe_blit x 0 dst pos xlen;
            copy_rest (pos + xlen) xs
      in
      copy_rest hlen tl;
      dst

let iter f s =
  for i = 0 to length s - 1 do
    f (unsafe_get s i)
  done

let iteri f s =
  for i = 0 to length s - 1 do
    f i (unsafe_get s i)
  done

let map f s =
  let l = length s in
  if l = 0 then empty
  else begin
    let r = create l in
    for i = 0 to l - 1 do
      unsafe_set r i (f (unsafe_get s i))
    done;
    r
  end

let mapi f s =
  let l = length s in
  if l = 0 then empty
  else begin
    let r = create l in
    for i = 0 to l - 1 do
      unsafe_set r i (f i (unsafe_get s i))
    done;
    r
  end

let is_space = function
  | ' ' | '\012' | '\n' | '\r' | '\t' -> true
  | _ -> false

let trim s =
  let len = length s in
  let rec find_start k =
    if k < len && is_space (unsafe_get s k) then find_start (k + 1) else k
  in
  let rec find_end k =
    if k >= 0 && is_space (unsafe_get s k) then find_end (k - 1) else k
  in
  let a = find_start 0 in
  let b = find_end (len - 1) in
  if b >= a then sub s a (b - a + 1) else empty

let rec index_rec s lim i c =
  if i >= lim then raise Not_found
  else if unsafe_get s i = c then i
  else index_rec s lim (i + 1) c

let index s c = index_rec s (length s) 0 c

let rec index_rec_opt s lim i c =
  if i >= lim then None
  else if unsafe_get s i = c then Some i
  else index_rec_opt s lim (i + 1) c

let index_opt s c = index_rec_opt s (length s) 0 c

let index_from s i c =
  let l = length s in
  if i < 0 || i > l then invalid_arg "Bytes.index_from"
  else index_rec s l i c

let index_from_opt s i c =
  let l = length s in
  if i < 0 || i > l then invalid_arg "Bytes.index_from_opt"
  else index_rec_opt s l i c

let rec rindex_rec s i c =
  if i < 0 then raise Not_found
  else if unsafe_get s i = c then i
  else rindex_rec s (i - 1) c

let rindex s c = rindex_rec s (length s - 1) c

let rindex_from s i c =
  if i < -1 || i >= length s then invalid_arg "Bytes.rindex_from"
  else rindex_rec s i c

let rec rindex_rec_opt s i c =
  if i < 0 then None
  else if unsafe_get s i = c then Some i
  else rindex_rec_opt s (i - 1) c

let rindex_opt s c = rindex_rec_opt s (length s - 1) c

let rindex_from_opt s i c =
  if i < -1 || i >= length s then invalid_arg "Bytes.rindex_from_opt"
  else rindex_rec_opt s i c

let contains_from s i c =
  let l = length s in
  if i < 0 || i > l then invalid_arg "Bytes.contains_from"
  else
    match index_rec_opt s l i c with
    | Some _ -> true
    | None -> false

let contains s c = contains_from s 0 c

let rcontains_from s i c =
  if i < 0 || i >= length s then invalid_arg "Bytes.rcontains_from"
  else
    match rindex_rec_opt s i c with
    | Some _ -> true
    | None -> false

let uppercase_ascii_char c =
  if c >= 'a' && c <= 'z' then char_of_int (int_of_char c - 32) else c

let lowercase_ascii_char c =
  if c >= 'A' && c <= 'Z' then char_of_int (int_of_char c + 32) else c

let uppercase_ascii s = map uppercase_ascii_char s
let lowercase_ascii s = map lowercase_ascii_char s

let capitalize_ascii s =
  if length s = 0 then empty
  else begin
    let r = copy s in
    unsafe_set r 0 (uppercase_ascii_char (unsafe_get r 0));
    r
  end

let uncapitalize_ascii s =
  if length s = 0 then empty
  else begin
    let r = copy s in
    unsafe_set r 0 (lowercase_ascii_char (unsafe_get r 0));
    r
  end

let starts_with ~prefix s =
  let len_s = length s and len_p = length prefix in
  if len_p > len_s then false
  else
    let rec go i =
      if i >= len_p then true
      else if unsafe_get s i <> unsafe_get prefix i then false
      else go (i + 1)
    in
    go 0

let ends_with ~suffix s =
  let len_s = length s and len_p = length suffix in
  let diff = len_s - len_p in
  if diff < 0 then false
  else
    let rec go i =
      if i >= len_p then true
      else if unsafe_get s (diff + i) <> unsafe_get suffix i then false
      else go (i + 1)
    in
    go 0
