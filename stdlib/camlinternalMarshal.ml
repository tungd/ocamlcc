(**************************************************************************)
(*                                                                        *)
(*   Pure OCaml Marshal encoder/decoder (0x8495a6be/bf + 0x8495a6bd)      *)
(*   Compiled with --nopervasives right after CamlinternalBulkOps.        *)
(*                                                                        *)
(**************************************************************************)

external raise : exn -> 'a = "%raise"
external ignore : 'a -> unit = "%ignore"
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
external ( ~- ) : int -> int = "%negint"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external ( land ) : int -> int -> int = "%andint"
external ( lor ) : int -> int -> int = "%orint"
external ( lxor ) : int -> int -> int = "%xorint"
external ( lsl ) : int -> int -> int = "%lslint"
external ( lsr ) : int -> int -> int = "%lsrint"
external ( asr ) : int -> int -> int = "%asrint"

external int_of_char : char -> int = "%identity"
external char_of_int : int -> char = "%identity"
external opaque_cast : 'a -> 'b = "%opaque"

external bytes_length : bytes -> int = "%bytes_length"
external bytes_create : int -> bytes = "caml_create_bytes"
external bytes_unsafe_get : bytes -> int -> char = "%bytes_unsafe_get"
external bytes_unsafe_set : bytes -> int -> char -> unit = "%bytes_unsafe_set"
external bytes_unsafe_to_string : bytes -> string = "%bytes_to_string"

external bytes_unsafe_get16 : bytes -> int -> int = "%caml_bytes_get16u"
external bytes_unsafe_get32 : bytes -> int -> int32 = "%caml_bytes_get32u"
external bytes_unsafe_get64 : bytes -> int -> int64 = "%caml_bytes_get64u"
external bytes_unsafe_set16 : bytes -> int -> int -> unit = "%caml_bytes_set16u"
external bytes_unsafe_set32 : bytes -> int -> int32 -> unit = "%caml_bytes_set32u"
external bytes_unsafe_set64 : bytes -> int -> int64 -> unit = "%caml_bytes_set64u"
external bswap16 : int -> int = "%bswap16"
external bswap32 : int32 -> int32 = "%bswap_int32"
external bswap64 : int64 -> int64 = "%bswap_int64"

external array_length : 'a array -> int = "%array_length"
external array_unsafe_get : 'a array -> int -> 'a = "%array_unsafe_get"
external array_unsafe_set : 'a array -> int -> 'a -> unit = "%array_unsafe_set"
external array_make : int -> 'a -> 'a array = "caml_array_make"

external floatarray_length : floatarray -> int = "%floatarray_length"
external floatarray_unsafe_get : floatarray -> int -> float = "%floatarray_unsafe_get"
external floatarray_unsafe_set : floatarray -> int -> float -> unit = "%floatarray_unsafe_set"

external i32_of_i64 : int64 -> int32 = "%int64_to_int32"
external i64_of_i32 : int32 -> int64 = "%int64_of_int32"
external i64_of_int : int -> int64 = "%int64_of_int"
external i64_to_int : int64 -> int = "%int64_to_int"
external i64_of_native : nativeint -> int64 = "%int64_of_nativeint"
external native_of_i64 : int64 -> nativeint = "%int64_to_nativeint"
external i64_add : int64 -> int64 -> int64 = "%int64_add"
external i64_and : int64 -> int64 -> int64 = "%int64_and"
external i64_or : int64 -> int64 -> int64 = "%int64_or"
external i64_xor : int64 -> int64 -> int64 = "%int64_xor"
external i64_lsl : int64 -> int -> int64 = "%int64_lsl"
external i64_lsr : int64 -> int -> int64 = "%int64_lsr"
external i64_asr : int64 -> int -> int64 = "%int64_asr"
external i64_lt : int64 -> int64 -> bool = "%lessthan"
external i64_eq : int64 -> int64 -> bool = "%equal"
external i64_bits_of_float : float -> int64 = "caml_int64_bits_of_float"
external float_of_i64_bits : int64 -> float = "caml_int64_float_of_bits"

type obj_t
external obj_block : int -> int -> obj_t = "caml_obj_block"
external obj_field : obj_t -> int -> obj_t = "%obj_field"
external obj_set_field : obj_t -> int -> obj_t -> unit = "%obj_set_field"
external obj_size : obj_t -> int = "%obj_size"
external fresh_oo_id : obj_t -> obj_t = "caml_fresh_oo_id"

external ptr_id : obj_t -> int = "ocamlcc_ptr_id"
external marshal_kind : obj_t -> int = "ocamlcc_marshal_kind"
external ba_info : obj_t -> int * int * int array = "ocamlcc_ba_info"
external ba_read_bytes : obj_t -> bytes = "ocamlcc_ba_read_bytes"
external ba_of_bytes : int -> int -> int array -> bytes -> obj_t = "ocamlcc_ba_of_bytes"

external ch_cast : 'a -> 'b = "%identity"
let ml_output_bytes oc b ofs len =
  CamlinternalChannel.unsafe_output (ch_cast oc) b ofs len
let ml_input ic b ofs len =
  CamlinternalChannel.unsafe_input (ch_cast ic) b ofs len

type 'a mref = { mutable contents : 'a }

let failwith msg = raise (Failure msg)
let invalid_arg msg = raise (Invalid_argument msg)

(* Optional external compression codec hook (e.g. libzstd registered by Compiler). *)
type codec = {
  compress : bytes -> int -> bytes -> int;
  decompress : bytes -> int -> int -> bytes -> int;
}

let codec_ref : codec option mref = { contents = None }

let register_codec ~compress ~decompress =
  codec_ref.contents <- Some { compress; decompress }

let clear_codec () =
  codec_ref.contents <- None

let i64_min_int = -9223372036854775808L

let u64_lt (a : int64) (b : int64) =
  i64_lt (i64_xor a i64_min_int) (i64_xor b i64_min_int)

let u64_le (a : int64) (b : int64) =
  not (u64_lt b a)

(* ---- Open-addressed pointer map for encoding ---- *)

type pmap = {
  mutable keys : int array;
  mutable vals : int array;
  mutable cap : int;
  mutable used : int;
}

