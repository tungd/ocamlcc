type color = Red | Green | Blue

let classify n =
  match n with
  | 0 -> Red
  | 1 | 2 -> Green
  | _ -> Blue

let () =
  print_int (match classify 2 with Red -> 1 | Green -> 2 | Blue -> 3);
  print_int (match classify 0 with Red -> 1 | Green -> 2 | Blue -> 3);
  print_int (match classify 9 with Red -> 1 | Green -> 2 | Blue -> 3);
  print_endline ""
