(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Pure OCaml Digest (MD5 + BLAKE2b) overlay for ocamlcc. *)

let hex_of_string d =
  let char_hex n =
    Char.chr (if n < 10 then Char.code '0' + n
                        else Char.code 'a' + n - 10) in
  let len = String.length d in
  let result = Bytes.create (len * 2) in
  for i = 0 to len - 1 do
    let x = Char.code d.[i] in
    Bytes.unsafe_set result (i * 2) (char_hex (x lsr 4));
    Bytes.unsafe_set result (i * 2 + 1) (char_hex (x land 0x0f));
  done;
  Bytes.unsafe_to_string result

let string_of_hex s =
  let digit c =
    match c with
    | '0' .. '9' -> Char.code c - Char.code '0'
    | 'A' .. 'F' -> Char.code c - Char.code 'A' + 10
    | 'a' .. 'f' -> Char.code c - Char.code 'a' + 10
    | _ -> invalid_arg "Digest.of_hex" in
  let byte i = (digit s.[i] lsl 4) + digit s.[i + 1] in
  String.init (String.length s / 2) (fun i -> Char.chr (byte (2 * i)))

let le32_of_bytes b o =
  Char.code (Bytes.unsafe_get b o)
  lor (Char.code (Bytes.unsafe_get b (o + 1)) lsl 8)
  lor (Char.code (Bytes.unsafe_get b (o + 2)) lsl 16)
  lor (Char.code (Bytes.unsafe_get b (o + 3)) lsl 24)

let le64_of_bytes b o =
  let lo = le32_of_bytes b o in
  let hi = le32_of_bytes b (o + 4) in
  Int64.logor (Int64.of_int lo) (Int64.shift_left (Int64.of_int hi) 32)

let channel_digest ~create ~update ~final ic toread =
  let buf_size = 4096 in
  let buf = Bytes.create buf_size in
  let st = create () in
  if toread < 0 then begin
    let rec do_read () =
      let n = In_channel.input ic buf 0 buf_size in
      if n = 0 then final st
      else (update st buf 0 n; do_read ())
    in do_read ()
  end else begin
    let rec do_read rem =
      if rem = 0 then final st else begin
        let n = In_channel.input ic buf 0 (Int.min buf_size rem) in
        if n = 0 then raise End_of_file
        else (update st buf 0 n; do_read (rem - n))
      end
    in do_read toread
  end

module type S = sig
  type t = string
  val hash_length : int
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val string : string -> t
  val bytes : bytes -> t
  val substring : string -> int -> int -> t
  val subbytes : bytes -> int -> int -> t
  val channel : in_channel -> int -> t
  val file : string -> t
  val output : out_channel -> t -> unit
  val input : in_channel -> t
  val to_hex : t -> string
  val of_hex : string -> t
end

(* ---- Pure OCaml BLAKE2b (RFC 7693) ---- *)

let b2_iv =
  [| 0x6a09e667f3bcc908L; 0xbb67ae8584caa73bL;
     0x3c6ef372fe94f82bL; 0xa54ff53a5f1d36f1L;
     0x510e527fade682d1L; 0x9b05688c2b3e6c1fL;
     0x1f83d9abfb41bd6bL; 0x5be0cd19137e2179L |]

let b2_sigma =
  [|
    [| 0; 1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11; 12; 13; 14; 15 |];
    [| 14; 10; 4; 8; 9; 15; 13; 6; 1; 12; 0; 2; 11; 7; 5; 3 |];
    [| 11; 8; 12; 0; 5; 2; 15; 13; 10; 14; 3; 6; 7; 1; 9; 4 |];
    [| 7; 9; 3; 1; 13; 12; 11; 14; 2; 6; 5; 10; 4; 0; 15; 8 |];
    [| 9; 0; 5; 7; 2; 4; 10; 15; 14; 1; 11; 12; 6; 8; 3; 13 |];
    [| 2; 12; 6; 10; 0; 11; 8; 3; 4; 13; 7; 5; 15; 14; 1; 9 |];
    [| 12; 5; 1; 15; 14; 13; 4; 10; 0; 7; 6; 3; 9; 2; 8; 11 |];
    [| 13; 11; 7; 14; 12; 1; 3; 9; 5; 0; 15; 4; 8; 6; 2; 10 |];
    [| 6; 15; 14; 9; 11; 3; 0; 8; 12; 2; 13; 7; 1; 4; 10; 5 |];
    [| 10; 2; 8; 4; 7; 6; 1; 5; 15; 11; 9; 14; 3; 12; 13; 0 |];
  |]

