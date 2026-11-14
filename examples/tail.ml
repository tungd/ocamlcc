(* Self tail-calls must lower to explicit QBE loops, not stack growth. *)
let rec sum_to acc n = if n = 0 then acc else sum_to (acc + n) (n - 1)

let () =
  print_int (sum_to 0 100000);
  print_endline ""
