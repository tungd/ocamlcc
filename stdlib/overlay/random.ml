(* Pseudo-random number generator overlay: identical LXM algorithm to upstream
   OCaml 5.5.0 Random, backed by [int64 array] instead of Bigarray.Array1. *)

external random_seed: unit -> int array = "caml_sys_random_seed"

module State = struct
  type t = int64 array

  let next (st : t) : int64 =
    let a = st.(0) and s = st.(1) and q0 = st.(2) and q1 = st.(3) in
    let z = Int64.add s q0 in
    let z =
      Int64.mul
        (Int64.logxor z (Int64.shift_right_logical z 32))
        0xdaba0b6eb09322e3L
    in
    let z =
      Int64.mul
        (Int64.logxor z (Int64.shift_right_logical z 32))
        0xdaba0b6eb09322e3L
    in
    let z = Int64.logxor z (Int64.shift_right_logical z 32) in
    st.(1) <- Int64.add (Int64.mul s 0xd1342543de82ef95L) a;
    let q1 = Int64.logxor q1 q0 in
    let q0 =
      Int64.logor (Int64.shift_left q0 24) (Int64.shift_right_logical q0 40)
    in
    let q0 = Int64.logxor (Int64.logxor q0 q1) (Int64.shift_left q1 16) in
    let q1 =
      Int64.logor (Int64.shift_left q1 37) (Int64.shift_right_logical q1 27)
    in
    st.(2) <- q0;
    st.(3) <- q1;
    z

  let create () : t = Array.make 4 0L

  let set (s : t) i1 i2 i3 i4 =
    s.(0) <- Int64.logor i1 1L;
    s.(1) <- i2;
    s.(2) <- (if i3 <> 0L then i3 else 1L);
    s.(3) <- (if i4 <> 0L then i4 else 2L)

  let mk i1 i2 i3 i4 =
    let s = create () in
    set s i1 i2 i3 i4;
    s

  let serialization_prefix = "lxm1:"
  let serialization_prefix_len = String.length serialization_prefix

  let to_binary_string s =
    let prefix = serialization_prefix in
    let preflen = serialization_prefix_len in
    let buf = Bytes.create (preflen + (4 * 8)) in
    Bytes.blit_string prefix 0 buf 0 preflen;
    for i = 0 to 3 do
      Bytes.set_int64_le buf (preflen + (i * 8)) s.(i)
    done;
    Bytes.unsafe_to_string buf

  let of_binary_string buf =
    let prefix = serialization_prefix in
    let preflen = serialization_prefix_len in
    if String.length buf <> preflen + (4 * 8)
       || not (String.starts_with ~prefix buf)
    then
      failwith
        ("Random.State.of_binary_string: expected a format compatible with OCaml "
         ^ Sys.ocaml_version);
    let i1 = String.get_int64_le buf (preflen + (0 * 8)) in
    let i2 = String.get_int64_le buf (preflen + (1 * 8)) in
    let i3 = String.get_int64_le buf (preflen + (2 * 8)) in
    let i4 = String.get_int64_le buf (preflen + (3 * 8)) in
    mk i1 i2 i3 i4

  let assign (dst : t) (src : t) = Array.blit src 0 dst 0 4

  let copy s =
    let s' = create () in
    assign s' s;
    s'

  let reinit s seed =
    let n = Array.length seed in
    let b = Bytes.create ((n * 8) + 1) in
    for i = 0 to n - 1 do
      Bytes.set_int64_le b (i * 8) (Int64.of_int seed.(i))
    done;
    Bytes.set b (n * 8) '\x01';
    let d1 = Digest.MD5.bytes b in
    Bytes.set b (n * 8) '\x02';
    let d2 = Digest.MD5.bytes b in
    set s (String.get_int64_le d1 0) (String.get_int64_le d1 8)
      (String.get_int64_le d2 0) (String.get_int64_le d2 8)

  let make seed =
    let s = create () in
    reinit s seed;
    s

  let make_self_init () = make (random_seed ())

  let min_int31 = -0x4000_0000
  let max_int31 = 0x3FFF_FFFF
  let min_int32 = -(1 lsl 31)
  let max_int32 = (1 lsl 31) - 1

  let bits s = Int64.to_int (next s) land max_int31

  let rec int_aux s n mask =
    let r = Int64.to_int (next s) land mask in
    let v = r mod n in
    if r - v > mask - n + 1 then int_aux s n mask else v

  let int s bound =
    if bound > max_int31 || bound <= 0 then invalid_arg "Random.int"
    else int_aux s bound max_int31

  let full_int s bound =
    if bound <= 0 then invalid_arg "Random.full_int"
    else
      int_aux s bound
        (if bound <= max_int31 then max_int31
         else if bound <= max_int32 then max_int32
         else max_int)

  let rec int_in_large_range s ~min ~max ~nbits =
    let drop = Sys.int_size - nbits in
    let r = (Int64.to_int (next s) lsl drop) asr drop in
    if r < min || r > max then int_in_large_range s ~min ~max ~nbits else r

  let int_in_range_aux s ~min ~max ~mask ~nbits =
    let span = max - min + 1 in
    if span <= mask && span > 0 then min + int_aux s span mask
    else int_in_large_range s ~min ~max ~nbits

  let int_in_range s ~min ~max =
    if min > max then invalid_arg "Random.int_in_range";
    if min >= min_int31 && max <= max_int31 then
      int_in_range_aux s ~min ~max ~mask:max_int31 ~nbits:31
    else if min >= min_int32 && max <= max_int32 then
      int_in_range_aux s ~min ~max ~mask:max_int32 ~nbits:32
    else
      int_in_range_aux s ~min ~max ~mask:max_int ~nbits:Sys.int_size

  let bits32 s = Int64.to_int32 (next s)

  let rec int32aux s n =
    let r = Int32.shift_right_logical (bits32 s) 1 in
    let v = Int32.rem r n in
    if Int32.(sub r v > add (sub max_int n) 1l) then int32aux s n else v

  let int32 s bound =
    if bound <= 0l then invalid_arg "Random.int32" else int32aux s bound

  let rec int32_in_range_aux s ~min ~max =
    let r = Int64.to_int32 (next s) in
    if r < min || r > max then int32_in_range_aux s ~min ~max else r

  let int32_in_range s ~min ~max =
    if min > max then invalid_arg "Random.int32_in_range"
    else
      let span = Int32.succ (Int32.sub max min) in
      if span <= Int32.zero then int32_in_range_aux s ~min ~max
      else Int32.add min (int32aux s span)

  let bits64 s = next s

  let rec int64aux s n =
    let r = Int64.shift_right_logical (bits64 s) 1 in
    let v = Int64.rem r n in
    if Int64.(sub r v > add (sub max_int n) 1L) then int64aux s n else v

  let int64 s bound =
    if bound <= 0L then invalid_arg "Random.int64" else int64aux s bound

  let rec int64_in_range_aux s ~min ~max =
    let r = next s in
    if r < min || r > max then int64_in_range_aux s ~min ~max else r

  let int64_in_range s ~min ~max =
    if min > max then invalid_arg "Random.int64_in_range"
    else
      let span = Int64.succ (Int64.sub max min) in
      if span <= Int64.zero then int64_in_range_aux s ~min ~max
      else Int64.add min (int64aux s span)

  let nativebits =
    if Nativeint.size = 32 then fun s -> Nativeint.of_int32 (bits32 s)
    else fun s -> Int64.to_nativeint (bits64 s)

  let nativeint =
    if Nativeint.size = 32 then fun s bound ->
      Nativeint.of_int32 (int32 s (Nativeint.to_int32 bound))
    else fun s bound -> Int64.to_nativeint (int64 s (Int64.of_nativeint bound))

  let nativeint_in_range =
    if Nativeint.size = 32 then fun s ~min ~max ->
      Nativeint.of_int32
        (int32_in_range s ~min:(Nativeint.to_int32 min)
           ~max:(Nativeint.to_int32 max))
    else fun s ~min ~max ->
      Int64.to_nativeint
        (int64_in_range s ~min:(Int64.of_nativeint min)
           ~max:(Int64.of_nativeint max))

  let rec rawfloat s =
    let b = next s in
    let n = Int64.shift_right_logical b 11 in
    if n <> 0L then Int64.to_float n *. 0x1.p-53 else rawfloat s

  let float s bound = rawfloat s *. bound
  let bool s = next s < 0L

  let split s =
    let i1 = bits64 s in
    let i2 = bits64 s in
    let i3 = bits64 s in
    let i4 = bits64 s in
    mk i1 i2 i3 i4
