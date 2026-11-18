(* Run with stock OCaml or with an ocamlcc compatibility stdlib. This
   contract deliberately treats unsupported registration as a test failure. *)
type node = { mutable next : node option; payload : int ref }

let check ok message = if not ok then failwith message

let collect () =
  Gc.full_major ();
  Gc.full_major ()

let check_lifetime cyclic =
  let weak = Weak.create 1 in
  let saved = ref None in
  let events = ref [] in
  let put_back x =
    check (!(x.payload) = 42) "lost payload";
    if cyclic then
      (match x.next with
       | Some original -> check (original == x) "lost cycle identity"
       | None -> failwith "lost cycle");
    saved := Some x;
    events := "publish" :: !events
  in
  let install () =
    let x = { next = None; payload = ref 42 } in
    if cyclic then x.next <- Some x;
    Weak.set weak 0 (Some x);
    Gc.finalise (fun _ -> events := "older" :: !events) x;
    Gc.finalise_last (fun () ->
      check (Weak.get weak 0 = None) "last callback observed live target";
      events := "last" :: !events) x;
    Gc.finalise put_back x;
    collect ();
    check (!events = []) "callback ran while target was rooted";
    ignore (Sys.opaque_identity x)
  in
  install ();
  collect ();
  check (!events = ["older"; "publish"]) "ordinary callback order or resurrection";
  (match !saved, Weak.get weak 0 with
   | Some x, Some original ->
       check (x == original && !(x.payload) = 42) "resurrected target changed"
   | _ -> failwith "missing resurrected target");
  saved := None;
  collect ();
  check (!events = ["last"; "older"; "publish"]) "permanent death or duplicate delivery"

let check_alarm () =
  let calls = ref 0 in
  let alarm = Gc.create_alarm (fun () -> incr calls) in
  collect ();
  check (!calls > 0) "alarm never fired";
  let first = !calls in
  collect ();
  check (!calls > first) "alarm did not re-register";
  Gc.delete_alarm alarm;
  let stopped = !calls in
  collect ();
  check (!calls = stopped) "deleted alarm fired"

let check_registered_leaf () =
  let events = ref [] in
  let install () =
    let leaf = Bytes.make 1 'x' in
    let parent = ref leaf in
    Gc.finalise (fun _ -> events := "parent" :: !events) parent;
    Gc.finalise (fun _ -> events := "leaf" :: !events) leaf;
    ignore (Sys.opaque_identity parent)
  in
  install ();
  collect ();
  check (!events = ["parent"; "leaf"]) "registration order across a leaf edge"

exception From_finalizer

let check_exception () =
  let calls = ref 0 in
  let install () =
    let x = ref 1 in
    Gc.finalise (fun _ -> incr calls) x;
    Gc.finalise (fun _ -> raise From_finalizer) x;
    ignore (Sys.opaque_identity x)
  in
  let caught =
    try install (); collect (); false with From_finalizer -> true
  in
  check caught "finalizer exception did not reach its caller";
  collect ();
  check (!calls = 1) "exception lost or repeated the other registration"

let check_many () =
  let count = 1500 in
  let seen = Array.make count 0 in
  let install i =
    let target = ref i in
    Gc.finalise (fun x -> seen.(!x) <- seen.(!x) + 1) target
  in
  for i = 0 to count - 1 do install i done;
  collect ();
  Array.iter (fun calls -> check (calls = 1) "batch lost or repeated a callback") seen

let () =
  try
    check_lifetime false;
    print_endline "acyclic resurrection and final death: ok";
    check_lifetime true;
    print_endline "cyclic resurrection and final death: ok";
    check_exception ();
    check_registered_leaf ();
    check_many ();
    check_alarm ();
    print_endline "alarm re-registration and deletion: ok"
  with Failure message ->
    prerr_endline message;
    exit 1
