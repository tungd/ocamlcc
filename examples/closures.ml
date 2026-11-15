let make_adder x = fun y -> x + y

let apply_twice f x = f (f x)

let inc x = x + 1

let add3 a b c = a + b + c

let add5 a b c d e = a + b + c + d + e

let id x = x

let rec map f xs =
  match xs with
  | [] -> []
  | x :: tl -> f x :: map f tl

let rec fold_left f acc xs =
  match xs with
  | [] -> acc
  | x :: tl -> fold_left f (f acc x) tl

let sum_above limit xs =
  let rec go acc ys =
    match ys with
    | [] -> acc
    | y :: tl -> go (if y > limit then acc + y else acc) tl
  in
  go 0 xs

let mutual_with_capture offset n =
  let rec even_k k = if k = 0 then offset else odd_k (k - 1)
  and odd_k k = if k = 0 then offset + 1 else even_k (k - 1) in
  even_k n

let () =
  let add5_clos = make_adder 5 in
  print_int (apply_twice add5_clos 10);
  print_endline "";
  print_int (apply_twice inc 10);
  print_endline "";
  let p1 = add3 10 in
  let p2 = p1 20 in
  print_int (p2 30);
  print_endline "";
  print_int (id (fun a -> fun b -> a + b) 3 4);
  print_endline "";
  print_int ((make_adder 100) 23);
  print_endline "";
  let f5 = id add5 in
  print_int (f5 1 2 3 4 5);
  print_endline "";
  let p5 = f5 10 20 in
  print_int (p5 30 40 50);
  print_endline "";
  let ys = map (fun x -> x * 2) [ 1; 2; 3; 4 ] in
  print_int (fold_left (fun acc x -> acc + x) 0 ys);
  print_endline "";
  print_int (sum_above 4 [ 1; 5; 2; 6; 4; 10 ]);
  print_endline "";
  print_int (mutual_with_capture 100 10000);
  print_endline "";
  print_int (mutual_with_capture 100 10001);
  print_endline ""
