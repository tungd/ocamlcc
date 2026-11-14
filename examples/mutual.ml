(* Mutual tail recursion must not grow the stack: 100k ping-pong round
   trips through the two-function trampoline. *)
let rec even n = if n = 0 then 1 else odd (n - 1)
and odd n = if n = 0 then 0 else even (n - 1)

let () =
  print_int (even 100000);
  print_int (odd 100001);
  print_endline ""
