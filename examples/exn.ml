external arc_live : unit -> int = "ocamlcc_arc_live"

exception Empty
exception Boom of int * (int * int)

type tree =
  | Leaf of int
  | Node of tree * int * tree

let rec tree_map f t =
  match t with
  | Leaf x -> Leaf (f x)
  | Node (l, v, r) -> Node (tree_map f l, f v, tree_map f r)

let rec deep_raise n acc =
  let local_pair = (n, acc) in
  let local_closure x = x + fst local_pair in
  if n <= 0 then raise (Boom (local_closure 5, local_pair))
  else
    let _res = deep_raise (n - 1) (acc + n) in
    (999, 888)

let test_nested_unwind () =
  let outer_kept = (100, 200) in
  try
    let p = (1, 2) in
    let _ =
      try
        let q = (3, 4) in
        ignore (fst p + snd q);
        deep_raise 5 0
      with Empty -> (0, 0)
    in
    0
  with Boom (v, pr) -> v + fst pr + snd pr + fst outer_kept + snd outer_kept

let test_tree_reuse_unwind () =
  let t = Node (Node (Leaf 1, 2, Leaf 3), 4, Node (Leaf 5, 6, Leaf 7)) in
  try
    let _t2 =
      tree_map (fun x -> if x = 6 then raise Empty else x + 10) t
    in
    1
  with Empty -> 42

let test_mut_loop_unwind () =
  let xs = [ (1, 2); (3, 4); (5, 6) ] in
  let acc = ref (0, 0) in
  try
    let i = ref 0 in
    while !i < 10 do
      let hd = match xs with (x, _) :: _ -> x | [] -> 0 in
      acc := (!i, hd);
      if !i = 3 then raise Empty;
      i := !i + 1
    done;
    0
  with Empty -> fst !acc + snd !acc

let test_normal_try () =
  let w = (10, 20) in
  try
    let q = (30, 40) in
    fst q + snd q + fst w
  with Empty -> snd w

let raise_empty () = raise Empty

let test_join_direct_borrow n =
  let x = ref n in
  let y =
    try raise Empty
    with Empty ->
      let junk = ref (n + 100) in
      !x + !junk
  in
  !x + y

let test_join_call_borrow n =
  let x = ref n in
  let y =
    try raise_empty ()
    with Empty ->
      let junk = ref (n + 100) in
      !x + !junk
  in
  !x + y

let test_join_cont_only_borrow n =
  let x = ref n in
  let y =
    try raise Empty
    with Empty ->
      let junk = ref (n + 100) in
      !junk
  in
  !x + y

let test_join_nested_reraise n =
  let x = ref n in
  try
    let y = try raise Empty with Empty -> raise (Boom (10, (1, 2))) in
    !x + y
  with Boom (a, _) ->
    let junk = ref (n + 100) in
    !x + a + !junk

let make_mul a =
  let box = (a, a + 1) in
  fun b -> fst box * snd box + b

let over_raise1 x =
  let pair = (x, x + 1) in
  if x = 0 then raise Empty
  else fun r -> fst pair + !r

let over_raise2 x =
  let pair = (x, x + 1) in
  if x < 0 then raise Empty
  else fun a b ->
    if fst pair > 0 then raise Empty
    else !a + !b

let test_overapp_no_leak () =
  let total = ref 0 in
  for i = 1 to 20 do
    total := !total + make_mul i (i + 2)
  done;
  !total

let test_overapp_raise1 () =
  let r = ref 77 in
  try over_raise1 0 r
  with Empty -> !r

let test_overapp_raise2 () =
  let r = ref 88 in
  let r2 = ref 9 in
  try over_raise2 10 r r2
  with Empty -> !r + !r2

let test_while_cond_raise () =
  let a =
    try
      while raise Empty do
        ()
      done;
      0
    with Empty -> 77
  in
  let keep = ref 10 in
  let b =
    try
      while
        let c = ref 5 in
        if !c = 5 then raise Empty else true
      do
        ()
      done;
      0
    with Empty -> !keep + 5
  in
  let c =
    try
      let outer = ref 30 in
      while
        let inner = ref 40 in
        !outer + !inner > 0 && raise Empty
      do
        ()
      done;
      0
    with Empty -> 88
  in
  a + b + c

let out v =
  print_int v;
  print_endline ""

let () =
  let b0 = arc_live () in
  let r1 = test_nested_unwind () in
  let l1 = arc_live () - b0 in
  let r2 = test_tree_reuse_unwind () in
  let l2 = arc_live () - b0 in
  let r3 = test_mut_loop_unwind () in
  let l3 = arc_live () - b0 in
  let r4 = test_normal_try () in
  let l4 = arc_live () - b0 in
  let r5 = test_join_direct_borrow 42 in
  let l5 = arc_live () - b0 in
  let r6 = test_join_call_borrow 42 in
  let l6 = arc_live () - b0 in
  let r7 = test_join_cont_only_borrow 42 in
  let l7 = arc_live () - b0 in
  let r8 = test_join_nested_reraise 42 in
  let l8 = arc_live () - b0 in
  let r9 = test_overapp_no_leak () in
  let l9 = arc_live () - b0 in
  let r10 = test_overapp_raise1 () in
  let l10 = arc_live () - b0 in
  let r11 = test_overapp_raise2 () in
  let l11 = arc_live () - b0 in
  let r12 = test_while_cond_raise () in
  let l12 = arc_live () - b0 in
  out r1; out l1; out r2; out l2;
  out r3; out l3; out r4; out l4;
  out r5; out l5; out r6; out l6;
  out r7; out l7; out r8; out l8;
  out r9; out l9; out r10; out l10;
  out r11; out l11;
  out r12; out l12
