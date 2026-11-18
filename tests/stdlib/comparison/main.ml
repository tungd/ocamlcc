let predicates x y =
  Printf.printf "%b %b %b %b %b %b\n"
    (x = y) (x <> y) (x < y) (x <= y) (x > y) (x >= y)

let () =
  let xs = [nan] in
  predicates xs xs;
  predicates xs [0.];
  predicates [0.] xs;
  let a = [|nan|] in
  predicates a a;
  predicates [2] [3];
  Printf.printf "%d %d\n" (compare xs xs) (compare xs [0.])