type b2_state = {
  h : int64 array;
  mutable t0 : int64;
  mutable t1 : int64;
  buf : bytes;
  mutable buflen : int;
  outlen : int;
}

let b2_rotr x n =
  Int64.logor (Int64.shift_right_logical x n) (Int64.shift_left x (64 - n))

let b2_add_len st inc =
  let old_t0 = st.t0 in
  let t0 = Int64.add old_t0 (Int64.of_int inc) in
  st.t0 <- t0;
  if Int64.compare old_t0 0L < 0 && Int64.compare t0 0L >= 0 then
    st.t1 <- Int64.add st.t1 1L

let b2_compress st is_last =
  let m = Array.init 16 (fun i -> le64_of_bytes st.buf (i * 8)) in
  let v = Array.make 16 0L in
  for i = 0 to 7 do
    v.(i) <- st.h.(i);
    v.(i + 8) <- b2_iv.(i)
  done;
  v.(12) <- Int64.logxor v.(12) st.t0;
  v.(13) <- Int64.logxor v.(13) st.t1;
  if is_last then v.(14) <- Int64.lognot v.(14);
  let g s i a b c d =
    let va = ref (Int64.add (Int64.add v.(a) v.(b)) m.(s.(2 * i))) in
    let vd = ref (b2_rotr (Int64.logxor v.(d) !va) 32) in
    let vc = ref (Int64.add v.(c) !vd) in
    let vb = ref (b2_rotr (Int64.logxor v.(b) !vc) 24) in
    va := Int64.add (Int64.add !va !vb) m.(s.(2 * i + 1));
    vd := b2_rotr (Int64.logxor !vd !va) 16;
    vc := Int64.add !vc !vd;
    vb := b2_rotr (Int64.logxor !vb !vc) 63;
    v.(a) <- !va; v.(b) <- !vb; v.(c) <- !vc; v.(d) <- !vd
  in
  for r = 0 to 11 do
    let s = b2_sigma.(r mod 10) in
    g s 0 0 4 8 12;
    g s 1 1 5 9 13;
    g s 2 2 6 10 14;
    g s 3 3 7 11 15;
    g s 4 0 5 10 15;
    g s 5 1 6 11 12;
    g s 6 2 7 8 13;
    g s 7 3 4 9 14
  done;
  for i = 0 to 7 do
    st.h.(i) <- Int64.logxor st.h.(i) (Int64.logxor v.(i) v.(i + 8))
  done

let b2_create outlen =
  let h = Array.copy b2_iv in
  h.(0) <- Int64.logxor h.(0) (Int64.of_int (0x01010000 lor outlen));
  { h; t0 = 0L; t1 = 0L; buf = Bytes.make 128 '\000'; buflen = 0; outlen }

let b2_update st data ofs len =
  if len > 0 then begin
    let in_ofs = ref ofs in
    let rem = ref len in
    let fill = 128 - st.buflen in
    if !rem > fill then begin
      Bytes.blit data !in_ofs st.buf st.buflen fill;
      b2_add_len st 128;
      b2_compress st false;
      in_ofs := !in_ofs + fill;
      rem := !rem - fill;
      st.buflen <- 0;
      while !rem > 128 do
        Bytes.blit data !in_ofs st.buf 0 128;
        b2_add_len st 128;
        b2_compress st false;
        in_ofs := !in_ofs + 128;
        rem := !rem - 128
      done
    end;
    Bytes.blit data !in_ofs st.buf st.buflen !rem;
    st.buflen <- st.buflen + !rem
  end

let b2_final st =
  b2_add_len st st.buflen;
  if st.buflen < 128 then
    Bytes.fill st.buf st.buflen (128 - st.buflen) '\000';
  b2_compress st true;
  let out = Bytes.create st.outlen in
  for i = 0 to st.outlen - 1 do
    let w = st.h.(i lsr 3) in
    let b = Int64.to_int (Int64.shift_right_logical w ((i land 7) * 8)) land 0xff in
    Bytes.unsafe_set out i (Char.chr b)
  done;
  Bytes.unsafe_to_string out

