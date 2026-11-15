type 'a weak_arr

external arc_live : unit -> int = "ocamlcc_arc_live"
external weak_create : int -> 'a weak_arr = "ocamlcc_weak_create"
external weak_length : 'a weak_arr -> int = "ocamlcc_weak_length"
external weak_set : 'a weak_arr -> int -> 'a option -> unit = "ocamlcc_weak_set"
external weak_get : 'a weak_arr -> int -> 'a option = "ocamlcc_weak_get"
external weak_check : 'a weak_arr -> int -> bool = "ocamlcc_weak_check"

type tree_node = {
  v : int;
  mutable child : tree_node option;
  parent : tree_node weak_arr;
}

let test_weak_basic x =
  let w = weak_create 2 in
  let p = (10, 20) in
  weak_set w 0 (Some p);
  weak_set w 1 (Some (x + 1, x + 2));
  let a =
    match weak_get w 0 with
    | Some q -> fst q + snd q
    | None -> -1
  in
  let dead_now = if weak_check w 1 then 1 else 0 in
  let alive_p = fst p + snd p in
  (weak_length w, a, dead_now, alive_p)

let test_cycle_break () =
  let w_obs = weak_create 1 in
  let build () =
    let root = { v = 100; child = None; parent = weak_create 1 } in
    let ch = { v = 23; child = None; parent = weak_create 1 } in
    weak_set ch.parent 0 (Some root);
    root.child <- Some ch;
    weak_set w_obs 0 (Some root);
    let back =
      match weak_get ch.parent 0 with
      | Some r -> r.v
      | None -> 0
    in
    let alive_in = if weak_check w_obs 0 then 1 else 0 in
    back + ch.v + alive_in + root.v
  in
  let s = build () in
  let alive_after = if weak_check w_obs 0 then 1 else 0 in
  (s, alive_after)

let test_weak_of_weak () =
  let outer = weak_create 1 in
  let reg () =
    let inner = weak_create 2 in
    weak_set outer 0 (Some inner);
    let alive_in = if weak_check outer 0 then 1 else 0 in
    alive_in + weak_length inner
  in
  let alive_and_len = reg () in
  let alive_after = if weak_check outer 0 then 1 else 0 in
  let got_none =
    match weak_get outer 0 with
    | Some _ -> 1
    | None -> 0
  in
  (alive_and_len, alive_after, got_none)

let () =
  let l, a, dead_now, alive_p = test_weak_basic 2 in
  let live1 = arc_live () in
  let s, alive_after = test_cycle_break () in
  let live2 = arc_live () in
  let win, wafter, wnone = test_weak_of_weak () in
  let live3 = arc_live () in
  print_int l;
  print_endline "";
  print_int a;
  print_endline "";
  print_int dead_now;
  print_endline "";
  print_int alive_p;
  print_endline "";
  print_int live1;
  print_endline "";
  print_int s;
  print_endline "";
  print_int alive_after;
  print_endline "";
  print_int live2;
  print_endline "";
  print_int win;
  print_endline "";
  print_int wafter;
  print_endline "";
  print_int wnone;
  print_endline "";
  print_int live3;
  print_endline ""
