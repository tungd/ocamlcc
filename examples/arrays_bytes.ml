let classify_word s =
  match s with
  | "" -> 0
  | "alpha" -> 1
  | "beta" -> 2
  | "gamma" -> 3
  | _ -> 99

let () =
  let s = "hello" in
  print_int (String.length s);
  print_endline "";
  print_int (Char.code (String.get s 1));
  print_endline "";
  print_int (classify_word "beta" + classify_word "gamma" + classify_word "" + classify_word "nope");
  print_endline "";

  let b = Bytes.create 5 in
  Bytes.set b 0 'O';
  Bytes.set b 1 'K';
  Bytes.set b 2 '!';
  Bytes.set b 3 '\n';
  Bytes.unsafe_set b 4 '\000';
  print_int (Bytes.length b);
  print_endline "";
  print_int (Char.code (Bytes.get b 1));
  print_endline "";

  let arr = [| 10; 20; 30 |] in
  print_int (Array.length arr);
  print_endline "";
  arr.(1) <- arr.(0) + arr.(2);
  print_int arr.(1);
  print_endline "";

  let a2 = Array.make 4 7 in
  a2.(2) <- 10;
  print_int (a2.(0) + a2.(1) + a2.(2) + a2.(3));
  print_endline "";

  let empty = [||] in
  print_int (Array.length empty);
  print_endline ""

let check_buffer_snapshots grow =
  let slot = ref (Bytes.create 1) in
  let current =
    if grow then begin
      let fresh = Bytes.create 2 in
      slot := fresh;
      fresh
    end else !slot
  in
  Bytes.unsafe_set current 0 'x';
  let previous = !slot in
  let replacement = Bytes.create 1 in
  Bytes.unsafe_set replacement 0 'z';
  slot := replacement;
  assert (Bytes.unsafe_get previous 0 = 'x');
  assert (Bytes.unsafe_get !slot 0 = 'z')

let () =
  check_buffer_snapshots false;
  check_buffer_snapshots true

type cursor = { row : int; col : int }
type state = { mutable cursor : cursor }

let check_cursor_snapshots state replacement =
  let row = state.cursor.row in
  let old = state.cursor in
  state.cursor <- replacement;
  assert (row = old.row && state.cursor.col = replacement.col)

let () =
  check_cursor_snapshots { cursor = { row = 1; col = 2 } } { row = 3; col = 4 }

external live_objects : unit -> int = "ocamlcc_arc_live"

let check_option_array () =
  let store (options : bytes option array) =
    let buffer = Bytes.create 2 in
    Bytes.unsafe_set buffer 1 'x';
    options.(0) <- Some buffer
  in
  let before = live_objects () in
  let check () =
    let options = Array.make 2 None in
    store options;
    match options.(0) with
    | Some buffer -> assert (Bytes.unsafe_get buffer 1 = 'x')
    | None -> assert false
  in
  check ();
  assert (live_objects () = before)

let () = check_option_array ()
