(* Public P-256/SHA-256 vector exercised by Mirage Crypto 2.4.1. *)
module P256 = Mirage_crypto_ec.P256.Dsa

let of_hex hex =
  String.init (String.length hex / 2) (fun i ->
    Char.chr (int_of_string ("0x" ^ String.sub hex (2 * i) 2)))

let () =
  let encoded = of_hex
    ("04" ^
     "60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6" ^
     "7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299") in
  let key = match P256.pub_of_octets encoded with
    | Ok key -> key
    | Error _ -> failwith "P-256 key decoding"
  in
  assert (P256.pub_to_octets key = encoded);
  let signature =
    of_hex "EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716",
    of_hex "F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8" in
  let digest = of_hex "AF2BDBE1AA9B6EC1E2ADE1D694F41FC71A831D0268E9891562113D8A62ADD1BF" in
  assert (P256.verify ~key signature digest);
  assert (not (P256.verify ~key signature (String.make 32 '\000')));
  print_endline "P-256 public-key verification: PASS";
  Mirage_crypto_rng_unix.use_default ();
  let buffer = Bytes.make 608 'Z' in
  Mirage_crypto_rng.generate_into buffer ~off:4 600;
  assert (Bytes.sub_string buffer 0 4 = "ZZZZ");
  assert (Bytes.sub_string buffer 604 4 = "ZZZZ");
  assert (Bytes.sub_string buffer 4 600 <> String.make 600 'Z');
  print_endline "Unix entropy at offset: PASS"
