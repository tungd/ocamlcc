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

let () =
  check "Gc.finalise" Gc.finalise;
  check "Gc.finalise_last" Gc.finalise_last;
  print_endline "ok"
