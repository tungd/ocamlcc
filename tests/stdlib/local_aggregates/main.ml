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

let[@inline never] choose counter n alternative =
  let pair =
    if alternative then (make counter n, make counter (n + 1))
    else (make counter (n + 2), make counter (n + 3))
  in
  Bytes.length (fst pair) + Bytes.length (snd pair)

let[@inline never] choose_result counter n alternative =
  let result =
    if alternative then Ok (make counter n) else Ok (make counter (n + 3))
  in
  match result with Ok bytes -> Bytes.length bytes | Error _ -> assert false

let () =
  let counter = ref 0 in
  assert (total counter 4 = 9 && !counter = 2);
  assert (take counter 4 = 4 && !counter = 3);
  assert (unused counter 4 = 5 && !counter = 5);
  let get = capture counter 4 in
  assert (get () = 9 && !counter = 7);
  assert (choose counter 4 false = 13 && !counter = 9);
  assert (choose counter 4 true = 9 && !counter = 11);
  assert (choose_result counter 4 false = 7 && !counter = 12);
  assert (choose_result counter 4 true = 4 && !counter = 13);
  print_endline "local aggregates: ok"