let pmap_hash k =
  let h = k * 0x9e3779b9 in
  h lxor (h lsr 16)

let pmap_create () =
  let cap = 256 in
  { keys = array_make cap 0; vals = array_make cap 0; cap; used = 0 }

let pmap_lookup (m : pmap) (k : int) : int =
  let mask = m.cap - 1 in
  let rec probe i =
    let ki = array_unsafe_get m.keys i in
    if ki = 0 then -1
    else if ki = k then array_unsafe_get m.vals i
    else probe ((i + 1) land mask)
  in
  probe ((pmap_hash k) land mask)

let rec pmap_insert_raw keys vals cap k v =
  let mask = cap - 1 in
  let rec probe i =
    let ki = array_unsafe_get keys i in
    if ki <= 0 then (
      array_unsafe_set keys i k;
      array_unsafe_set vals i v;
      ki = 0)
    else probe ((i + 1) land mask)
  in
  probe ((pmap_hash k) land mask)

let pmap_insert (m : pmap) (k : int) (v : int) =
  if (m.used + 1) * 2 >= m.cap then (
    let old_cap = m.cap in
    let old_keys = m.keys in
    let old_vals = m.vals in
    let new_cap = old_cap * 2 in
    let new_keys = array_make new_cap 0 in
    let new_vals = array_make new_cap 0 in
    let inserted = { contents = 0 } in
    for j = 0 to old_cap - 1 do
      let ok = array_unsafe_get old_keys j in
      if ok > 0 then (
        ignore (pmap_insert_raw new_keys new_vals new_cap ok (array_unsafe_get old_vals j));
        inserted.contents <- inserted.contents + 1)
    done;
    m.keys <- new_keys;
    m.vals <- new_vals;
    m.cap <- new_cap;
    m.used <- inserted.contents);
  if pmap_insert_raw m.keys m.vals m.cap k v then
    m.used <- m.used + 1

let pmap_remove (m : pmap) (k : int) =
  let mask = m.cap - 1 in
  let rec probe i =
    let ki = array_unsafe_get m.keys i in
    if ki = k then array_unsafe_set m.keys i (-1)
    else if ki <> 0 then probe ((i + 1) land mask)
  in
  probe ((pmap_hash k) land mask)

(* ---- Dynamic byte buffer & encoder ---- *)

type writer = {
  mutable data : bytes;
  mutable len : int;
  mutable cap : int;
  seen : pmap;
  mutable objects : int;
  mutable words32 : int64;
  mutable words64 : int64;
  no_sharing : bool;
  compat32 : bool;
  compress : bool;
}

let w_ensure w need =
  if need > w.cap then (
    let next = { contents = if w.cap = 0 then 256 else w.cap } in
    while next.contents < need do
      next.contents <- next.contents * 2
    done;
    let nd = bytes_create next.contents in
    CamlinternalBulkOps.blit_bytes w.data 0 nd 0 w.len;
    w.data <- nd;
    w.cap <- next.contents)

let w_u8 w v =
  w_ensure w (w.len + 1);
  bytes_unsafe_set w.data w.len (char_of_int (v land 255));
  w.len <- w.len + 1

let w_be16 w v =
  w_ensure w (w.len + 2);
  bytes_unsafe_set16 w.data w.len (bswap16 v);
  w.len <- w.len + 2

let w_be32 w (v : int32) =
  w_ensure w (w.len + 4);
  bytes_unsafe_set32 w.data w.len (bswap32 v);
  w.len <- w.len + 4

let w_be64 w (v : int64) =
  w_ensure w (w.len + 8);
  bytes_unsafe_set64 w.data w.len (bswap64 v);
  w.len <- w.len + 8

let w_le64 w (v : int64) =
  w_ensure w (w.len + 8);
  bytes_unsafe_set64 w.data w.len v;
  w.len <- w.len + 8

let w_put_u w (v : int64) nbytes =
  if nbytes = 1 then w_u8 w (i64_to_int v)
  else if nbytes = 2 then w_be16 w (i64_to_int v)
  else if nbytes = 4 then w_be32 w (i32_of_i64 v)
  else if nbytes = 8 then w_be64 w v
  else
    for i = nbytes - 1 downto 0 do
      w_u8 w (i64_to_int (i64_lsr v (i * 8)))
    done

let w_code w code (v : int64) nbytes =
  w_u8 w code;
  w_put_u w v nbytes

let w_bytes w src ofs n =
  if n > 0x7FFFFFFF || w.len > 0x7FFFFFFF - n then
    failwith "output_value: object too big";
  w_ensure w (w.len + n);
  CamlinternalBulkOps.blit_bytes src ofs w.data w.len n;
  w.len <- w.len + n

let w_cstr_z w (s : string) =
  let n = CamlinternalBulkOps.string_length s in
  w_bytes w (opaque_cast s : bytes) 0 n;
  w_u8 w 0

let w_header w size tag =
  if size < 8 && tag < 16 then
    w_u8 w (0x80 + tag + (size lsl 4))
  else
    let hd = i64_or (i64_lsl (i64_of_int size) 10) (i64_of_int tag) in
    if u64_le hd 0xFFFFFFFFL then w_code w 8 hd 4
    else w_code w 0x13 hd 8

let w_int w n =
  if n >= 0 && n < 64 then w_u8 w (0x40 + n)
  else if n >= -128 && n < 128 then w_code w 0 (i64_of_int n) 1
  else if n >= -32768 && n < 32768 then w_code w 1 (i64_of_int n) 2
  else if n < -(1 lsl 30) || n >= (1 lsl 30) then
    if w.compat32 then
      failwith "output_value: integer cannot be read back on 32-bit platform"
    else w_code w 3 (i64_of_int n) 8
  else w_code w 2 (i64_of_int n) 4

let ba_elem_width kind =
  match kind with
  | 0 -> 4 | 1 -> 8 | 2 -> 1 | 3 -> 1 | 4 -> 2 | 5 -> 2 | 6 -> 4 | 7 -> 8
  | 8 -> 8 | 9 -> 8 | 10 -> 8 | 11 -> 16 | 12 -> 1 | 13 -> 2
  | _ -> 1

