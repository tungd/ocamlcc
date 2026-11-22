type t = (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

external get16 : t -> int -> int = "%caml_bigstring_get16"
external get32 : t -> int -> int32 = "%caml_bigstring_get32"
external get64 : t -> int -> int64 = "%caml_bigstring_get64"
external set16 : t -> int -> int -> unit = "%caml_bigstring_set16"
external set32 : t -> int -> int32 -> unit = "%caml_bigstring_set32"
external set64 : t -> int -> int64 -> unit = "%caml_bigstring_set64"
external unsafe_get16 : t -> int -> int = "%caml_bigstring_get16u"
external unsafe_get32 : t -> int -> int32 = "%caml_bigstring_get32u"
external unsafe_get64 : t -> int -> int64 = "%caml_bigstring_get64u"
external unsafe_set16 : t -> int -> int -> unit = "%caml_bigstring_set16u"
external unsafe_set32 : t -> int -> int32 -> unit = "%caml_bigstring_set32u"
external unsafe_set64 : t -> int -> int64 -> unit = "%caml_bigstring_set64u"

let bounds f =
  match f () with
  | exception Invalid_argument _ -> ()
  | _ -> assert false

let check width encode (get, set) (unsafe_get, unsafe_set) first second =
  let open Bigarray in
  let owner = Array1.create char c_layout (width + 5) in
  Array1.fill owner '\x7f';
  let view = Array1.sub owner 2 (width + 1) in
  let expected = Bytes.create width in
  let check_bytes word =
    encode expected 0 word;
    for i = 0 to width - 1 do
      assert (owner.{i + 3} = Bytes.get expected i)
    done;
    assert (owner.{2} = '\x7f' && owner.{width + 3} = '\x7f')
  in
  encode expected 0 first;
  for i = 0 to width - 1 do view.{i + 1} <- Bytes.get expected i done;
  assert (unsafe_get view 1 = first && get view 1 = first);
  unsafe_set view 1 second;
  check_bytes second;
  assert (get view 1 = second);
  set view 1 first;
  check_bytes first;
  bounds (fun () -> get view (-1));
  bounds (fun () -> get view 2);
  bounds (fun () -> set view max_int second);
  bounds (fun () -> set view 2 second);
  bounds (fun () -> get (Array1.sub view 0 0) 0);
  check_bytes first

let () =
  check 8 Bytes.set_int64_ne (get64, set64) (unsafe_get64, unsafe_set64)
    0x0807060504030201L 0x90abcdef76543210L;
  check 4 Bytes.set_int32_ne (get32, set32) (unsafe_get32, unsafe_set32)
    0x04030201l 0x89abcdefl;
  check 2 Bytes.set_uint16_ne (get16, set16) (unsafe_get16, unsafe_set16)
    0xabcd 0xfe98;
  print_endline "bigstring: native-endian unaligned access, subviews, bounds"
