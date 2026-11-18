(* A successful registration must eventually call the callback. The ARC
   runtime reports unsupported registration synchronously. *)
let check name register =
  let calls = ref 0 in
  let install () =
    let target = ref 42 in
    register (fun _ -> incr calls) target;
    ignore (Sys.opaque_identity target)
  in
  match install () with
  | () ->
      Gc.full_major ();
      Gc.full_major ();
      assert (!calls = 1)
  | exception Failure msg ->
      assert (msg = name ^ ": unsupported by ARC");
      assert (!calls = 0)

let check_ordinary () =
  let calls = ref 0 in
  let published = ref None in
  let weak = Weak.create 1 in
  let install () =
    let target = ref 42 in
    Weak.set weak 0 (Some target);
    Gc.finalise (fun value ->
      incr calls;
      assert (!value = 42);
      published := Some value) target;
    Gc.full_major ();
    assert (!calls = 0);
    ignore (Sys.opaque_identity target)
  in
  install ();
  Gc.full_major ();
  assert (!calls = 1);
  (match !published, Weak.get weak 0 with
   | Some value, Some original -> assert (value == original)
   | _ -> assert false);
  published := None;
  Gc.full_major ();
  assert (!calls = 1 && Weak.get weak 0 = None)

let () =
  check_ordinary ();
  check "Gc.finalise_last" Gc.finalise_last;
  print_endline "ok"