let w_bigarray w v =
  let kind, layout, dims = ba_info v in
  let ndims = array_length dims in
  let raw = ba_read_bytes v in
  w_u8 w 0x18;
  w_cstr_z w "_bigarr02";
  w_be32 w (i32_of_i64 (i64_of_int ((4 + ndims) * 4)));
  w_be64 w (i64_of_int ((4 + ndims) * 8));
  w_be32 w (i32_of_i64 (i64_of_int ndims));
  w_be32 w (i32_of_i64 (i64_of_int (kind lor (layout lsl 8))));
  let count = { contents = 1 } in
  for i = 0 to ndims - 1 do
    let d = array_unsafe_get dims i in
    count.contents <- count.contents * d;
    if d < 65535 then w_be16 w d
    else (
      w_be16 w 65535;
      w_be64 w (i64_of_int d))
  done;
  let cnt = count.contents in
  let elems = if kind = 10 || kind = 11 then cnt * 2 else cnt in
  let width =
    if kind = 10 || kind = 11 then ba_elem_width kind / 2
    else ba_elem_width kind
  in
  if kind = 8 || kind = 9 then (
    let minv = if kind = 8 then -1073741824L else -2147483648L in
    let maxv = if kind = 8 then 1073741823L else 2147483647L in
    let out_w = { contents = 4 } in
    for i = 0 to elems - 1 do
      let x = bytes_unsafe_get64 raw (i * 8) in
      if x < minv || x > maxv then out_w.contents <- 8
    done;
    let ow = out_w.contents in
    w_u8 w (if ow = 8 then 1 else 0);
    for i = 0 to elems - 1 do
      let x = bytes_unsafe_get64 raw (i * 8) in
      if ow = 8 then w_be64 w x else w_be32 w (i32_of_i64 x)
    done)
  else
    for i = 0 to elems - 1 do
      let off = i * width in
      if width = 1 then w_u8 w (int_of_char (bytes_unsafe_get raw off))
      else if width = 2 then w_be16 w (bytes_unsafe_get16 raw off)
      else if width = 4 then w_be32 w (bytes_unsafe_get32 raw off)
      else w_be64 w (bytes_unsafe_get64 raw off)
    done;
  let dw = i64_of_int (6 + ndims) in
  w.words32 <- i64_add w.words32 dw;
  w.words64 <- i64_add w.words64 dw

let encode_value_loop w (root : obj_t) =
  let cap = { contents = 256 } in
  let st_val = { contents = array_make 256 root } in
  let st_leave = { contents = array_make 256 false } in
  let sp = { contents = 0 } in
  let push v leave =
    if sp.contents >= cap.contents then (
      let ncap = cap.contents * 2 in
      let nv = array_make ncap v in
      let nl = array_make ncap false in
      for i = 0 to cap.contents - 1 do
        array_unsafe_set nv i (array_unsafe_get st_val.contents i);
        array_unsafe_set nl i (array_unsafe_get st_leave.contents i)
      done;
      st_val.contents <- nv;
      st_leave.contents <- nl;
      cap.contents <- ncap);
    array_unsafe_set st_val.contents sp.contents v;
    array_unsafe_set st_leave.contents sp.contents leave;
    sp.contents <- sp.contents + 1
  in
  push root false;
  while sp.contents > 0 do
    sp.contents <- sp.contents - 1;
    let v = array_unsafe_get st_val.contents sp.contents in
    let leave = array_unsafe_get st_leave.contents sp.contents in
    array_unsafe_set st_val.contents sp.contents (opaque_cast 0);
    if leave then pmap_remove w.seen (ptr_id v)
    else
      let kind = marshal_kind v in
      if kind = -1 then
        let n : int = opaque_cast v in
        w_int w n
      else if kind = 247 then
        invalid_arg "output_value: functional value"
      else if kind = 251 then
        invalid_arg "output_value: abstract value"
      else if kind <> 300 && kind <> 301 && kind <> 302 && kind <> 306 &&
              ((kind <= 250 && obj_size v = 0) ||
               (kind = 254 && floatarray_length (opaque_cast v) = 0)) then
        w_header w 0 (if kind = 254 then 0 else kind)
      else if kind <> 306 && kind <> 300 && kind <> 301 && kind <> 302 &&
              kind = 252 && bytes_length (opaque_cast v) = 0 then (
        let prev = pmap_lookup w.seen (ptr_id v) in
        if prev >= 0 then (
          if w.no_sharing then invalid_arg "output_value: cyclic value with No_sharing";
          let ref_id = if w.compress then prev else w.objects - prev in
          if ref_id < 256 then w_code w 4 (i64_of_int ref_id) 1
          else if ref_id < 65536 then w_code w 5 (i64_of_int ref_id) 2
          else w_code w 6 (i64_of_int ref_id) 4)
        else (
          if not w.no_sharing then (
            pmap_insert w.seen (ptr_id v) w.objects;
            w.objects <- w.objects + 1);
          w_u8 w 0x20;
          w.words32 <- i64_add w.words32 2L;
          w.words64 <- i64_add w.words64 2L))
      else
        let key = ptr_id v in
        let prev = pmap_lookup w.seen key in
        if prev >= 0 then (
          if w.no_sharing then invalid_arg "output_value: cyclic value with No_sharing";
          let ref_id = if w.compress then prev else w.objects - prev in
          if ref_id < 256 then w_code w 4 (i64_of_int ref_id) 1
          else if ref_id < 65536 then w_code w 5 (i64_of_int ref_id) 2
          else w_code w 6 (i64_of_int ref_id) 4)
        else (
          if not w.no_sharing then (
            pmap_insert w.seen key w.objects;
            w.objects <- w.objects + 1);
          if kind = 252 then (
            let bs : bytes = opaque_cast v in
            let n = bytes_length bs in
            if n < 32 then w_u8 w (0x20 + n)
            else if n < 256 then w_code w 9 (i64_of_int n) 1
            else w_code w 10 (i64_of_int n) 4;
            w_bytes w bs 0 n;
            w.words32 <- i64_add w.words32 (i64_of_int (1 + (n + 4) / 4));
            w.words64 <- i64_add w.words64 (i64_of_int (1 + (n + 8) / 8)))
          else if kind = 253 then (
            let f : float = opaque_cast v in
            w_u8 w 12;
            w_le64 w (i64_bits_of_float f);
            w.words32 <- i64_add w.words32 3L;
            w.words64 <- i64_add w.words64 2L)
          else if kind = 254 then (
            let fa : floatarray = opaque_cast v in
            let n = floatarray_length fa in
            if n < 256 then w_code w 14 (i64_of_int n) 1
            else w_code w 7 (i64_of_int n) 4;
            for i = 0 to n - 1 do
              w_le64 w (i64_bits_of_float (floatarray_unsafe_get fa i))
            done;
            w.words32 <- i64_add w.words32 (i64_of_int (1 + 2 * n));
            w.words64 <- i64_add w.words64 (i64_of_int (1 + n)))
          else if kind = 306 then
            w_bigarray w v
          else if kind = 300 then (
            let x : int32 = opaque_cast v in
            w_u8 w 0x19;
            w_cstr_z w "_i";
            w_be32 w x;
            w.words32 <- i64_add w.words32 3L;
            w.words64 <- i64_add w.words64 3L)
          else if kind = 301 then (
            let x : int64 = opaque_cast v in
            w_u8 w 0x19;
            w_cstr_z w "_j";
            w_be64 w x;
            w.words32 <- i64_add w.words32 4L;
            w.words64 <- i64_add w.words64 3L)
          else if kind = 302 then (
            let nv : nativeint = opaque_cast v in
            let x = i64_of_native nv in
            w_u8 w 0x19;
            w_cstr_z w "_n";
            if x >= -2147483648L && x <= 2147483647L then (
              w_u8 w 1;
              w_be32 w (i32_of_i64 x))
            else if w.compat32 then
              failwith "output_value: native integer cannot be read back on 32-bit platform"
            else (
              w_u8 w 2;
              w_be64 w x);
            w.words32 <- i64_add w.words32 3L;
            w.words64 <- i64_add w.words64 3L)
          else (
            let n = obj_size v in
            w_header w n kind;
            w.words32 <- i64_add w.words32 (i64_of_int (1 + n));
            w.words64 <- i64_add w.words64 (i64_of_int (1 + n));
            if w.no_sharing then (
              pmap_insert w.seen key 0;
              push v true);
            for i = n - 1 downto 0 do
              push (obj_field v i) false
            done))
  done

