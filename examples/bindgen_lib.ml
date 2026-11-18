type t = { mutable v : int }
type point = { x : float; y : float }
type user = { name : string; age : int }

exception Bad_arg of int

let create x = { v = x }
let get h = h.v

let add_pt a b = { x = a.x +. b.x; y = a.y +. b.y }

let greet u =
  if u.age >= 18 then "Hello, " ^ u.name
  else "Hi, " ^ u.name

let opt_inc = function
  | Some x -> Some (x + 1)
  | None -> None

let flip b = not b

let sum_i32_i64 a b = Int64.add (Int64.of_int32 a) b

let pair_sum (a, b) = a + b

let check_pos n =
  if n < 0 then raise (Bad_arg (0 - n))
  else n * 10

type labels = { switch : int; ocamlcc_switch : int; x' : int; x_ : int }
let echo_labels x = x
