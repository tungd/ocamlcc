let make counter n =
  incr counter;
  Bytes.make n 'a'

let[@inline never] total counter n =
  let tuple = (make counter n, make counter (n + 1)) in
  let alias = tuple in
  Bytes.length (fst alias) + Bytes.length (snd alias)

let[@inline never] take counter n =
  let option = Some (make counter n) in
  match option with Some b -> Bytes.length b | None -> assert false

let[@inline never] unused counter n =
  let tuple = (make counter n, make counter (n + 1)) in
  Bytes.length (snd tuple)

let[@inline never] capture counter n =
  let tuple = (make counter n, make counter (n + 1)) in
  fun () -> Bytes.length (fst tuple) + Bytes.length (snd tuple)

let () =
  let counter = ref 0 in
  assert (total counter 4 = 9 && !counter = 2);
  assert (take counter 4 = 4 && !counter = 3);
  assert (unused counter 4 = 5 && !counter = 5);
  let get = capture counter 4 in
  assert (get () = 9 && !counter = 7);
  print_endline "local aggregates: ok"
