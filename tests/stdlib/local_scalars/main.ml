let[@inline never] update (array : float array) source destination =
  let x = array.(source) in
  let doubled = x *. 2. in
  array.(destination) <- doubled +. 1.

let[@inline never] float_result (x : float) =
  let intermediate = x +. 2. in
  intermediate *. 3.

let[@inline never] to_int x =
  let as_float = float_of_int x in
  let magnitude = abs_float (-.as_float *. 2.) in
  int_of_float magnitude

let[@inline never] lower (x : float) =
  let y = x +. 2. in y < 0.

let[@inline never] abs_zero (x : float) =
  let negated = -.x in
  1. /. abs_float negated

let[@inline never] arithmetic x divisor =
  let base = Int32.of_int x in
  let wrapped = Int32.add base 1l in
  let shifted = Int32.shift_left wrapped 1 in
  Int32.div shifted divisor

let[@inline never] remainder (x : int64) divisor =
  let negated = Int64.neg x in
  Int64.rem negated divisor

let out_of_bounds f =
  match f () with exception Invalid_argument _ -> true | _ -> false

let () =
  let array = [|1.5; 3.|] in
  update array 0 1;
  assert (array.(1) = 4.);
  assert (out_of_bounds (fun () -> update array 2 1));
  assert (out_of_bounds (fun () -> update array 1 (-1)));
  assert (array.(1) = 4.);
  assert (float_result 2. = 12. && to_int (-21) = 42);
  assert (lower (-3.) && not (lower nan) && abs_zero 0. = infinity);
  assert (arithmetic 20 2l = 21l);
  assert (arithmetic 2147483647 1l = 0l);
  assert (remainder Int64.min_int (-1L) = 0L);
  (match arithmetic 20 0l with exception Division_by_zero -> () | _ -> assert false);
  print_endline "local scalars: ok"

let rec float_loop n (acc : float) =
  if n <= 0 then acc else float_loop (n - 1) (acc +. 0.5)

let rec int64_loop n (acc : int64) =
  if n <= 0 then acc else int64_loop (n - 1) (Int64.add acc 2L)

let rec int32_loop n (acc : int32) =
  if n <= 0 then acc else int32_loop (n - 1) (Int32.add acc 2l)

let rec array_loop (a : float array) i (acc : float) =
  if i = 0 then acc
  else array_loop a (i - 1) (acc +. a.(i - 1))

let rec divide_loop n (acc : int64) =
  if n < 0 then acc
  else divide_loop (n - 1) (Int64.div acc (Int64.of_int n))

let () =
  let loop = Sys.opaque_identity float_loop in
  assert (loop 100_000 0.25 = 50_000.25);
  assert (loop 0 10.5 = 10.5);
  assert (int64_loop 33 (Int64.sub Int64.max_int 65L) = Int64.min_int);
  assert (int32_loop 33 (Int32.sub Int32.max_int 65l) = Int32.min_int);
  assert (array_loop [|1.; 2.; 3.|] 3 0.5 = 6.5);
  assert (out_of_bounds (fun () -> array_loop [|1.|] 2 0.));
  (match divide_loop 2 16L with exception Division_by_zero -> () | _ -> assert false);
  print_endline "numeric loops: ok"

let[@inline never] seed_float n = float_of_int n /. 2.

let rec carry n (acc : float) =
  if n = 0 then acc else carry (n - 1) acc

let () =
  let seed = seed_float 11 in
  assert (float_loop 0 seed == seed);
  assert (carry 10 seed == seed);
  print_endline "boxed seeds: ok"

let[@inline never] publish_then_return sink n =
  let rec loop n (acc : float) =
    if n = 0 then acc
    else
      let next = acc +. 0.5 in
      sink := Some next;
      loop (n - 1) next
  in
  loop n 1.25

let () =
  let sink = ref None in
  let result = publish_then_return sink 2 in
  assert (result = 2.25 && result == Option.get !sink);
  print_endline "boxed loop values: ok"
