let check_invalid f =
  try
    ignore (f ());
    assert false
  with Invalid_argument _ -> ()

let check_eof f =
  try
    ignore (f ());
    assert false
  with End_of_file -> ()

let test_suite (module D : Digest.S) label =
  let empty = D.string "" in
  let abc = D.string "abc" in
  let sub = D.substring "xxabcxx" 2 3 in
  let subb = D.subbytes (Bytes.of_string "yyabcyy") 2 3 in
  assert (D.equal abc sub);
  assert (D.equal abc subb);
  assert (D.compare empty abc <> 0);
  assert (String.length empty = D.hash_length);

  let hex = D.to_hex abc in
  assert (String.length hex = D.hash_length * 2);
  assert (D.equal (D.of_hex (String.uppercase_ascii hex)) abc);
  check_invalid (fun () -> D.to_hex "short");
  check_invalid (fun () -> D.of_hex "00");
  check_invalid (fun () -> D.of_hex (String.make (D.hash_length * 2) 'z'));
  check_invalid (fun () -> D.substring "abc" (-1) 2);
  check_invalid (fun () -> D.substring "abc" 2 2);
  check_invalid (fun () -> D.subbytes (Bytes.of_string "abc") 0 4);

  (* Multi-block > 4096 bytes streaming through file & channel *)
  let big_len = 10000 in
  let big = String.init big_len (fun i -> Char.chr ((i * 37 + 13) land 0xff)) in
  let expected_big = D.string big in
  let tmp = Filename.temp_file "ocamlcc_digest_" ".bin" in
  Fun.protect
    ~finally:(fun () -> (try Sys.remove tmp with _ -> ()))
    (fun () ->
      Out_channel.with_open_bin tmp (fun oc -> Out_channel.output_string oc big);
      let file_dig = D.file tmp in
      assert (D.equal file_dig expected_big);
      In_channel.with_open_bin tmp (fun ic ->
          let partial = D.channel ic 130 in
          let expected_130 = D.substring big 0 130 in
          assert (D.equal partial expected_130));
      In_channel.with_open_bin tmp (fun ic ->
          check_eof (fun () -> D.channel ic (big_len + 1)));
      Out_channel.with_open_bin tmp (fun oc -> D.output oc expected_big);
      In_channel.with_open_bin tmp (fun ic ->
          let rd = D.input ic in
          assert (D.equal rd expected_big)));

  Printf.printf "%s:empty=%s abc=%s big=%s\n" label (D.to_hex empty) hex
    (D.to_hex expected_big)

let () =
  (* Known RFC 1321 MD5 check + top-level Digest API *)
  assert (Digest.to_hex (Digest.string "") = "d41d8cd98f00b204e9800998ecf8427e");
  assert (Digest.to_hex (Digest.string "abc") = "900150983cd24fb0d6963f7d28e17f72");
  assert (Digest.equal (Digest.from_hex "900150983cd24fb0d6963f7d28e17f72")
            (Digest.string "abc"));
  assert (Digest.equal (Digest.bytes (Bytes.of_string "abc")) (Digest.string "abc"));
  assert (Digest.equal (Digest.substring "xxabcyy" 2 3) (Digest.string "abc"));
  assert (Digest.equal (Digest.subbytes (Bytes.of_string "xxabcyy") 2 3)
            (Digest.string "abc"));
  test_suite (module Digest.MD5) "MD5";
  test_suite (module Digest.BLAKE128) "BLAKE128";
  test_suite (module Digest.BLAKE256) "BLAKE256";
  test_suite (module Digest.BLAKE512) "BLAKE512"
