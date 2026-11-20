let clamp lo hi x = Int.max lo (Stdlib.Int.min hi x)

let () =
  let left_calls = ref 0 and right_calls = ref 0 in
  let tick calls x = incr calls; x in
  let smaller = Int.min (tick left_calls max_int) (tick right_calls min_int) in
  let larger = Stdlib.Int.max min_int max_int in
  let partial = Int.max 4 in
  let module Int = struct let min x y = x + y end in
  Printf.printf "%b %b %d %d %d %d %d %d\n"
    (smaller = min_int) (larger = max_int) !left_calls !right_calls
    (clamp (-4) 5 20) (clamp 2 2 2) (partial 1) (Int.min 3 4)
