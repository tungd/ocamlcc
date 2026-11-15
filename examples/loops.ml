type counter = { mutable value : int; step : int }

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
  print_endline ""
