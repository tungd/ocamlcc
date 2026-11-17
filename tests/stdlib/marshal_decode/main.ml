let bytes hex =
  let digit c = if c >= '0' && c <= '9' then Char.code c - 48 else Char.code c - 87 in
  Bytes.init (String.length hex / 2) (fun i -> Char.chr (16 * digit hex.[2*i] + digit hex.[2*i+1]))
let test () =
  (* 32-byte big-model header, with a small integer payload. *)
  let big = bytes "8495a6bf000000000000000000000001000000000000000000000000000000006a" in
  assert (Marshal.from_bytes big 0 = 42);
  assert (Marshal.total_size big 0 = Bytes.length big);
  (* Foreign big-endian double and double-array payloads. *)
  let number = bytes "8495a6be000000090000000100000003000000020b3ff8000000000000" in
  assert (Marshal.from_bytes number 0 = 1.5);
  let array = bytes "8495a6be000000120000000100000005000000030d023ff8000000000000c000000000000000" in
  assert (Marshal.from_bytes array 0 = [|1.5; -2.|]);
  (* 64-bit block header, one field containing 42. *)
  let block = bytes "8495a6be0000000a0000000100000002000000021300000000000004006a" in
  assert (!(Marshal.from_bytes block 0 : int ref) = 42);
  print_endline "marshal: foreign endian payloads and 64-bit headers"
let () = try test () with e -> prerr_endline (Printexc.to_string e); exit 1
