(**************************************************************************)
(*                                                                        *)
(*   Array / Floatarray / Bytes / String bulk operations       *)
(*   Compiled with --nopervasives right after CamlinternalIntFmt.         *)
(*                                                                        *)
(**************************************************************************)

external raise : exn -> 'a = "%raise"
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( == ) : 'a -> 'a -> bool = "%eq"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"
external not : bool -> bool = "%boolnot"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external int_of_char : char -> int = "%identity"

external bytes_length : bytes -> int = "%bytes_length"
external bytes_unsafe_get : bytes -> int -> char = "%bytes_unsafe_get"
external string_length : string -> int = "%string_length"
external string_unsafe_get : string -> int -> char = "%string_unsafe_get"
external unsafe_blit_bytes : bytes -> int -> bytes -> int -> int -> unit
  = "ocamlcc_bulk_blit_bytes"
external unsafe_blit_string : string -> int -> bytes -> int -> int -> unit
  = "ocamlcc_bulk_blit_bytes"
external unsafe_fill_bytes : bytes -> int -> int -> char -> unit
  = "ocamlcc_bulk_fill_bytes"

external array_length : 'a array -> int = "%array_length"
external array_unsafe_get : 'a array -> int -> 'a = "%array_unsafe_get"
external array_unsafe_set : 'a array -> int -> 'a -> unit = "%array_unsafe_set"
external array_make : int -> 'a -> 'a array = "caml_array_make"
external unsafe_array_sub : 'a array -> int -> int -> 'a array
  = "ocamlcc_bulk_array_sub"
external unsafe_array_blit : 'a array -> int -> 'a array -> int -> int -> unit
  = "ocamlcc_bulk_array_blit"
external unsafe_array_fill : 'a array -> int -> int -> 'a -> unit
  = "ocamlcc_bulk_array_fill"

external floatarray_length : floatarray -> int = "%floatarray_length"
external floatarray_unsafe_get : floatarray -> int -> float = "%floatarray_unsafe_get"
external floatarray_unsafe_set : floatarray -> int -> float -> unit = "%floatarray_unsafe_set"
external opaque_cast : 'a -> 'b = "%opaque"

external caml_hash : int -> int -> int -> 'a -> int = "caml_hash"

let invalid_arg s = raise (Invalid_argument s)

let slice_ok ofs len cap =
  ofs >= 0 && len >= 0 && ofs <= cap - len

let blit_bytes src soff dst doff len =
  if not (slice_ok soff len (bytes_length src))
     || not (slice_ok doff len (bytes_length dst))
  then invalid_arg "index out of bounds";
  unsafe_blit_bytes src soff dst doff len

let blit_string src soff dst doff len =
  if not (slice_ok soff len (string_length src))
     || not (slice_ok doff len (bytes_length dst))
  then invalid_arg "index out of bounds";
  unsafe_blit_string src soff dst doff len

let fill_bytes dst off len ch =
  if not (slice_ok off len (bytes_length dst)) then
    invalid_arg "index out of bounds";
  unsafe_fill_bytes dst off len ch

let string_equal a b =
  if a == b then true
  else
    let la = string_length a in
    let lb = string_length b in
    if la <> lb then false
    else
      let rec loop i =
        if i >= la then true
        else if string_unsafe_get a i <> string_unsafe_get b i then false
        else loop (i + 1)
      in
      loop 0

let bytes_equal a b =
  if a == b then true
  else
    let la = bytes_length a in
    let lb = bytes_length b in
    if la <> lb then false
    else
      let rec loop i =
        if i >= la then true
        else if bytes_unsafe_get a i <> bytes_unsafe_get b i then false
        else loop (i + 1)
      in
      loop 0

let string_compare a b =
  if a == b then 0
  else
    let la = string_length a in
    let lb = string_length b in
    let minlen = if la < lb then la else lb in
    let rec loop i =
      if i >= minlen then
        if la < lb then -1 else if la > lb then 1 else 0
      else
        let ca = int_of_char (string_unsafe_get a i) in
        let cb = int_of_char (string_unsafe_get b i) in
        if ca < cb then -1 else if ca > cb then 1 else loop (i + 1)
    in
    loop 0

