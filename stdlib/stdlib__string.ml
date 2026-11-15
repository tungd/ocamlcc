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

external length : string -> int = "%string_length"
external get : string -> int -> char = "%string_safe_get"
external unsafe_get : string -> int -> char = "%string_unsafe_get"
external blit : string -> int -> bytes -> int -> int -> unit = "caml_blit_string"
external equal : string -> string -> bool = "caml_string_equal"
external compare : string -> string -> int = "caml_string_compare"

module B = Stdlib__bytes

let empty = ""
let make n c = B.unsafe_to_string (B.make n c)
let init n f = B.unsafe_to_string (B.init n f)
let copy s = B.unsafe_to_string (B.of_string s)
let of_bytes b = B.to_string b
let to_bytes s = B.of_string s
let sub s ofs len = B.unsafe_to_string (B.sub (B.unsafe_of_string s) ofs len)

let cat s1 s2 =
  B.unsafe_to_string (B.cat (B.unsafe_of_string s1) (B.unsafe_of_string s2))

let concat sep l =
  match l with
  | [] -> ""
  | hd :: tl ->
      let seplen = length sep in
      let rec total_len acc = function
        | [] -> acc
        | x :: xs -> total_len (acc + seplen + length x) xs
      in
      let dst = B.create (total_len (length hd) tl) in
      let hlen = length hd in
      B.unsafe_blit_string hd 0 dst 0 hlen;
      let rec copy_rest pos = function
        | [] -> ()
        | x :: xs ->
            B.unsafe_blit_string sep 0 dst pos seplen;
            let pos = pos + seplen in
            let xlen = length x in
            B.unsafe_blit_string x 0 dst pos xlen;
            copy_rest (pos + xlen) xs
      in
      copy_rest hlen tl;
      B.unsafe_to_string dst

let iter f s = B.iter f (B.unsafe_of_string s)
let iteri f s = B.iteri f (B.unsafe_of_string s)
let map f s = B.unsafe_to_string (B.map f (B.unsafe_of_string s))
let mapi f s = B.unsafe_to_string (B.mapi f (B.unsafe_of_string s))
let trim s = B.unsafe_to_string (B.trim (B.unsafe_of_string s))
let index s c = B.index (B.unsafe_of_string s) c
let index_opt s c = B.index_opt (B.unsafe_of_string s) c
let rindex s c = B.rindex (B.unsafe_of_string s) c
let rindex_opt s c = B.rindex_opt (B.unsafe_of_string s) c
let index_from s i c = B.index_from (B.unsafe_of_string s) i c
let index_from_opt s i c = B.index_from_opt (B.unsafe_of_string s) i c
let rindex_from s i c = B.rindex_from (B.unsafe_of_string s) i c
let rindex_from_opt s i c = B.rindex_from_opt (B.unsafe_of_string s) i c
let contains s c = B.contains (B.unsafe_of_string s) c
let contains_from s i c = B.contains_from (B.unsafe_of_string s) i c
let rcontains_from s i c = B.rcontains_from (B.unsafe_of_string s) i c
let uppercase_ascii s = B.unsafe_to_string (B.uppercase_ascii (B.unsafe_of_string s))
let lowercase_ascii s = B.unsafe_to_string (B.lowercase_ascii (B.unsafe_of_string s))
let capitalize_ascii s = B.unsafe_to_string (B.capitalize_ascii (B.unsafe_of_string s))
let uncapitalize_ascii s = B.unsafe_to_string (B.uncapitalize_ascii (B.unsafe_of_string s))

let starts_with ~prefix s =
  B.starts_with ~prefix:(B.unsafe_of_string prefix) (B.unsafe_of_string s)

let ends_with ~suffix s =
  B.ends_with ~suffix:(B.unsafe_of_string suffix) (B.unsafe_of_string s)

let split_on_char sep s =
  let rec go acc j i =
    if i < 0 then
      sub s 0 j :: acc
    else if unsafe_get s i = sep then
      go (sub s (i + 1) (j - i - 1) :: acc) i (i - 1)
    else
      go acc j (i - 1)
  in
  let l = length s in
  go [] l (l - 1)