module BLAKE2 (X : sig val hash_length : int end) : S = struct

  type t = string

  let hash_length =
    if X.hash_length < 1 || X.hash_length > 64
    then invalid_arg "Digest.BLAKE2: wrong hash size";
    X.hash_length

  let compare = String.compare
  let equal = String.equal

  let subbytes b ofs len =
    if ofs < 0 || len < 0 || ofs > Bytes.length b - len
    then invalid_arg "Digest.subbytes";
    let st = b2_create hash_length in
    b2_update st b ofs len;
    b2_final st

  let substring str ofs len =
    if ofs < 0 || len < 0 || ofs > String.length str - len
    then invalid_arg "Digest.substring";
    let st = b2_create hash_length in
    b2_update st (Bytes.unsafe_of_string str) ofs len;
    b2_final st

  let string str = substring str 0 (String.length str)
  let bytes b = subbytes b 0 (Bytes.length b)

  let channel ic toread =
    channel_digest
      ~create:(fun () -> b2_create hash_length)
      ~update:b2_update ~final:b2_final ic toread

  let file filename =
    In_channel.with_open_bin filename (fun ic -> channel ic (-1))

  let output chan digest = output_string chan digest
  let input chan = really_input_string chan hash_length

  let to_hex d =
    if String.length d <> hash_length then invalid_arg "Digest.to_hex";
    hex_of_string d

  let of_hex s =
    if String.length s <> hash_length * 2 then invalid_arg "Digest.of_hex";
    string_of_hex s

end

module BLAKE128 = BLAKE2(struct let hash_length = 16 end)
module BLAKE256 = BLAKE2(struct let hash_length = 32 end)
module BLAKE512 = BLAKE2(struct let hash_length = 64 end)

(* ---- Pure OCaml MD5 (RFC 1321) ---- *)

let md5_k =
  [| 0xd76aa478; 0xe8c7b756; 0x242070db; 0xc1bdceee;
     0xf57c0faf; 0x4787c62a; 0xa8304613; 0xfd469501;
     0x698098d8; 0x8b44f7af; 0xffff5bb1; 0x895cd7be;
     0x6b901122; 0xfd987193; 0xa679438e; 0x49b40821;
     0xf61e2562; 0xc040b340; 0x265e5a51; 0xe9b6c7aa;
     0xd62f105d; 0x02441453; 0xd8a1e681; 0xe7d3fbc8;
     0x21e1cde6; 0xc33707d6; 0xf4d50d87; 0x455a14ed;
     0xa9e3e905; 0xfcefa3f8; 0x676f02d9; 0x8d2a4c8a;
     0xfffa3942; 0x8771f681; 0x6d9d6122; 0xfde5380c;
     0xa4beea44; 0x4bdecfa9; 0xf6bb4b60; 0xbebfbc70;
     0x289b7ec6; 0xeaa127fa; 0xd4ef3085; 0x04881d05;
     0xd9d4d039; 0xe6db99e5; 0x1fa27cf8; 0xc4ac5665;
     0xf4292244; 0x432aff97; 0xab9423a7; 0xfc93a039;
     0x655b59c3; 0x8f0ccc92; 0xffeff47d; 0x85845dd1;
     0x6fa87e4f; 0xfe2ce6e0; 0xa3014314; 0x4e0811a1;
     0xf7537e82; 0xbd3af235; 0x2ad7d2bb; 0xeb86d391 |]

let md5_r =
  [| 7; 12; 17; 22; 7; 12; 17; 22; 7; 12; 17; 22; 7; 12; 17; 22;
     5;  9; 14; 20; 5;  9; 14; 20; 5;  9; 14; 20; 5;  9; 14; 20;
     4; 11; 16; 23; 4; 11; 16; 23; 4; 11; 16; 23; 4; 11; 16; 23;
     6; 10; 15; 21; 6; 10; 15; 21; 6; 10; 15; 21; 6; 10; 15; 21 |]

type md5_state = {
  s : int array;
  mutable count : int;
  buf : bytes;
}

let md5_create () =
  { s = [| 0x67452301; 0xefcdab89; 0x98badcfe; 0x10325476 |];
    count = 0;
    buf = Bytes.make 64 '\000' }

