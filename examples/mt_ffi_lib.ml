external arc_collect : unit -> int = "ocamlcc_arc_collect"

exception Mt_boom of int

type cyc_node = {
  mutable c_next : cyc_node option;
  c_val : int;
}

let cycle_iter seed =
  let a = { c_next = None; c_val = seed } in
  let b = { c_next = Some a; c_val = seed + 1 } in
  a.c_next <- Some b;
  let sum =
    match a.c_next with
    | Some n -> n.c_val + a.c_val
    | None -> 0
  in
  let _ = if seed mod 16 = 0 then arc_collect () else 0 in
  sum

let shared_fn x = (x * 3) + 1

let call_shared f x = f x

let work_iter seed =
  (* Allocate blocks, lists, closures, strings *)
  let rec build i acc =
    if i <= 0 then acc else build (i - 1) ((i + seed) :: acc)
  in
  let xs = build 8 [] in
  let sum_list = List.fold_left (fun a x -> a + x) 0 xs in
  let arr = Array.make 4 (seed + 1) in
  arr.(2) <- seed + 5;
  let sum_arr = arr.(0) + arr.(2) in
  (* Weak reference roundtrip — keep [box] alive across [Weak.get] *)
  let w = Weak.create 2 in
  let box = Some (seed + 10) in
  Weak.set w 0 (Some box);
  let wv =
    match Weak.get w 0 with
    | Some (Some v) -> v
    | _ -> 0
  in
  let bv = match box with Some b -> b | None -> 0 in
  (* Exception raise & catch per-thread *)
  let exn_v =
    try
      if seed >= 0 then raise (Mt_boom (seed + 7)) else 0
    with Mt_boom n -> n
  in
  (* Coroutine fiber per-thread *)
  let f =
    Fiber.create (fun v ->
        let y = Fiber.suspend (v + 1) in
        y + 2)
  in
  let r1 = Fiber.resume f seed in
  let r2 = Fiber.resume f (r1 + 3) in
  (* Scheduler fiber per-thread *)
  let acc = ref 0 in
  let _ =
    Fiber.spawn (fun () ->
        Fiber.yield ();
        acc := !acc + 11)
  in
  Fiber.run_all ();
  sum_list + sum_arr + wv + bv + exn_v + r2 + !acc

external atomic_get : 'a ref -> 'a = "%atomic_load"
external atomic_exchange : 'a ref -> 'a -> 'a = "%atomic_exchange"
external atomic_cas : 'a ref -> 'a -> 'a -> bool = "%atomic_cas"

let left = ref 11
let right = ref 12
let slot = ref left

let atomic_iter seed =
  let next = if seed land 1 = 0 then left else right in
  let seen = atomic_get slot in
  let old = atomic_exchange slot next in
  ignore (atomic_cas slot next seen);
  (!seen = 11 || !seen = 12) && (!old = 11 || !old = 12)