end

let mk_default () =
  State.mk (-6196874289567705097L) 586573249833713189L (-8591268803865043407L)
    6388613595849772044L

let random_key = Domain.DLS.new_key ~split_from_parent:State.split mk_default
let bits () = State.bits (Domain.DLS.get random_key)
let int bound = State.int (Domain.DLS.get random_key) bound
let full_int bound = State.full_int (Domain.DLS.get random_key) bound

let int_in_range ~min ~max =
  State.int_in_range (Domain.DLS.get random_key) ~min ~max

let int32 bound = State.int32 (Domain.DLS.get random_key) bound

let int32_in_range ~min ~max =
  State.int32_in_range (Domain.DLS.get random_key) ~min ~max

let nativeint bound = State.nativeint (Domain.DLS.get random_key) bound

let nativeint_in_range ~min ~max =
  State.nativeint_in_range (Domain.DLS.get random_key) ~min ~max

let int64 bound = State.int64 (Domain.DLS.get random_key) bound

let int64_in_range ~min ~max =
  State.int64_in_range (Domain.DLS.get random_key) ~min ~max

let float scale = State.float (Domain.DLS.get random_key) scale
let bool () = State.bool (Domain.DLS.get random_key)
let bits32 () = State.bits32 (Domain.DLS.get random_key)
let bits64 () = State.bits64 (Domain.DLS.get random_key)
let nativebits () = State.nativebits (Domain.DLS.get random_key)
let full_init seed = State.reinit (Domain.DLS.get random_key) seed
let init seed = full_init [| seed |]
let self_init () = full_init (random_seed ())
let split () = State.split (Domain.DLS.get random_key)
let get_state () = State.copy (Domain.DLS.get random_key)
let set_state s = State.assign (Domain.DLS.get random_key) s