let bytes_compare a b =
  if a == b then 0
  else
    let la = bytes_length a in
    let lb = bytes_length b in
    let minlen = if la < lb then la else lb in
    let rec loop i =
      if i >= minlen then
        if la < lb then -1 else if la > lb then 1 else 0
      else
        let ca = int_of_char (bytes_unsafe_get a i) in
        let cb = int_of_char (bytes_unsafe_get b i) in
        if ca < cb then -1 else if ca > cb then 1 else loop (i + 1)
    in
    loop 0

let string_hash seed s =
  caml_hash 1 1 seed s

let array_create_float n =
  if n < 0 then invalid_arg "Array.create_float";
  array_make n 0.0

let array_sub a ofs len =
  if not (slice_ok ofs len (array_length a)) then
    invalid_arg "index out of bounds";
  if len = 0 then [||]
  else unsafe_array_sub a ofs len

let array_append a1 a2 =
  let n1 = array_length a1 in
  let n2 = array_length a2 in
  if n1 = 0 && n2 = 0 then [||]
  else
    let total = n1 + n2 in
    if total < n1 then invalid_arg "Array.append";
    let seed =
      if n1 > 0 then array_unsafe_get a1 0 else array_unsafe_get a2 0
    in
    let dst = array_make total seed in
    for i = 0 to n1 - 1 do
      array_unsafe_set dst i (array_unsafe_get a1 i)
    done;
    for i = 0 to n2 - 1 do
      array_unsafe_set dst (n1 + i) (array_unsafe_get a2 i)
    done;
    dst

let array_concat lst =
  let rec measure total = function
    | [] -> total
    | a :: tl ->
        let n = array_length a in
        let next = total + n in
        if next < total then invalid_arg "Array.concat";
        measure next tl
  in
  let rec find_seed = function
    | [] -> None
    | a :: tl ->
        if array_length a > 0 then Some (array_unsafe_get a 0) else find_seed tl
  in
  let total = measure 0 lst in
  if total = 0 then [||]
  else
    match find_seed lst with
    | None -> [||]
    | Some seed ->
        let dst = array_make total seed in
        let rec fill pos = function
          | [] -> ()
          | a :: tl ->
              let n = array_length a in
              for i = 0 to n - 1 do
                array_unsafe_set dst (pos + i) (array_unsafe_get a i)
              done;
              fill (pos + n) tl
        in
        fill 0 lst;
        dst

let array_blit src sofs dst dofs len =
  if not (slice_ok sofs len (array_length src))
     || not (slice_ok dofs len (array_length dst))
  then invalid_arg "index out of bounds";
  unsafe_array_blit src sofs dst dofs len

let array_fill dst ofs len v =
  if not (slice_ok ofs len (array_length dst)) then
    invalid_arg "index out of bounds";
  unsafe_array_fill dst ofs len v

let floatarray_create (n : int) : floatarray =
  if n < 0 then invalid_arg "Float.Array.create";
  opaque_cast (array_make n 0.0)

let floatarray_make (n : int) (v : float) : floatarray =
  if n < 0 then invalid_arg "Float.Array.make";
  opaque_cast (array_make n v)

let floatarray_sub (a : floatarray) ofs len : floatarray =
  opaque_cast (array_sub (opaque_cast a : float array) ofs len)

let floatarray_append (a1 : floatarray) (a2 : floatarray) : floatarray =
  opaque_cast
    (array_append (opaque_cast a1 : float array) (opaque_cast a2 : float array))

let floatarray_concat (lst : floatarray list) : floatarray =
  opaque_cast (array_concat (opaque_cast lst : float array list))

let floatarray_blit (s : floatarray) so (d : floatarray) dofs l =
  array_blit (opaque_cast s : float array) so (opaque_cast d : float array) dofs l

let floatarray_fill (d : floatarray) ofs len (v : float) =
  array_fill (opaque_cast d : float array) ofs len v
