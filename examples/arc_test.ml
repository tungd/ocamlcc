external arc_live : unit -> int = "ocamlcc_arc_live"
external arc_reuse : unit -> int = "ocamlcc_arc_reuse"
external arc_slab_count : unit -> int = "ocamlcc_arc_slab_count"

type tree =
  | Empty
  | Node of tree * int * tree

let rec build_list n acc =
  if n <= 0 then acc else build_list (n - 1) (n :: acc)

let rec sum_list acc xs =
  match xs with
  | [] -> acc
  | x :: tl -> sum_list (acc + x) tl

let rec list_map f xs =
  match xs with
  | [] -> []
  | x :: tl -> f x :: list_map f tl

let rec list_filter p xs =
  match xs with
  | [] -> []
  | x :: tl ->
      if p x then x :: list_filter p tl else list_filter p tl

let rec build_tree d v =
  if d <= 0 then Empty
  else Node (build_tree (d - 1) (v * 2), v, build_tree (d - 1) (v * 2 + 1))

let rec tree_map f t =
  match t with
  | Empty -> Empty
  | Node (l, v, r) -> Node (tree_map f l, f v, tree_map f r)

let rec sum_tree t =
  match t with
  | Empty -> 0
  | Node (l, v, r) -> sum_tree l + v + sum_tree r

let test_deep_list () =
  let xs = build_list 100000 [] in
  sum_list 0 xs

let test_tree_reuse () =
  let t = build_tree 10 1 in
  let t2 = tree_map (fun x -> x + 1) t in
  sum_tree t2

let test_shared_list () =
  let xs = build_list 100 [] in
  let ys = list_map (fun x -> x * 2) xs in
  let zs = list_filter (fun x -> x mod 2 = 0) ys in
  sum_list 0 xs + sum_list 0 zs

let test_closures_and_pap () =
  let pair = (10, 20) in
  let add3 a b c = fst pair + snd pair + a + b + c in
  let p1 = add3 1 in
  let p2 = p1 2 in
  p2 3 + p1 4 5

let test_mut_arrays_refs () =
  let r = ref (10, 20) in
  r := (30, 40);
  let arr = Array.make 4 (1, 2) in
  for i = 0 to 3 do
    arr.(i) <- (i, i * 10)
  done;
  let acc = ref (fst !r + snd !r) in
  let k = ref 0 in
  while !k < 4 do
    let p = arr.(!k) in
    acc := !acc + fst p + snd p;
    k := !k + 1
  done;
  let b = Bytes.create 5 in
  Bytes.set b 0 'A';
  !acc + Char.code (Bytes.get b 0)

let test_pattern_join x y =
  match (x, y) with
  | Some a, Some b -> fst a + snd b
  | Some a, None -> fst a
  | None, Some b -> snd b
  | None, None -> 0

let () =
  print_int (arc_live ());
  print_endline "";
  print_int (test_deep_list ());
  print_endline "";
  print_int (arc_live ());
  print_endline "";
  let r0 = arc_reuse () in
  let s_tree = test_tree_reuse () in
  let r1 = arc_reuse () in
  print_int s_tree;
  print_endline "";
  print_int (if r1 > r0 then 1 else 0);
  print_endline "";
  print_int (arc_live ());
  print_endline "";
  print_int (test_shared_list ());
  print_endline "";
  print_int (arc_live ());
  print_endline "";
  print_int (test_closures_and_pap ());
  print_endline "";
  print_int (arc_live ());
  print_endline "";
  print_int (test_mut_arrays_refs ());
  print_endline "";
  print_int (arc_live ());
  print_endline "";
  print_int
    (test_pattern_join (Some (7, 8)) (Some (9, 10))
    + test_pattern_join (Some (3, 4)) None
    + test_pattern_join None None);
  print_endline "";
  print_int (arc_live ());
  print_endline "";
  print_int (if arc_slab_count () <= 4 then 1 else 0);
  print_endline ""
