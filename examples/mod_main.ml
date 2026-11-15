let () =
  print_int (Mod_lib.square 7);
  print_endline "";
  print_int (Mod_lib.pair_sum (3, 4));
  print_endline "";
  let add5 = Mod_lib.make_adder 5 in
  print_int (add5 12);
  print_endline "";
  let box = Mod_lib.create 32 in
  print_int (Mod_lib.get box);
  print_endline "";
  (try print_int (Mod_lib.check (-7)) with Mod_lib.Lib_err n -> print_int n);
  print_endline "";
  print_int (Mod_lib.check 9);
  print_endline ""
