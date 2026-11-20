let temp_file name =
  Filename.concat (Filename.get_temp_dir_name ()) name

let hex_of_string s =
  let b = Buffer.create (String.length s * 2) in
  String.iter (fun c -> Buffer.add_string b (Printf.sprintf "%02x" (Char.code c))) s;
  Buffer.contents b

let () =
  let path = temp_file "ocamlcc_test_channels_main.dat" in
  (try Sys.remove path with Sys_error _ -> ());

  (* 1. Buffered writes, flush, pos_out, seek_out, out_channel_length, binary ints *)
  let oc = open_out_bin path in
  Printf.printf "init_pos_out=%d is_buf=%b bin=%b tty=%b\n"
    (pos_out oc) (Out_channel.is_buffered oc) (Out_channel.is_binary_mode oc)
    (Out_channel.isatty oc);
  output_string oc "hello";
  output_char oc ',';
  output_byte oc (Char.code ' ');
  let b = Bytes.of_string "world!!" in
  output oc b 0 5;
  output_substring oc "__!??" 2 1;
  output_char oc '\n';
  Printf.printf "after_line1_pos=%d\n" (pos_out oc);
  output_binary_int oc 0x12345678;
  output_binary_int oc (-0x12345678);
  output_binary_int oc 0;
  output_binary_int oc (-1);
  (* Write > 4096 bytes to span buffer boundaries *)
  let big = String.init 5000 (fun i -> Char.chr (65 + (i mod 26))) in
  output_string oc big;
  output_char oc '\n';
  let end_pos = pos_out oc in
  seek_out oc 0;
  output_string oc "HELLO";
  seek_out oc end_pos;
  flush oc;
  Printf.printf "end_pos=%d len=%d lpos=%Ld llen=%Ld\n"
    (pos_out oc) (out_channel_length oc)
    (LargeFile.pos_out oc) (LargeFile.out_channel_length oc);
  close_out oc;

  (* 2. Reading back with mixed input_char, input_line, input_binary_int, seek_in, pos_in *)
  let ic = open_in_bin path in
  Printf.printf "in_bin=%b in_tty=%b in_len=%d llen=%Ld\n"
    (In_channel.is_binary_mode ic) (In_channel.isatty ic)
    (in_channel_length ic) (LargeFile.in_channel_length ic);
  let c0 = input_char ic in
  let line1_rest = input_line ic in
  let p_after_line1 = pos_in ic in
  let i1 = input_binary_int ic in
  let i2 = input_binary_int ic in
  let i3 = input_binary_int ic in
  let i4 = input_binary_int ic in
  let long_line = input_line ic in
  Printf.printf "c0=%c rest=%s p1=%d ints=%08x,%08x,%d,%d long_len=%d first5=%s last5=%s\n"
    c0 line1_rest p_after_line1
    (i1 land 0xffffffff) (i2 land 0xffffffff) i3 i4
    (String.length long_line)
    (String.sub long_line 0 5)
    (String.sub long_line (String.length long_line - 5) 5);
  (* EOF behavior *)
  let eof_char = try ignore (input_char ic); false with End_of_file -> true in
  let eof_byte = try ignore (input_byte ic); false with End_of_file -> true in
  let eof_line = try ignore (input_line ic); false with End_of_file -> true in
  let eof_int = try ignore (input_binary_int ic); false with End_of_file -> true in
  let rbuf = Bytes.make 4 'z' in
  let eof_inp = input ic rbuf 0 4 in
  Printf.printf "eof=%b,%b,%b,%b,%d\n" eof_char eof_byte eof_line eof_int eof_inp;
  (* Seek back and test pos_in, seek_in, LargeFile.seek_in, really_input_string *)
  seek_in ic 6;
  let p6 = pos_in ic in
  let next5 = really_input_string ic 5 in
  let p11 = pos_in ic in
  Printf.printf "after_seek6_pos=%d next5=%s after_read5_pos=%d\n" p6 next5 p11;
  LargeFile.seek_in ic 0L;
  let r5 = really_input_string ic 5 in
  LargeFile.seek_in ic (Int64.sub (LargeFile.in_channel_length ic) 3L);
  let tail_eof = try ignore (really_input_string ic 10); false with End_of_file -> true in
  Printf.printf "seek0=%s lpos=%Ld tail_eof=%b\n" r5 (LargeFile.pos_in ic) tail_eof;
  close_in ic;
  close_in_noerr ic;

  (* 3. Partial line without trailing newline + CR in binary/text mode + input_lines / input_all *)
  let path2 = temp_file "ocamlcc_test_channels_lines.dat" in
  Out_channel.with_open_bin path2 (fun oc2 ->
    Out_channel.set_buffered oc2 false;
    Printf.printf "unbuffered=%b\n" (not (Out_channel.is_buffered oc2));
    output_string oc2 "alpha\r\nbeta\ngamma");
  In_channel.with_open_bin path2 (fun ic2 ->
    let lines = In_channel.input_lines ic2 in
    seek_in ic2 0;
    let all = In_channel.input_all ic2 in
    Printf.printf "lines=%d:[%s] all=%s\n"
      (List.length lines)
      (String.concat "|" (List.map hex_of_string lines))
      (hex_of_string all));

  (* 4. OOB Invalid_argument & closed channel error behavior *)
  let dummy_b = Bytes.make 4 'a' in
  let oob_out = try Out_channel.with_open_bin path2 (fun o -> output o dummy_b 2 4); false with Invalid_argument _ -> true in
  let oob_sub = try Out_channel.with_open_bin path2 (fun o -> output_substring o "abc" (-1) 2); false with Invalid_argument _ -> true in
  let oob_in = try In_channel.with_open_bin path2 (fun i -> ignore (input i dummy_b 3 2)); false with Invalid_argument _ -> true in
  let oob_rin = try In_channel.with_open_bin path2 (fun i -> really_input i dummy_b (-1) 1); false with Invalid_argument _ -> true in
  Printf.printf "oob=%b,%b,%b,%b\n" oob_out oob_sub oob_in oob_rin;

  let closed_ic = open_in_bin path2 in
  close_in closed_ic;
  let closed_in_err = try ignore (input_char closed_ic); false with Sys_error _ -> true in
  let closed_oc = open_out_bin path2 in
  close_out closed_oc;
  let closed_out_err = try output_char closed_oc 'x'; false with Sys_error _ -> true in
  let closed_flush_err = try flush closed_oc; false with Sys_error _ -> true in
  Printf.printf "closed_err=%b,%b,%b\n" closed_in_err closed_out_err closed_flush_err;

  (* 5. Bigarray channel I/O + subrange + bounds *)
  let path3 = temp_file "ocamlcc_test_channels_ba.dat" in
  let ba = Bigarray.Array1.create Bigarray.Char Bigarray.c_layout 8 in
  let src = "helloBA!" in
  for i = 0 to 7 do Bigarray.Array1.set ba i src.[i] done;
  let ba2 = Bigarray.Array1.create Bigarray.Char Bigarray.c_layout 8 in
  let ba_oob_out =
    try Out_channel.with_open_bin path3 (fun oc3 -> Out_channel.output_bigarray oc3 ba 7 4); false
    with Invalid_argument _ -> true
  in
  Out_channel.with_open_bin path3 (fun oc3 ->
    Out_channel.output_bigarray oc3 ba 0 8;
    Out_channel.output_bigarray oc3 ba 2 3);
  let ba_oob_in =
    try In_channel.with_open_bin path3 (fun ic3 -> ignore (In_channel.input_bigarray ic3 ba2 0 9)); false
    with Invalid_argument _ -> true
  in
  In_channel.with_open_bin path3 (fun ic3 ->
    let n1 = In_channel.input_bigarray ic3 ba2 0 8 in
    let got1 = String.init n1 (fun i -> Bigarray.Array1.get ba2 i) in
    let n2 = In_channel.input_bigarray ic3 ba2 0 8 in
    let got2 = String.init n2 (fun i -> Bigarray.Array1.get ba2 i) in
    let n3 = In_channel.input_bigarray ic3 ba2 0 8 in
    Printf.printf "ba=%d:%s,%d:%s,%d oob=%b,%b\n" n1 got1 n2 got2 n3 ba_oob_out ba_oob_in);

  (* 6. flush_all on live unclosed out_channel + Marshal round-trip via channels *)
  let path4 = temp_file "ocamlcc_test_channels_marshal.dat" in
  let oc4 = open_out_bin path4 in
  output_string oc4 "preflush:\n";
  flush_all ();
  let ic4 = open_in_bin path4 in
  Printf.printf "flushed=%s\n" (input_line ic4);
  close_in ic4;
  close_out oc4;

  Out_channel.with_open_bin path4 (fun oc5 ->
    Marshal.to_channel oc5 ("msg", [1; 2; 3; 4], (42, true)) []);
  In_channel.with_open_bin path4 (fun ic5 ->
    let (s, xs, (k, b)) : string * int list * (int * bool) = Marshal.from_channel ic5 in
    Printf.printf "marshal=%s:%d:%d:%b\n"
      s (List.fold_left ( + ) 0 xs) k b);

  (try Sys.remove path with Sys_error _ -> ());
  (try Sys.remove path2 with Sys_error _ -> ());
  (try Sys.remove path3 with Sys_error _ -> ());
  (try Sys.remove path4 with Sys_error _ -> ())