let encode_vlq (v : int64) (dst : bytes) (ofs : int) : int =
  let tmp = bytes_create 10 in
  let n = { contents = 1 } in
  bytes_unsafe_set tmp 0 (char_of_int (i64_to_int (i64_and v 0x7FL)));
  let cur = { contents = i64_lsr v 7 } in
  while not (i64_eq cur.contents 0L) do
    bytes_unsafe_set tmp n.contents
      (char_of_int (i64_to_int (i64_or (i64_and cur.contents 0x7FL) 0x80L)));
    n.contents <- n.contents + 1;
    cur.contents <- i64_lsr cur.contents 7
  done;
  let k = n.contents in
  for i = 0 to k - 1 do
    bytes_unsafe_set dst (ofs + i) (bytes_unsafe_get tmp (k - 1 - i))
  done;
  k

let parse_flags (flags : 'f list) =
  let no_sh = { contents = false } in
  let compat32 = { contents = false } in
  let comp = { contents = false } in
  let rec loop = function
    | [] -> ()
    | f :: tl ->
        let tag : int = opaque_cast f in
        if tag = 0 then no_sh.contents <- true
        else if tag = 2 then compat32.contents <- true
        else if tag = 3 then comp.contents <- true;
        loop tl
  in
  loop flags;
  let has_codec = match codec_ref.contents with Some _ -> true | None -> false in
  (no_sh.contents, compat32.contents, comp.contents && has_codec)

let encode_to_bytes_len value flags : bytes * int =
  let no_sharing, compat32, compress = parse_flags flags in
  let w =
    { data = bytes_create 256; len = 20; cap = 256; seen = pmap_create ();
      objects = 0; words32 = 0L; words64 = 0L;
      no_sharing; compat32; compress }
  in
  encode_value_loop w (opaque_cast value);
  let payload_len = w.len - 20 in
  if compress then (
    match codec_ref.contents with
    | None -> failwith "output_value: compression failed"
    | Some codec ->
        let payload = bytes_create payload_len in
        CamlinternalBulkOps.blit_bytes w.data 20 payload 0 payload_len;
        let comp_cap = payload_len + (payload_len lsr 2) + 256 in
        let comp_buf = bytes_create comp_cap in
        let comp_len = codec.compress payload payload_len comp_buf in
        if comp_len <= 0 then failwith "output_value: compression failed";
        let hdr = bytes_create 64 in
        bytes_unsafe_set hdr 0 '\x84';
        bytes_unsafe_set hdr 1 '\x95';
        bytes_unsafe_set hdr 2 '\xa6';
        bytes_unsafe_set hdr 3 '\xbd';
        let hp = { contents = 5 } in
        hp.contents <- hp.contents + encode_vlq (i64_of_int comp_len) hdr hp.contents;
        hp.contents <- hp.contents + encode_vlq (i64_of_int payload_len) hdr hp.contents;
        hp.contents <- hp.contents + encode_vlq (i64_of_int w.objects) hdr hp.contents;
        hp.contents <- hp.contents + encode_vlq w.words32 hdr hp.contents;
        hp.contents <- hp.contents + encode_vlq w.words64 hdr hp.contents;
        let hlen = hp.contents in
        if hlen > 63 then failwith "output_value: object too big";
        bytes_unsafe_set hdr 4 (char_of_int hlen);
        let total = hlen + comp_len in
        let out = bytes_create total in
        CamlinternalBulkOps.blit_bytes hdr 0 out 0 hlen;
        CamlinternalBulkOps.blit_bytes comp_buf 0 out hlen comp_len;
        (out, total))
  else
    let end_pos = w.len in
    if end_pos > 0x7FFFFFFF || w.words32 > 0xFFFFFFFFL || w.words64 > 0xFFFFFFFFL then
      failwith "output_value: object too big";
    w.len <- 0;
    w_be32 w (i32_of_i64 0x8495A6BEL);
    w_be32 w (i32_of_i64 (i64_of_int payload_len));
    w_be32 w (i32_of_i64 (i64_of_int w.objects));
    w_be32 w (i32_of_i64 w.words32);
    w_be32 w (i32_of_i64 w.words64);
    (w.data, end_pos)

let to_bytes v flags =
  let buf, n = encode_to_bytes_len v flags in
  if bytes_length buf = n then buf
  else
    let out = bytes_create n in
    CamlinternalBulkOps.blit_bytes buf 0 out 0 n;
    out

let to_string v flags =
  bytes_unsafe_to_string (to_bytes v flags)

let to_buffer_unsafe buff ofs len v flags =
  if ofs < 0 || len < 0 || ofs > bytes_length buff - len then
    invalid_arg "Marshal.to_buffer: index out of bounds";
  let buf, n = encode_to_bytes_len v flags in
  if n > len then failwith "Marshal.to_buffer: buffer overflow";
  CamlinternalBulkOps.blit_bytes buf 0 buff ofs n;
  n

let to_channel oc v flags =
  let buf, n = encode_to_bytes_len v flags in
  ml_output_bytes oc buf 0 n

(* ---- Decoder ---- *)

let r_u8 buf pos end_pos =
  if pos >= end_pos then failwith "input_value: truncated object";
  int_of_char (bytes_unsafe_get buf pos)

let r_u64 buf pos end_pos nbytes =
  if nbytes > end_pos - pos then failwith "input_value: truncated object";
  if nbytes = 1 then i64_of_int (int_of_char (bytes_unsafe_get buf pos))
  else if nbytes = 2 then i64_of_int (bswap16 (bytes_unsafe_get16 buf pos))
  else if nbytes = 4 then i64_and (i64_of_i32 (bswap32 (bytes_unsafe_get32 buf pos))) 0xFFFFFFFFL
  else if nbytes = 8 then bswap64 (bytes_unsafe_get64 buf pos)
  else
    let acc = { contents = 0L } in
    for i = 0 to nbytes - 1 do
      let b = i64_of_int (int_of_char (bytes_unsafe_get buf (pos + i))) in
      acc.contents <- i64_or (i64_lsl acc.contents 8) b
    done;
    acc.contents

let r_i64_signed_be buf pos end_pos nbytes =
  if nbytes > end_pos - pos then failwith "input_value: truncated object";
  if nbytes = 1 then
    let v = int_of_char (bytes_unsafe_get buf pos) in
    if v >= 128 then v - 256 else v
  else if nbytes = 2 then
    let v = bswap16 (bytes_unsafe_get16 buf pos) in
    if v >= 32768 then v - 65536 else v
  else if nbytes = 4 then
    let v = bswap32 (bytes_unsafe_get32 buf pos) in
    i64_to_int (i64_of_i32 v)
  else
    i64_to_int (bswap64 (bytes_unsafe_get64 buf pos))

let r_vlq buf pos_ref limit =
  let v = { contents = 0L } in
  let rec step count =
    if count >= 10 || pos_ref.contents >= limit then failwith "input_value: bad object";
    let b = int_of_char (bytes_unsafe_get buf pos_ref.contents) in
    pos_ref.contents <- pos_ref.contents + 1;
    if not (u64_le v.contents 0x01FFFFFFFFFFFFFFL) then failwith "input_value: bad object";
    v.contents <- i64_or (i64_lsl v.contents 7) (i64_of_int (b land 0x7f));
    if (b land 0x80) = 0 then v.contents else step (count + 1)
  in
  step 0

let parse_header_at buf ofs end_pos =
  let magic = r_u64 buf ofs end_pos 4 in
  if i64_eq magic 0x8495A6BEL then
    let len = r_u64 buf (ofs + 4) end_pos 4 in
    let expected = r_u64 buf (ofs + 8) end_pos 4 in
    let _w32 = r_u64 buf (ofs + 12) end_pos 4 in
    let _w64 = r_u64 buf (ofs + 16) end_pos 4 in
    (20, len, expected, 0L, false)
  else if i64_eq magic 0x8495A6BFL then
    let _unused = r_u64 buf (ofs + 4) end_pos 4 in
    let len = r_u64 buf (ofs + 8) end_pos 8 in
    let expected = r_u64 buf (ofs + 16) end_pos 8 in
    let _w64 = r_u64 buf (ofs + 24) end_pos 8 in
    (32, len, expected, 0L, false)
  else if i64_eq magic 0x8495A6BDL then (
    let hb = r_u8 buf (ofs + 4) end_pos in
    if (hb land 0xc0) <> 0 || hb < 10 || hb > 63 then failwith "input_value: bad object";
    if hb > end_pos - ofs then failwith "input_value: truncated object";
    let pr = { contents = ofs + 5 } in
    let limit = ofs + hb in
    let comp_len = r_vlq buf pr limit in
    let uncomp_len = r_vlq buf pr limit in
    let expected = r_vlq buf pr limit in
    ignore (r_vlq buf pr limit);
    ignore (r_vlq buf pr limit);
    if pr.contents <> limit then failwith "input_value: bad object";
    (hb, comp_len, expected, uncomp_len, true))
  else failwith "input_value: bad object"

let data_size_unsafe buff ofs =
  let blen = bytes_length buff in
  if ofs < 0 || ofs > blen then invalid_arg "Marshal.data_size";
  let hlen, len64, _, _, _ = parse_header_at buff ofs blen in
  let hlen64 = i64_of_int hlen in
  let limit = i64_of_int 0x3FFFFFFF in
  if not (u64_le len64 limit) || not (u64_le (i64_add len64 hlen64) limit) then
    failwith "input_value: object too large";
  i64_to_int len64 + hlen - 16

type decode_task =
  | SetRoot
  | SetSlot of obj_t * int

let decode_payload buf start_pos end_pos (expected64 : int64) (compressed : bool) : 'a =
  let zero = opaque_cast 0 in
  let root = { contents = zero } in
  let obj_cap = { contents = 256 } in
  let objs = { contents = array_make 256 zero } in
  let obj_cnt = { contents = 0 } in
  let own_cap = { contents = 256 } in
  let owners = { contents = array_make 256 zero } in
  let own_cnt = { contents = 0 } in
  let task_cap = { contents = 256 } in
  let tasks = { contents = array_make 256 SetRoot } in
  let task_cnt = { contents = 0 } in
  let atoms = array_make 256 zero in
  let expected =
    if i64_eq expected64 0L then 0
    else if not (u64_le expected64 (i64_of_int 0x3FFFFFFF)) then
      failwith "input_value: object too large"
    else i64_to_int expected64
  in
  let push_task t =
    if task_cnt.contents >= task_cap.contents then (
      let ncap = task_cap.contents * 2 in
      let nt = array_make ncap SetRoot in
      for i = 0 to task_cap.contents - 1 do
        array_unsafe_set nt i (array_unsafe_get tasks.contents i)
      done;
      tasks.contents <- nt;
      task_cap.contents <- ncap);
    array_unsafe_set tasks.contents task_cnt.contents t;
    task_cnt.contents <- task_cnt.contents + 1
  in
  let own value shared =
    if own_cnt.contents >= own_cap.contents then (
      let ncap = own_cap.contents * 2 in
      let no = array_make ncap zero in
      for i = 0 to own_cap.contents - 1 do
        array_unsafe_set no i (array_unsafe_get owners.contents i)
      done;
      owners.contents <- no;
      own_cap.contents <- ncap);
    array_unsafe_set owners.contents own_cnt.contents value;
    own_cnt.contents <- own_cnt.contents + 1;
    if shared && expected > 0 then (
      if obj_cnt.contents >= expected then failwith "input_value: ill-formed message";
      if obj_cnt.contents >= obj_cap.contents then (
        let ncap = obj_cap.contents * 2 in
        let nobjs = array_make ncap zero in
        for i = 0 to obj_cap.contents - 1 do
          array_unsafe_set nobjs i (array_unsafe_get objs.contents i)
        done;
        objs.contents <- nobjs;
        obj_cap.contents <- ncap);
      array_unsafe_set objs.contents obj_cnt.contents value;
      obj_cnt.contents <- obj_cnt.contents + 1)
  in
  let cleanup_on_error () =
    (* Sever partial cycles before releasing owners so ARC reclaims all nodes. *)
    for j = 0 to own_cnt.contents - 1 do
      let node = array_unsafe_get owners.contents j in
      let k = marshal_kind node in
      if k >= 0 && k <= 250 then
        let sz = obj_size node in
        for i = 0 to sz - 1 do
          obj_set_field node i zero
        done
    done;
    for j = 0 to own_cnt.contents - 1 do
      array_unsafe_set owners.contents j zero
    done;
    for j = 0 to obj_cnt.contents - 1 do
      array_unsafe_set objs.contents j zero
    done;
    for j = 0 to task_cnt.contents - 1 do
      array_unsafe_set tasks.contents j SetRoot
    done;
    root.contents <- zero
  in
  let pos = { contents = start_pos } in
  let get_u64 nb =
    let v = r_u64 buf pos.contents end_pos nb in
    pos.contents <- pos.contents + nb;
    v
  in
  let get_int_s nb =
    let v = r_i64_signed_be buf pos.contents end_pos nb in
    pos.contents <- pos.contents + nb;
    v
  in
  let read_cstr_z () =
    let tmp = bytes_create 64 in
    let i = { contents = 0 } in
    let ch = { contents = r_u8 buf pos.contents end_pos } in
    pos.contents <- pos.contents + 1;
    while ch.contents <> 0 do
      if i.contents >= 63 then failwith "input_value: unknown custom block identifier";
      bytes_unsafe_set tmp i.contents (char_of_int ch.contents);
      i.contents <- i.contents + 1;
      ch.contents <- r_u8 buf pos.contents end_pos;
      pos.contents <- pos.contents + 1
    done;
    let out = bytes_create i.contents in
    CamlinternalBulkOps.blit_bytes tmp 0 out 0 i.contents;
    bytes_unsafe_to_string out
  in
  let read_bigarray size32 size64 =
    let n64 = get_u64 4 in
    let flags64 = get_u64 4 in
    let flags = i64_to_int (i64_and flags64 0xFFFFFFFFL) in
    let kind = flags land 255 in
    let layout = (flags lsr 8) land 1 in
    if not (u64_le n64 16L) || kind >= 14 || flags <> (kind lor (layout lsl 8)) then
      failwith "input_value: invalid bigarray descriptor";
    let ndims = i64_to_int n64 in
    let exp32 = i64_of_int ((4 + ndims) * 4) in
    let exp64 = i64_of_int ((4 + ndims) * 8) in
    if (not (i64_eq size32 exp32)) || (not (i64_eq size64 exp64)) then
      failwith "input_value: invalid bigarray descriptor";
    let dims = array_make ndims 0 in
    let count = { contents = 1 } in
    for i = 0 to ndims - 1 do
      let d16 = i64_to_int (get_u64 2) in
      let d64 = if d16 = 65535 then get_u64 8 else i64_of_int d16 in
      if not (u64_le d64 (i64_of_int 0x3FFFFFFF)) then
        failwith "input_value: bigarray size overflow";
      let d = i64_to_int d64 in
      array_unsafe_set dims i d;
      if d > 0 && count.contents > (0x3FFFFFFF / 16) / d then
        failwith "input_value: bigarray size overflow";
      count.contents <- count.contents * d
    done;
    let cnt = count.contents in
    let elems = if kind = 10 || kind = 11 then cnt * 2 else cnt in
    let base_w =
      if kind = 10 || kind = 11 then ba_elem_width kind / 2
      else ba_elem_width kind
    in
    let wire_w =
      if kind = 8 || kind = 9 then (
        let wide = i64_to_int (get_u64 1) in
        if wide <> 0 && wide <> 1 then failwith "input_value: invalid bigarray integer size";
        if wide = 1 then 8 else 4)
      else base_w
    in
    if elems > (end_pos - pos.contents) / wire_w then
      failwith "input_value: truncated object";
    let raw_bytes = bytes_create (cnt * ba_elem_width kind) in
    if kind = 8 || kind = 9 then
      for i = 0 to elems - 1 do
        let bits =
          if wire_w = 4 then i64_of_i32 (i32_of_i64 (get_u64 4))
          else get_u64 8
        in
        bytes_unsafe_set64 raw_bytes (i * 8) bits
      done
    else
      for i = 0 to elems - 1 do
        let off = i * base_w in
        if base_w = 1 then
          bytes_unsafe_set raw_bytes off (char_of_int (i64_to_int (get_u64 1)))
        else if base_w = 2 then
          bytes_unsafe_set16 raw_bytes off (i64_to_int (get_u64 2))
        else if base_w = 4 then
          bytes_unsafe_set32 raw_bytes off (i32_of_i64 (get_u64 4))
        else
          bytes_unsafe_set64 raw_bytes off (get_u64 8)
      done;
    let ba = ba_of_bytes kind layout dims raw_bytes in
    own ba true;
    ba
  in
  let run_loop () =
    push_task SetRoot;
    while task_cnt.contents > 0 do
      task_cnt.contents <- task_cnt.contents - 1;
      let task = array_unsafe_get tasks.contents task_cnt.contents in
      array_unsafe_set tasks.contents task_cnt.contents SetRoot;
      let code = i64_to_int (get_u64 1) in
      let value =
        if code >= 0x80 then
          let tag = code land 15 in
          let n = (code lsr 4) land 7 in
          if n = 0 then (
            if array_unsafe_get atoms tag == zero then (
              let b = obj_block tag 0 in
              array_unsafe_set atoms tag b;
              own b false;
              b)
            else array_unsafe_get atoms tag)
          else (
            let b = obj_block tag n in
            own b true;
            for i = n - 1 downto 0 do
              push_task (SetSlot (b, i))
            done;
            b)
        else if code >= 0x40 then opaque_cast (code - 0x40)
        else if code >= 0x20 then
          let n = code - 0x20 in
          if n > end_pos - pos.contents then failwith "input_value: truncated object"
          else
            let s = bytes_create n in
            CamlinternalBulkOps.blit_bytes buf pos.contents s 0 n;
            pos.contents <- pos.contents + n;
            let o : obj_t = opaque_cast s in
            own o true;
            o
        else
          match code with
          | 0 -> opaque_cast (get_int_s 1)
          | 1 -> opaque_cast (get_int_s 2)
          | 2 -> opaque_cast (get_int_s 4)
          | 3 -> opaque_cast (i64_to_int (get_u64 8))
          | 4 | 5 | 6 | 0x14 ->
              let nb = if code = 4 then 1 else if code = 5 then 2 else if code = 6 then 4 else 8 in
              let n64 = get_u64 nb in
              if compressed then
                if not (u64_lt n64 (i64_of_int obj_cnt.contents)) then
                  failwith "input_value: invalid shared reference"
                else array_unsafe_get objs.contents (i64_to_int n64)
              else if i64_eq n64 0L || not (u64_le n64 (i64_of_int obj_cnt.contents)) then
                failwith "input_value: invalid shared reference"
              else array_unsafe_get objs.contents (obj_cnt.contents - i64_to_int n64)
          | 8 | 0x13 ->
              let hd = get_u64 (if code = 8 then 4 else 8) in
              let tag = i64_to_int (i64_and hd 255L) in
              let n64 = i64_lsr hd 10 in
              if tag >= 245 && tag <> 246 && tag <> 248 && tag <> 250 && not (i64_eq n64 0L && tag = 254) then
                failwith "input_value: unsupported block tag";
              let rem64 = i64_of_int (end_pos - pos.contents) in
              if (tag = 248 && not (u64_le 2L n64)) || not (u64_le n64 rem64) ||
                 not (u64_le n64 (i64_of_int 0x0FFFFFFF)) || (tag <> 0 && not (u64_le n64 65535L)) then
                failwith "input_value: block too large";
              let n = i64_to_int n64 in
              if n = 0 then (
                if array_unsafe_get atoms tag == zero then (
                  let b = obj_block tag 0 in
                  array_unsafe_set atoms tag b;
                  own b false;
                  b)
                else array_unsafe_get atoms tag)
              else (
                let b =
                  if tag = 0 && n > 65535 then opaque_cast (array_make n zero)
                  else obj_block tag n
                in
                own b true;
                for i = n - 1 downto 0 do
                  push_task (SetSlot (b, i))
                done;
                b)
          | 9 | 10 | 0x15 ->
              let nb = if code = 9 then 1 else if code = 10 then 4 else 8 in
              let n64 = get_u64 nb in
              let rem64 = i64_of_int (end_pos - pos.contents) in
              if not (u64_le n64 rem64) || not (u64_le n64 (i64_of_int 0x3FFFFFFF)) then
                failwith "input_value: truncated object";
              let n = i64_to_int n64 in
              let s = bytes_create n in
              CamlinternalBulkOps.blit_bytes buf pos.contents s 0 n;
              pos.contents <- pos.contents + n;
              let o : obj_t = opaque_cast s in
              own o true;
              o
          | 11 | 12 ->
              if 8 > end_pos - pos.contents then failwith "input_value: truncated object";
              let raw =
                if code = 12 then (let v = bytes_unsafe_get64 buf pos.contents in pos.contents <- pos.contents + 8; v)
                else get_u64 8
              in
              let o : obj_t = opaque_cast (float_of_i64_bits raw) in
              own o true;
              o
          | 13 | 14 | 15 | 7 | 0x16 | 0x17 ->
              let nb = if code = 13 || code = 14 then 1 else if code = 15 || code = 7 then 4 else 8 in
              let little = code = 14 || code = 7 || code = 0x17 in
              let n64 = get_u64 nb in
              let max_elems64 = i64_of_int ((end_pos - pos.contents) / 8) in
              if not (u64_le n64 max_elems64) then failwith "input_value: truncated object";
              let n = i64_to_int n64 in
              let fa = CamlinternalBulkOps.floatarray_create n in
              for i = 0 to n - 1 do
                let raw =
                  if little then (let v = bytes_unsafe_get64 buf pos.contents in pos.contents <- pos.contents + 8; v)
                  else get_u64 8
                in
                floatarray_unsafe_set fa i (float_of_i64_bits raw)
              done;
              let o : obj_t = opaque_cast fa in
              own o true;
              o
          | 0x18 | 0x19 ->
              let id = read_cstr_z () in
              if code = 0x18 then (
                let s32 = get_u64 4 in
                let s64 = get_u64 8 in
                if id = "_bigarr02" then read_bigarray s32 s64
                else failwith "input_value: unknown custom block identifier")
              else if id = "_i" then
                let x : int32 = i32_of_i64 (get_u64 4) in
                let o : obj_t = opaque_cast x in
                own o true;
                o
              else if id = "_j" then
                let x : int64 = get_u64 8 in
                let o : obj_t = opaque_cast x in
                own o true;
                o
              else if id = "_n" then
                let sz = i64_to_int (get_u64 1) in
                if sz <> 1 && sz <> 2 then failwith "input_value: ill-formed native integer"
                else
                  let bits =
                    if sz = 1 then i64_of_i32 (i32_of_i64 (get_u64 4))
                    else get_u64 8
                  in
                  let o : obj_t = opaque_cast (native_of_i64 bits) in
                  own o true;
                  o
              else if id = "_bigarr02" then
                failwith "input_value: invalid custom block length"
              else failwith "input_value: unknown custom block identifier"
          | _ -> failwith "input_value: ill-formed message"
      in
      (match task with
      | SetRoot -> root.contents <- value
      | SetSlot (blk, idx) -> obj_set_field blk idx value)
    done;
    if pos.contents <> end_pos || (expected > 0 && obj_cnt.contents <> expected) then
      failwith "input_value: ill-formed message";
    for j = 0 to own_cnt.contents - 1 do
      let node = array_unsafe_get owners.contents j in
      if marshal_kind node = 248 then
        let oid = obj_field node 1 in
        if marshal_kind oid = -1 && (opaque_cast oid : int) >= 0 then
          obj_set_field node 1 (fresh_oo_id (opaque_cast 0))
    done;
    let res = root.contents in
    for j = 0 to own_cnt.contents - 1 do
      array_unsafe_set owners.contents j zero
    done;
    for j = 0 to obj_cnt.contents - 1 do
      array_unsafe_set objs.contents j zero
    done;
    opaque_cast res
  in
  try run_loop ()
  with exn ->
    cleanup_on_error ();
    raise exn

let decode_from_slice buf ofs avail : 'a =
  let hlen, len64, expected64, uncomp64, compressed =
    parse_header_at buf ofs (ofs + avail)
  in
  let rem64 = i64_of_int (avail - hlen) in
  if not (u64_le len64 rem64) then failwith "input_value: truncated object";
  let comp_len = i64_to_int len64 in
  if compressed then
    match codec_ref.contents with
    | None -> failwith "input_value: compressed object, zstd unavailable"
    | Some codec ->
        if i64_eq uncomp64 0L || not (u64_le uncomp64 (i64_of_int 0x3FFFFFFF)) then
          failwith "input_value: object too large";
        let uncomp_len = i64_to_int uncomp64 in
        let uncomp_buf = bytes_create uncomp_len in
        if codec.decompress buf (ofs + hlen) comp_len uncomp_buf <> 0 then
          failwith "input_value: decompression error";
        decode_payload uncomp_buf 0 uncomp_len expected64 true
  else
    decode_payload buf (ofs + hlen) (ofs + hlen + comp_len) expected64 false

let from_bytes_unsafe buff ofs =
  let blen = bytes_length buff in
  if ofs < 0 || ofs > blen then invalid_arg "Marshal.from_bytes";
  decode_from_slice buff ofs (blen - ofs)

let read_exact_chan ic dst ofs len allow_eof0 =
  let got = { contents = 0 } in
  while got.contents < len do
    let n = ml_input ic dst (ofs + got.contents) (len - got.contents) in
    if n = 0 then (
      if got.contents = 0 && allow_eof0 then raise End_of_file
      else failwith "input_value: truncated object");
    got.contents <- got.contents + n
  done

let from_channel ic =
  let hdr = bytes_create 64 in
  read_exact_chan ic hdr 0 5 true;
  let magic = r_u64 hdr 0 5 4 in
  let hlen =
    if i64_eq magic 0x8495A6BEL then 20
    else if i64_eq magic 0x8495A6BFL then 32
    else if i64_eq magic 0x8495A6BDL then
      let hb = int_of_char (bytes_unsafe_get hdr 4) in
      if (hb land 0xc0) <> 0 || hb < 10 || hb > 63 then failwith "input_value: bad object"
      else hb
    else failwith "input_value: bad object"
  in
  read_exact_chan ic hdr 5 (hlen - 5) false;
  let _, len64, expected64, uncomp64, compressed = parse_header_at hdr 0 hlen in
  if not (u64_le len64 (i64_of_int 0x3FFFFFFF)) then
    failwith "input_value: object too large";
  let payload_len = i64_to_int len64 in
  (* Read in bounded chunks before committing to a large allocation so truncated
     or huge-length streams fail on EOF without multi-gigabyte allocations. *)
  let init_cap = if payload_len <= 65536 then payload_len else 65536 in
  let payload = { contents = bytes_create init_cap } in
  let cap = { contents = init_cap } in
  let total_read = { contents = 0 } in
  while total_read.contents < payload_len do
    let chunk = payload_len - total_read.contents in
    let want = if chunk > 65536 then 65536 else chunk in
    if total_read.contents + want > cap.contents then (
      let next = { contents = cap.contents * 2 } in
      if next.contents > payload_len then next.contents <- payload_len;
      let nb = bytes_create next.contents in
      CamlinternalBulkOps.blit_bytes payload.contents 0 nb 0 total_read.contents;
      payload.contents <- nb;
      cap.contents <- next.contents);
    read_exact_chan ic payload.contents total_read.contents want false;
    total_read.contents <- total_read.contents + want
  done;
  if compressed then
    match codec_ref.contents with
    | None -> failwith "input_value: compressed object, zstd unavailable"
    | Some codec ->
        if i64_eq uncomp64 0L || not (u64_le uncomp64 (i64_of_int 0x3FFFFFFF)) then
          failwith "input_value: object too large";
        let uncomp_len = i64_to_int uncomp64 in
        let uncomp_buf = bytes_create uncomp_len in
        if codec.decompress payload.contents 0 payload_len uncomp_buf <> 0 then
          failwith "input_value: decompression error";
        decode_payload uncomp_buf 0 uncomp_len expected64 true
  else
    decode_payload payload.contents 0 payload_len expected64 false
