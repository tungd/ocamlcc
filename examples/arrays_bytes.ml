let classify_word s =
  match s with
  | "" -> 0
  | "alpha" -> 1
  | "beta" -> 2
  | "gamma" -> 3
  | _ -> 99

let () =
  let s = "hello" in
  print_int (String.length s);
  print_endline "";
  print_int (Char.code (String.get s 1));
  print_endline "";
  print_int (classify_word "beta" + classify_word "gamma" + classify_word "" + classify_word "nope");
  print_endline "";

  let b = Bytes.create 5 in
  Bytes.set b 0 'O';
  Bytes.set b 1 'K';
  Bytes.set b 2 '!';
  Bytes.set b 3 '\n';
  Bytes.unsafe_set b 4 '\000';
  print_int (Bytes.length b);
  print_endline "";
  print_int (Char.code (Bytes.get b 1));
  print_endline "";

  let arr = [| 10; 20; 30 |] in
  print_int (Array.length arr);
  print_endline "";
  arr.(1) <- arr.(0) + arr.(2);
  print_int arr.(1);
  print_endline "";

  let a2 = Array.make 4 7 in
  a2.(2) <- 10;
  print_int (a2.(0) + a2.(1) + a2.(2) + a2.(3));
  print_endline "";

  let empty = [||] in
  print_int (Array.length empty);
  print_endline ""
