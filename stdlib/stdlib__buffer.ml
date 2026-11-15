external raise : exn -> 'a = "%raise"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external ( || ) : bool -> bool -> bool = "%sequor"

module B = Stdlib__bytes
module S = Stdlib__string

type t = {
  mutable buffer : bytes;
  mutable position : int;
  mutable length : int;
  initial_buffer : bytes;
}

let invalid_arg s = raise (Invalid_argument s)

let create n =
  let n = if n < 1 then 1 else n in
  let s = B.create n in
  { buffer = s; position = 0; length = n; initial_buffer = s }

let contents b = B.sub_string b.buffer 0 b.position
let to_bytes b = B.sub b.buffer 0 b.position

let sub b ofs len =
  if ofs < 0 || len < 0 || ofs > b.position - len then
    invalid_arg "Buffer.sub"
  else
    B.sub_string b.buffer ofs len

let blit src srcoff dst dstoff len =
  if len < 0 || srcoff < 0 || srcoff > src.position - len
     || dstoff < 0 || dstoff > B.length dst - len
  then invalid_arg "Buffer.blit"
  else B.unsafe_blit src.buffer srcoff dst dstoff len

let nth b ofs =
  if ofs < 0 || ofs >= b.position then invalid_arg "Buffer.nth"
  else B.unsafe_get b.buffer ofs

let length b = b.position
let clear b = b.position <- 0

let reset b =
  b.position <- 0;
  b.buffer <- b.initial_buffer;
  b.length <- B.length b.buffer

let resize b more =
  let old_len = b.length in
  let rec new_size len =
    if b.position + more <= len then len else new_size (len * 2)
  in
  let new_len = new_size (if old_len < 1 then 1 else old_len) in
  let new_buf = B.create new_len in
  B.unsafe_blit b.buffer 0 new_buf 0 b.position;
  b.buffer <- new_buf;
  b.length <- new_len

let add_char b c =
  let pos = b.position in
  if pos >= b.length then resize b 1;
  B.unsafe_set b.buffer pos c;
  b.position <- pos + 1

let add_substring b s offset len =
  if offset < 0 || len < 0 || offset > S.length s - len then
    invalid_arg "Buffer.add_substring";
  let new_position = b.position + len in
  if new_position > b.length then resize b len;
  B.unsafe_blit_string s offset b.buffer b.position len;
  b.position <- new_position

let add_subbytes b s offset len =
  if offset < 0 || len < 0 || offset > B.length s - len then
    invalid_arg "Buffer.add_subbytes";
  let new_position = b.position + len in
  if new_position > b.length then resize b len;
  B.unsafe_blit s offset b.buffer b.position len;
  b.position <- new_position

let add_string b s =
  let len = S.length s in
  let new_position = b.position + len in
  if new_position > b.length then resize b len;
  B.unsafe_blit_string s 0 b.buffer b.position len;
  b.position <- new_position

let add_bytes b s =
  let len = B.length s in
  let new_position = b.position + len in
  if new_position > b.length then resize b len;
  B.unsafe_blit s 0 b.buffer b.position len;
  b.position <- new_position

let add_buffer b bs =
  add_subbytes b bs.buffer 0 bs.position
