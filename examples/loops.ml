type counter = { mutable value : int; step : int }

exception Loop_limit

let () =
  let r = ref 10 in
  incr r;
  r := !r + 4;
  print_int !r;
  print_endline "";

  let c = { value = 0; step = 3 } in
  for i = 1 to 4 do
    c.value <- c.value + i * c.step
  done;
  print_int c.value;
  print_endline "";

  let sum = ref 0 in
  for i = 5 downto 1 do
    sum := !sum + i
  done;
  while !sum > 3 do
    sum := !sum - 4
  done;
  print_int !sum;
  print_endline "";

  let a = 0b10110 in
  let b = 0b01101 in
  print_int ((a land b) + (a lor b) + (a lxor b) + (1 lsl 4) + (32 asr 2) + ((-1) lsr 60));
  print_endline "";

  let short_circuit =
    let hit = ref 0 in
    let bump () =
      incr hit;
      true
    in
    let _ = false && bump () in
    let _ = true || bump () in
    let ok = true && not false && (17 mod 5 = 2) in
    if ok then !hit else -1
  in
  print_int short_circuit;
  print_endline "";

  print_int (compare 3 5 + compare 5 5 + compare 9 2);
  print_endline "";

  let mx = (-1) lsr 1 in
  let mn = mx + 1 in
  let count_upto a b =
    let n = ref 0 in
    let last = ref 0 in
    (try
       for i = a to b do
         incr n;
         last := i;
         if !n >= 5 then raise Loop_limit
       done
     with Loop_limit -> ());
    (!n, !last)
  in
  let count_downto a b =
    let n = ref 0 in
    let last = ref 0 in
    (try
       for i = a downto b do
         incr n;
         last := i;
         if !n >= 5 then raise Loop_limit
       done
     with Loop_limit -> ());
    (!n, !last)
  in
  let n1, l1 = count_upto mx mx in
  let n2, l2 = count_upto (mx - 1) mx in
  let n3, _ = count_upto mx mn in
  let n4, l4 = count_downto mn mn in
  let n5, l5 = count_downto (mn + 1) mn in
  let n6, _ = count_downto mn mx in
  print_int n1; print_endline "";
  print_int (if l1 = mx then 1 else 0); print_endline "";
  print_int n2; print_endline "";
  print_int (if l2 = mx then 1 else 0); print_endline "";
  print_int n3; print_endline "";
  print_int n4; print_endline "";
  print_int (if l4 = mn then 1 else 0); print_endline "";
  print_int n5; print_endline "";
  print_int (if l5 = mn then 1 else 0); print_endline "";
  print_int n6; print_endline "";

  let callbacks = Array.make 3 (fun () -> 0) in
  for i = 2 downto 0 do
    callbacks.(i) <- (fun () -> i + 1)
  done;
  print_int (callbacks.(0) () + 10 * callbacks.(1) () + 100 * callbacks.(2) ());
  print_endline ""
