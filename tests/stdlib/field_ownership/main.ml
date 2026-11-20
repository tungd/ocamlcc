type slot = { mutable count : int; mutable data : bytes option }

let record_replace weak slot =
  let value = Bytes.make 8 'r' in
  Weak.set weak 0 (Some value);
  slot.data <- Some value;
  slot.count <- slot.count + 1;
  assert (Option.get slot.data == value);
  slot.data <- None

let array_replace weak (array : bytes option array) =
  let value = Bytes.make 8 'a' in
  Weak.set weak 1 (Some value);
  array.(0) <- Some value;
  assert (Option.get array.(0) == value);
  array.(0) <- None

let array_reject weak (array : bytes option array) index =
  let value = Bytes.make 8 'x' in
  Weak.set weak 2 (Some value);
  match array.(index) <- Some value with
  | exception Invalid_argument _ -> ()
  | () -> assert false

let () =
  let weak = Weak.create 3 in
  let slot = {count = 6; data = None} in
  let array = [|None|] in
  record_replace weak slot;
  array_replace weak array;
  array_reject weak array 1;
  assert (slot.count = 7 && slot.data = None && array.(0) = None);
  Gc.full_major ();
  for i = 0 to 2 do assert (not (Weak.check weak i)) done;
  print_endline "field and array ownership: ok"