let md5_rotl x n =
  let u = x land 0xffff_ffff in
  ((u lsl n) land 0xffff_ffff) lor (u lsr (32 - n))

let md5_transform st blk ofs =
  let m = Array.init 16 (fun i -> le32_of_bytes blk (ofs + i * 4)) in
  let a = ref st.s.(0) in
  let b = ref st.s.(1) in
  let c = ref st.s.(2) in
  let d = ref st.s.(3) in
  for i = 0 to 63 do
    let f, g =
      if i < 16 then
        ((!b land !c) lor ((lnot !b land 0xffff_ffff) land !d), i)
      else if i < 32 then
        ((!d land !b) lor ((lnot !d land 0xffff_ffff) land !c), (5 * i + 1) mod 16)
      else if i < 48 then
        (!b lxor !c lxor !d, (3 * i + 5) mod 16)
      else
        (!c lxor (!b lor (lnot !d land 0xffff_ffff)), (7 * i) mod 16)
    in
    let tmp = !d in
    d := !c;
    c := !b;
    let sum = (!a + f + md5_k.(i) + m.(g)) land 0xffff_ffff in
    b := (!b + md5_rotl sum md5_r.(i)) land 0xffff_ffff;
    a := tmp
  done;
  st.s.(0) <- (st.s.(0) + !a) land 0xffff_ffff;
  st.s.(1) <- (st.s.(1) + !b) land 0xffff_ffff;
  st.s.(2) <- (st.s.(2) + !c) land 0xffff_ffff;
  st.s.(3) <- (st.s.(3) + !d) land 0xffff_ffff

let md5_update st data ofs len =
  if len > 0 then begin
    let idx = st.count land 63 in
    st.count <- st.count + len;
    let i = ref 0 in
    if idx > 0 && idx + len >= 64 then begin
      let take = 64 - idx in
      Bytes.blit data ofs st.buf idx take;
      md5_transform st st.buf 0;
      i := take
    end;
    while !i + 64 <= len do
      md5_transform st data (ofs + !i);
      i := !i + 64
    done;
    if !i < len then begin
      let dst_idx = if idx > 0 && !i = 0 then idx else 0 in
      Bytes.blit data (ofs + !i) st.buf dst_idx (len - !i)
    end
  end

let md5_final st =
  let bits = st.count * 8 in
  let pad = Bytes.make 1 '\x80' in
  md5_update st pad 0 1;
  let zero = Bytes.make 1 '\000' in
  while (st.count land 63) <> 56 do
    md5_update st zero 0 1
  done;
  let len_le = Bytes.create 8 in
  for j = 0 to 7 do
    Bytes.unsafe_set len_le j (Char.chr ((bits lsr (j * 8)) land 0xff))
  done;
  md5_update st len_le 0 8;
  let out = Bytes.create 16 in
  for i = 0 to 3 do
    let w = st.s.(i) in
    for j = 0 to 3 do
      Bytes.unsafe_set out (i * 4 + j) (Char.chr ((w lsr (j * 8)) land 0xff))
    done
  done;
  Bytes.unsafe_to_string out

module MD5 = struct

  type t = string

  let hash_length = 16

  let compare = String.compare
  let equal = String.equal

  let subbytes b ofs len =
    if ofs < 0 || len < 0 || ofs > Bytes.length b - len
    then invalid_arg "Digest.subbytes";
    let st = md5_create () in
    md5_update st b ofs len;
    md5_final st

  let substring str ofs len =
    if ofs < 0 || len < 0 || ofs > String.length str - len
    then invalid_arg "Digest.substring";
    let st = md5_create () in
    md5_update st (Bytes.unsafe_of_string str) ofs len;
    md5_final st

  let string str = substring str 0 (String.length str)
  let bytes b = subbytes b 0 (Bytes.length b)

  let channel ic toread =
    channel_digest ~create:md5_create ~update:md5_update ~final:md5_final
      ic toread

  let file filename =
    In_channel.with_open_bin filename (fun ic -> channel ic (-1))

  let output chan digest = output_string chan digest
  let input chan = really_input_string chan 16

  let to_hex d =
    if String.length d <> 16 then invalid_arg "Digest.to_hex";
    hex_of_string d

  let of_hex s =
    if String.length s <> 32 then invalid_arg "Digest.of_hex";
    string_of_hex s

end

include MD5

let from_hex = of_hex
