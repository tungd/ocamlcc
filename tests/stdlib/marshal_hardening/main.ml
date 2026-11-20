let stream_of_bytes payload =
  let n = Bytes.length payload in
  let hdr = Bytes.make (20 + n) '\000' in
  Bytes.set hdr 0 '\x84';
  Bytes.set hdr 1 '\x95';
  Bytes.set hdr 2 '\xa6';
  Bytes.set hdr 3 '\xbe';
  Bytes.set_int32_be hdr 4 (Int32.of_int n);
  Bytes.set_int32_be hdr 8 1l;
  Bytes.set_int32_be hdr 12 1l;
  Bytes.set_int32_be hdr 16 1l;
  Bytes.blit payload 0 hdr 20 n;
  hdr

let expect_exn label f =
  try
    ignore (f ());
    Printf.printf "%s:UNEXPECTED_OK\n" label
  with
  | Failure _ -> Printf.printf "%s:FAIL\n" label
  | Invalid_argument _ -> Printf.printf "%s:INV\n" label
  | End_of_file -> Printf.printf "%s:EOF\n" label

let () =
  (* 1. Partial cycle in malformed stream: tuple(ref self, <invalid code 0x10>) *)
  let partial_cyc =
    stream_of_bytes (Bytes.of_string "\xa0\x90\x04\x01\x10")
  in
  expect_exn "partial_cyc" (fun () -> Marshal.from_bytes partial_cyc 0);

  (* 2. Complete root self-cycle *)
  let complete_cyc = stream_of_bytes (Bytes.of_string "\x90\x04\x01") in
  let v : Obj.t = Marshal.from_bytes complete_cyc 0 in
  Printf.printf "complete_cyc:%b\n" (Obj.field v 0 == v);

  (* 3. Truncation and mutation fuzz on (42, "aaaa...a") *)
  let payload = (42, String.make 50 'a') in
  let good = Marshal.to_bytes payload [] in
  let n = Bytes.length good in
  let trunc_ok = ref true in
  for i = 0 to n - 1 do
    let p = Bytes.sub good 0 i in
    (try
       ignore (Marshal.from_bytes p 0);
       trunc_ok := false
     with Failure _ | Invalid_argument _ | End_of_file -> ())
  done;
  let mut_clean = ref true in
  for i = 20 to n - 1 do
    let byte = ref 0 in
    while !byte < 256 do
      let p = Bytes.copy good in
      Bytes.set p i (Char.chr !byte);
      (try ignore (Marshal.from_bytes p 0)
       with Failure _ | Invalid_argument _ | End_of_file -> ());
      byte := !byte + 17
    done
  done;
  Printf.printf "trunc:%b mut:%b\n" !trunc_ok !mut_clean;

  (* 4. Marshal.to_buffer bounds *)
  let buf = Bytes.make 8 'A' in
  expect_exn "tobuf_neg_off" (fun () -> Marshal.to_buffer buf (-1) 4 42 []);
  expect_exn "tobuf_neg_len" (fun () -> Marshal.to_buffer buf 0 (-1) 42 []);
  expect_exn "tobuf_oob" (fun () -> Marshal.to_buffer buf 6 4 42 []);
  expect_exn "tobuf_over" (fun () -> Marshal.to_buffer buf 0 4 42 []);

  (* 5. Truncated channel payload on a file channel must raise Failure cleanly *)
  let path = Filename.temp_file "ocamlcc_marshal_trunc_" ".bin" in
  let oc = open_out_bin path in
  output_string oc "\x84\x95\xa6\xbe\x00\x00\x10\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\x40";
  close_out oc;
  let ic = open_in_bin path in
  expect_exn "chan_trunc" (fun () -> Marshal.from_channel ic);
  close_in ic;
  Sys.remove path;

  (* 6. Malformed compressed header 0x8495a6bd *)
  let bad_comp = Bytes.of_string "\x84\x95\xa6\xbd\x4a\x01\x01\x01\x01\x01" in
  expect_exn "comp_bad_topbits" (fun () -> Marshal.from_bytes bad_comp 0);
  Bytes.set bad_comp 4 '\009';
  expect_exn "comp_bad_hlen" (fun () -> Marshal.from_bytes bad_comp 0);

  (* 7. Bad bigarray custom descriptor *)
  let bad_ba =
    Bytes.of_string
      "\x84\x95\xa6\xbe\x00\x00\x00\x18\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x01\
       \x12_bigarray\x00\x00\x00\x00\x01\x00\x00\x02\x00\x00\x00\x00\x00"
  in
  expect_exn "bad_ba" (fun () -> Marshal.from_bytes bad_ba 0);

  (* 8. No_sharing (DAG) / Closures / Compat_32 / data_size / total_size *)
  expect_exn "clos" (fun () -> Marshal.to_bytes (fun x -> x + 1) []);
  let shared = String.make 16 'k' in
  let b_share = Marshal.to_bytes (shared, shared) [] in
  let b_noshare = Marshal.to_bytes (shared, shared) [ Marshal.No_sharing ] in
  Printf.printf "noshare_dag:%b\n" (Bytes.length b_noshare > Bytes.length b_share);
  expect_exn "compat32" (fun () ->
      Marshal.to_bytes (Int64.to_int 0x100000000L) [ Marshal.Compat_32 ]);
  Printf.printf "sizes:%b\n"
    (Marshal.total_size good 0 = n && Marshal.data_size good 0 = n - 16)
