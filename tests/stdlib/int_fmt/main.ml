let check_fail label f =
  try
    ignore (f ());
    Printf.printf "%s:UNEXPECTED_OK\n" label
  with Failure msg -> Printf.printf "%s:FAIL(%s)\n" label msg

let () =
  (* Format parity *)
  Printf.printf "int:%s|%s|%s|%s|%s|%s|%s\n"
    (Printf.sprintf "%+4i" 42)
    (Printf.sprintf "%-6d" 42)
    (Printf.sprintf "%05d" (-42))
    (Printf.sprintf "%.4d" 7)
    (Printf.sprintf "%.0d" 0)
    (Printf.sprintf "%#x" 255)
    (Printf.sprintf "%#o" 42);
  Printf.printf "i32:%s|%s|%s|%s\n"
    (Printf.sprintf "%ld" (-1l))
    (Printf.sprintf "%lu" (-1l))
    (Printf.sprintf "%lx" Int32.min_int)
    (Printf.sprintf "%#lX" Int32.max_int);
  Printf.printf "i64:%s|%s|%s|%s\n"
    (Printf.sprintf "%#LX" (-1L))
    (Printf.sprintf "%Ld" Int64.min_int)
    (Printf.sprintf "%Lu" (-1L))
    (Printf.sprintf "%#.4Lo" 42L);
  Printf.printf "nat:%s|%s|%s\n"
    (Printf.sprintf "%#.4no" 42n)
    (Printf.sprintf "%nd" Nativeint.min_int)
    (Printf.sprintf "%nu" (-1n));

  (* Parse parity: int *)
  let int_ok =
    [ "0x30"; "-0x30"; "+0x30"; "-0o77"; "-0b1010"; "-0u10";
      "1_000_000"; "0x3fffffffffffffff"; "-0x3fffffffffffffff";
      "0x4000000000000000"; "-0x4000000000000000";
      "0x7fffffffffffffff"; "-0x7fffffffffffffff"; "-0x4000000000000001";
      string_of_int max_int; string_of_int min_int ]
  in
  List.iter (fun s -> Printf.printf "p_int(%s)=%d\n" s (int_of_string s)) int_ok;
  List.iter
    (fun (lbl, s) -> check_fail ("p_int_bad:" ^ lbl) (fun () -> int_of_string s))
    [ ("empty", ""); ("minus", "-"); ("plus", "+"); ("under", "_1");
      ("hex0", "0x"); ("hex8", "0x8000000000000000");
      ("mhex8", "-0x8000000000000000"); ("ovr", "4611686018427387904");
      ("movr", "-4611686018427387905"); ("badch", "12a"); ("nul", "1\0002") ];

  (* Parse parity: int32 *)
  let i32_ok =
    [ "0"; "-1"; "2147483647"; "-2147483648"; "0xffffffff"; "-0x80000000";
      "0u4294967295"; "0o37777777777"; "0b11111111" ]
  in
  List.iter (fun s -> Printf.printf "p_i32(%s)=%ld\n" s (Int32.of_string s)) i32_ok;
  List.iter
    (fun s -> check_fail ("p_i32_bad:" ^ s) (fun () -> Int32.of_string s))
    [ ""; "2147483648"; "-2147483649"; "0x100000000"; "0u4294967296" ];

  (* Parse parity: int64 *)
  let i64_ok =
    [ "0"; "-1"; "9223372036854775807"; "-9223372036854775808";
      "0xffffffffffffffff"; "0u18446744073709551615"; "-0x8000000000000000" ]
  in
  List.iter (fun s -> Printf.printf "p_i64(%s)=%Ld\n" s (Int64.of_string s)) i64_ok;
  List.iter
    (fun s -> check_fail ("p_i64_bad:" ^ s) (fun () -> Int64.of_string s))
    [ ""; "9223372036854775808"; "-9223372036854775809"; "0x10000000000000000";
      "0u18446744073709551616" ];

  (* Scanf integration *)
  Scanf.sscanf "42 -7 ff 123456789012" "%d %ld %nx %Ld" (fun a b c d ->
      Printf.printf "scanf:%d|%ld|%nd|%Ld\n" a b c d);
  (* Int to_string + Nativeint integration *)
  Printf.printf "int_mod:%s|%d|%nd\n" (Int.to_string (-99))
    (Option.get (int_of_string_opt "0x2a")) (Nativeint.of_string "-0x2a")
