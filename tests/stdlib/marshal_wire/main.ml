let emit value flags =
  let bytes = Marshal.to_string value flags in
  String.iter (fun c -> Printf.printf "%02x" (Char.code c)) bytes;
  print_newline ()
let () =
  List.iter (fun n -> emit n []) [min_int; -1073741825; -32769; -129; -1; 0; 63; 64; 127; 128; 32767; 32768; 1073741824; max_int];
  emit (Bytes.to_string (Bytes.of_string "a\000b")) [];
  emit (String.make 300 'z') [];
  emit [|1.; -0.; infinity; neg_infinity|] [];
  emit (123l, -456L, 789n, Nativeint.min_int) [];
  let shared = ref 42 in
  emit (shared, shared) [];
  emit (shared, shared) [Marshal.No_sharing];
  emit Bigarray.(Array2.init int64 fortran_layout 2 3 (fun i j -> Int64.of_int (10*i+j))) [];
  emit Bigarray.(Array1.of_array int c_layout [|min_int; max_int|]) [];
  emit Bigarray.(Array1.of_array complex64 c_layout [|{Complex.re = 1.25; im = -2.5}|]) []
