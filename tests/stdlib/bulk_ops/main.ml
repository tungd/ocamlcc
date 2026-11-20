let check_invalid_arg label f =
  try
    ignore (f ());
    Printf.printf "%s:UNEXPECTED_OK\n" label
  with Invalid_argument _ -> Printf.printf "%s:INVALID_ARG\n" label

let () =
  (* Bytes blit / overlap / blit_string / fill / equal / compare *)
  let b = Bytes.of_string "abcdefgh" in
  Bytes.blit b 0 b 2 4;
  Printf.printf "b_fwd:%s\n" (Bytes.to_string b);
  Bytes.blit b 2 b 0 4;
  Printf.printf "b_bwd:%s\n" (Bytes.to_string b);
  Bytes.fill b 1 3 'X';
  Printf.printf "b_fill:%s\n" (Bytes.to_string b);
  Bytes.blit_string "1234" 1 b 2 2;
  Printf.printf "b_str:%s\n" (Bytes.to_string b);
  check_invalid_arg "b_oob1" (fun () -> Bytes.blit b (-1) b 0 1);
  check_invalid_arg "b_oob2" (fun () -> Bytes.blit b 6 b 0 3);
  check_invalid_arg "b_oob3" (fun () -> Bytes.fill b 5 4 'z');
  let shared = Bytes.of_string "abcdefgh" in
  let alias = Bytes.unsafe_to_string shared in
  Bytes.blit_string alias 0 shared 2 4;
  assert (Bytes.to_string shared = "ababcdgh");
  Bytes.blit_string alias 2 shared 0 4;
  assert (Bytes.to_string shared = "abcdcdgh");
  Bytes.blit_string alias 8 shared 8 0;
  Bytes.fill shared 8 0 '\255';
  Bytes.fill shared 1 2 '\255';
  assert (Bytes.to_string shared = "a\255\255dcdgh");

  (* String equal / compare with embedded NUL *)
  let s1 = "ab\000c" in
  let s2 = "ab\000d" in
  let s3 = "ab\000c" in
  Printf.printf "seq:%b|%b|%d|%d|%b|%b\n"
    (String.equal s1 s3) (String.equal s1 s2)
    (String.compare s1 s2) (String.compare s2 s1)
    (s1 < s2) (s1 <= s3 && s2 > s1);
  Printf.printf "shash:%b\n"
    (String.seeded_hash 17 s1 = String.seeded_hash 17 s3);

  (* Unaligned 16/32/64-bit bytes/string access + bswap *)
  let u = Bytes.make 16 '\000' in
  Bytes.set_uint16_le u 1 0xBEEF;
  Bytes.set_uint16_be u 3 0x1234;
  Bytes.set_int32_le u 5 0x12345678l;
  Bytes.set_int64_be u 7 0x0102030405060708L;
  Printf.printf "u:%04x|%04x|%08lx|%016Lx\n"
    (Bytes.get_uint16_le u 1)
    (Bytes.get_uint16_be u 3)
    (Bytes.get_int32_le u 5)
    (Bytes.get_int64_be u 7);
  let su = Bytes.to_string u in
  Printf.printf "su:%04x|%04x|%08lx|%016Lx\n"
    (String.get_uint16_le su 1)
    (String.get_uint16_be su 3)
    (String.get_int32_le su 5)
    (String.get_int64_be su 7);
  check_invalid_arg "u16_short" (fun () -> ignore (Bytes.get_uint16_ne (Bytes.create 1) 0));
  check_invalid_arg "u32_short" (fun () -> ignore (Bytes.get_int32_ne (Bytes.create 3) 0));
  check_invalid_arg "u64_short" (fun () -> Bytes.set_int64_ne (Bytes.create 7) 0 0L);
  check_invalid_arg "u16_neg" (fun () -> ignore (Bytes.get_uint16_ne u (-1)));

  (* Buffer add_uint16 / add_int32 / add_int64 *)
  let buf = Buffer.create 16 in
  Buffer.add_uint16_be buf 0xCAFE;
  Buffer.add_int32_le buf 0x11223344l;
  let bs = Buffer.contents buf in
  Printf.printf "buf:%04x|%08lx\n"
    (String.get_uint16_be bs 0) (String.get_int32_le bs 2);

  (* Array sub / append / concat / blit / fill / create_float *)
  let a = [| 10; 20; 30; 40; 50 |] in
  let asub = Array.sub a 1 3 in
  let aapp = Array.append asub [| 60; 70 |] in
  let acat = Array.concat [ [||]; [| 1; 2 |]; [||]; [| 3 |] ] in
  Array.blit a 0 a 2 3;
  Array.fill a 0 2 99;
  Printf.printf "arr:%s|%s|%s|%s\n"
    (String.concat "," (Array.to_list (Array.map string_of_int asub)))
    (String.concat "," (Array.to_list (Array.map string_of_int aapp)))
    (String.concat "," (Array.to_list (Array.map string_of_int acat)))
    (String.concat "," (Array.to_list (Array.map string_of_int a)));
  let cf = Array.create_float 3 in
  Array.fill cf 1 2 2.5;
  let cf2 = Array.append [||] (Array.sub cf 1 2) in
  Printf.printf "farr:%d|%.1f|%.1f|%.1f\n"
    (Array.length (Array.create_float 0)) cf.(0) cf2.(0) cf2.(1);
  check_invalid_arg "arr_sub" (fun () -> Array.sub a 3 3);
  check_invalid_arg "arr_blit" (fun () -> Array.blit a 4 a 0 2);

  (* Float.Array *)
  let fa = Float.Array.make 4 1.5 in
  Float.Array.set fa 2 9.5;
  Float.Array.blit fa 1 fa 2 2;
  let fas = Float.Array.sub fa 1 3 in
  let fac = Float.Array.concat [ Float.Array.create 0; fas; Float.Array.make 1 7.5 ] in
  let flt_str f = Printf.sprintf "%.1f" f in
  Printf.printf "fa:%d|%.1f|%.1f|%.1f|%.1f|%s\n"
    (Float.Array.length (Float.Array.create 0))
    (Float.Array.get fa 0) (Float.Array.get fa 1)
    (Float.Array.get fa 2) (Float.Array.get fa 3)
    (String.concat "," (List.init (Float.Array.length fac) (fun i -> flt_str (Float.Array.get fac i))));
  check_invalid_arg "fa_neg" (fun () -> Float.Array.create (-1));
  check_invalid_arg "fa_oob" (fun () -> Float.Array.fill fa 3 2 0.0)
