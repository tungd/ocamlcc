external arc_live : unit -> int = "ocamlcc_arc_live"
external arc_collect : unit -> int = "ocamlcc_arc_collect"

type ilist = Nil | Cons of int * ilist
type node = { v : int; mutable next : node }
type box = B of box array
type fbox = F of (int -> int)

let rec_list_sum () =
  let rec ones = Cons (1, ones)
  and ev = Cons (0, od)
  and od = Cons (2, ev) in
  let a = match ones with Cons (x, Cons (y, _)) -> x + y | _ -> -1 in
  let b = match ev with Cons (x, Cons (y, Cons (z, _))) -> x + y + z | _ -> -1 in
  a + b

let rec_record_test () =
  let rec a = { v = 10; next = b }
  and b = { v = 20; next = a } in
  a.next.v + b.next.v

let rec_array_box_test () =
  let rec bx = B [| bx |] in
  match bx with
  | B arr -> (match arr.(0) with B arr2 -> Array.length arr2)

let rec_closure_box_test () =
  let rec fb = F (fun x -> if x <= 0 then 0 else match fb with F g -> 1 + g (x - 1)) in
  match fb with F g -> g 5

let () =
  let base = arc_live () in
  let s1 = rec_list_sum () in
  let s2 = rec_record_test () in
  let s3 = rec_array_box_test () in
  let s4 = rec_closure_box_test () in
  let reclaimed = arc_collect () in
  let delta = arc_live () - base in
  Printf.printf "s=%d,%d,%d,%d coll=%d delta=%d\n" s1 s2 s3 s4
    (if reclaimed >= 4 then 1 else 0)
    delta
