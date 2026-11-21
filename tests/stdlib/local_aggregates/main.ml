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

let[@inline never] mark trace event = trace := !trace * 10 + event

let[@inline] make_inline_pair trace n =
  mark trace 2;
  let payload = Bytes.make n 'a' in
  payload, n + 1

let from_inline trace n =
  let pair = make_inline_pair trace (mark trace 1; n) in
  mark trace 3;
  Bytes.length (fst pair) + snd pair

let[@inline] make_inline_ref trace fail n =
  mark trace 1;
  if fail then raise Exit;
  ref (Bytes.make n 'a')

let use_inline_ref trace fail n =
  try
    let cell = make_inline_ref trace fail n in
    mark trace 2;
    cell := Bytes.extend !cell 0 1;
    Bytes.length !cell
  with Exit -> 0

type row = { a : bytes; b : int; c : bytes; d : int }

let wide_join counter n alternative =
  let row =
    if alternative then { a = make counter n; b = 1; c = make counter 2; d = 3 }
    else { a = make counter 4; b = 5; c = make counter n; d = 6 }
  in
  Bytes.length row.a + row.b + row.d

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
  let trace = ref 0 in
  assert (from_inline trace 4 = 9 && !trace = 123);
  trace := 0;
  assert (use_inline_ref trace false 4 = 5 && !trace = 12);
  trace := 0;
  assert (use_inline_ref trace true 4 = 0 && !trace = 1);
  assert (wide_join counter 7 true = 11 && !counter = 15);
  assert (wide_join counter 7 false = 15 && !counter = 17);
  print_endline "local aggregates: ok"
