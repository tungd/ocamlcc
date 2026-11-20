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
