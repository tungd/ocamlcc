type 'a weak_arr

external arc_live : unit -> int = "ocamlcc_arc_live"
external arc_collect : unit -> int = "ocamlcc_arc_collect"
external weak_create : int -> 'a weak_arr = "ocamlcc_weak_create"
external weak_set : 'a weak_arr -> int -> 'a option -> unit = "ocamlcc_weak_set"
external weak_check : 'a weak_arr -> int -> bool = "ocamlcc_weak_check"

type node = {
  id : int;
  payload : int * int;
  mutable next : node option;
}

let invoke f k = f k

let run_closure_cycle x =
  let captured = (x + 10, x + 20) in
  let rec even_k k = if k = 0 then fst captured else invoke odd_k (k - 1)
  and odd_k k = if k = 0 then snd captured else even_k (k - 1) in
  even_k 5

(* Both functions escape through the result. Each still works after its
   sibling has been dropped, and partial application keeps its capture alive. *)
let make_steps x =
  let captured = (x + 10, x + 20) in
  let rec even k =
    if k = 0 then fst captured else odd (k - 1) 0
  and odd k acc =
    if k = 0 then snd captured + acc else even (k - 1)
  in
  (even, even, odd)

let run_lifted_steps x =
  let even, alias, _ = make_steps x in
  let partial =
    let _, _, odd = make_steps (x + 1) in
    odd 0
  in
  if even == alias then even 50_000 + partial 7 else -1

let make_record_cycle a b =
  let n1 = { id = a; payload = (a + 1, a + 2); next = None } in
  let n2 = { id = b; payload = (b + 1, b + 2); next = None } in
  n1.next <- Some n2;
  n2.next <- Some n1;
  n1

let test_live_record_cycle w_obs =
  let n1 = make_record_cycle 10 20 in
  weak_set w_obs 0 (Some n1);
  let _ = arc_collect () in
  let alive_during = if weak_check w_obs 0 then 1 else 0 in
  let sum =
    match n1.next with
    | Some n2 -> n1.id + n2.id + fst n1.payload + snd n2.payload
    | None -> -1
  in
  (alive_during, sum)

let test_dropped_cycles () =
  let live0 = arc_live () in
  let w = weak_create 1 in
  let alive_during, sum = test_live_record_cycle w in
  let leaked = arc_live () - live0 in
  let freed = arc_collect () in
  let alive_after = if weak_check w 0 then 1 else 0 in
  let live_end = arc_live () - live0 in
  (alive_during, sum, (if leaked > 0 then 1 else 0), (if freed > 0 then 1 else 0), alive_after, live_end)

let make_wrapped_cycle () =
  let c = make_record_cycle 30 40 in
  (99, Some c)

let drop_parent_holding_cycle w =
  let box = make_wrapped_cycle () in
  let tag =
    match snd box with
    | Some c ->
        weak_set w 0 (Some c);
        fst box
    | None -> 0
  in
  tag

type ('a, 'b) coro

external fiber_create : ('a -> 'b) -> ('a, 'b) coro = "ocamlcc_fiber_create"
external fiber_resume : ('a, 'b) coro -> 'a -> 'b = "ocamlcc_fiber_resume"
external fiber_suspend : 'b -> 'a = "ocamlcc_fiber_suspend"

let test_parent_owning_cycle () =
  let live0 = arc_live () in
  let w = weak_create 1 in
  let tag = drop_parent_holding_cycle w in
  let freed = arc_collect () in
  let alive_after = if weak_check w 0 then 1 else 0 in
  let live_end = arc_live () - live0 in
  ((if tag = 99 then 1 else 0), (if freed > 0 then 1 else 0), alive_after, live_end)

(* Cycle through a suspended fiber's shadow stack: the option block is kept
   alive only by the fiber's shadow, and the fiber is kept alive only by the
   option's field. Trial deletion must treat the fiber as a candidate and
   traverse its shadow-stack values as owning edges. *)
let test_fiber_shadow_cycle () =
  let live0 = arc_live () in
  let w = weak_create 1 in
  let make_and_drop () =
    let holder = ref None in
    let c =
      fiber_create (fun seed ->
          let y1 = fiber_suspend (seed + 1) in
          (* read after the first resume returns: snap = Some c, and it
             stays live (in the fiber's shadow stack) across suspend #2 *)
          let snap = !holder in
          let y2 = fiber_suspend y1 in
          (match snap with Some _ -> 1 | None -> 0) + y2)
    in
    weak_set w 0 (Some c);
    let y1 = fiber_resume c 2 in
    holder := Some c;
    let y2 = fiber_resume c y1 in
    let alive_during = if weak_check w 0 then 1 else 0 in
    (y2, alive_during)
  in
  let y, alive_during = make_and_drop () in
  let freed = arc_collect () in
  let alive_after = if weak_check w 0 then 1 else 0 in
  let delta = arc_live () - live0 in
  (y, alive_during, (if freed > 0 then 1 else 0), alive_after, delta)

let () =
  let cval = run_closure_cycle 3 in
  let leaked_closures = arc_live () in
  let freed_closures = arc_collect () in
  let live_after_closures = arc_live () in
  let (alive_during, sum, had_leak, did_free, alive_after, delta_rec) =
    test_dropped_cycles ()
  in
  let (ptag, pfreed, palive, pdelta) = test_parent_owning_cycle () in
  let (fy, falive_during, ffreed, falive_after, fdelta) =
    test_fiber_shadow_cycle ()
  in
  let live_final = arc_live () in
  print_int cval;
  print_endline "";
  print_int (if leaked_closures > 0 then 1 else 0);
  print_endline "";
  print_int (if freed_closures >= 2 then 1 else 0);
  print_endline "";
  print_int live_after_closures;
  print_endline "";
  print_int alive_during;
  print_endline "";
  print_int sum;
  print_endline "";
  print_int had_leak;
  print_endline "";
  print_int did_free;
  print_endline "";
  print_int alive_after;
  print_endline "";
  print_int delta_rec;
  print_endline "";
  print_int ptag;
  print_endline "";
  print_int pfreed;
  print_endline "";
  print_int palive;
  print_endline "";
  print_int pdelta;
  print_endline "";
  print_int fy;
  print_endline "";
  print_int falive_during;
  print_endline "";
  print_int ffreed;
  print_endline "";
  print_int falive_after;
  print_endline "";
  print_int fdelta;
  print_endline "";
  print_int live_final;
  print_endline ""

let () =
  let live_before = arc_live () in
  let result = run_lifted_steps 3 in
  let live_delta = arc_live () - live_before in
  print_int result;
  print_endline "";
  print_int live_delta;
  print_endline ""
