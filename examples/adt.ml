type tree =
  | Empty
  | Leaf of int
  | Node of tree * int * tree

type mixed =
  | A
  | B of int
  | C
  | D of int * int

let sum_pair (a, b) = a + b

let unwrap_or d opt =
  match opt with
  | None -> d
  | Some x -> x

let rec sum_list acc xs =
  match xs with
  | [] -> acc
  | x :: tl -> sum_list (acc + x) tl

let rec sum_tree t =
  match t with
  | Empty -> 0
  | Leaf x -> x
  | Node (l, x, r) -> sum_tree l + x + sum_tree r

let eval_mixed m =
  match m with
  | A -> 10
  | B x -> x + 1
  | C -> 20
  | D (x, y) -> x * y

let eval_with_wildcard m =
  match m with
  | B x | D (x, _) -> x
  | _ -> -1

let () =
  let const_list = [ 1; 2; 3; 4 ] in
  let dyn_list =
    let x = 5 in
    [ x; x + 1; x + 2 ]
  in
  let t = Node (Leaf 3, 4, Node (Empty, 5, Leaf 6)) in
  print_int (sum_pair (10, 20));
  print_endline "";
  print_int (unwrap_or 99 None);
  print_endline "";
  print_int (unwrap_or 99 (Some 42));
  print_endline "";
  print_int (sum_list 0 const_list);
  print_endline "";
  print_int (sum_list 0 dyn_list);
  print_endline "";
  print_int (sum_tree t);
  print_endline "";
  print_int (eval_mixed A + eval_mixed (B 4) + eval_mixed C + eval_mixed (D (3, 7)));
  print_endline "";
  print_int (eval_with_wildcard A + eval_with_wildcard (B 7) + eval_with_wildcard (D (8, 9)));
  print_endline ""
