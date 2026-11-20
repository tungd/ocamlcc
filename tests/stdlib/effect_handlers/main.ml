[@@@alert "-unstable"]

type _ Effect.t += Ask : int Effect.t

let deep () =
  let open Effect.Deep in
  let effc : type a. a Effect.t -> ((a, int) continuation -> int) option =
    function
    | Ask -> Some (fun k -> continue k 20)
    | _ -> None
  in
  match_with
    (fun () ->
      let a = Effect.perform Ask in
      let b = Effect.perform Ask in
      a + b)
    () { retc = succ; exnc = raise; effc }

let () =
  assert (deep () = 41);
  print_endline "deep: ok"

exception Cancel

let discontinue () =
  let open Effect.Deep in
  let pending : (int, int) continuation option ref = ref None in
  let cleaned = ref false in
  let effc : type a. a Effect.t -> ((a, int) continuation -> int) option =
    function
    | Ask -> Some (fun k -> pending := Some k; -1)
    | _ -> None
  in
  let first =
    try_with
      (fun () ->
        Fun.protect
          ~finally:(fun () -> cleaned := true)
          (fun () -> try Effect.perform Ask with Cancel -> 17))
      () { effc }
  in
  assert (first = -1 && not !cleaned);
  let k = Option.get !pending in
  assert (discontinue k Cancel = 17 && !cleaned);
  match continue k 20 with
  | exception Effect.Continuation_already_resumed -> ()
  | _ -> assert false

let forwarding () =
  let open Effect.Deep in
  let inner =
    { retc = (fun x -> x * 2); exnc = raise; effc = (fun _ -> None) }
  in
  let effc : type a. a Effect.t -> ((a, int) continuation -> int) option =
    function
    | Ask -> Some (fun k -> continue k 20)
    | _ -> None
  in
  let run () =
    match_with
      (fun () -> try Effect.perform Ask with Effect.Unhandled Ask -> 11)
      () inner
  in
  assert (run () = 22);
  assert (try_with run () { effc } = 40);
  (match Effect.perform Ask with
  | exception Effect.Unhandled Ask -> ()
  | _ -> assert false);
  let syntax () =
    match Effect.perform Ask with
    | x -> x + 1
    | effect Ask, k -> continue k 40
  in
  assert (syntax () = 41)

let abandon () =
  let open Effect.Deep in
  let weak = Weak.create 2 in
  let effc : type a. a Effect.t -> ((a, int) continuation -> int) option =
    function
    | Ask -> Some (fun _ -> 42)
    | _ -> None
  in
  let result =
    try_with
      (fun () ->
        let outer = Bytes.make 8 'o' in
        Weak.set weak 0 (Some outer);
        let x =
          try_with
            (fun () ->
              let inner = Bytes.make 8 'i' in
              Weak.set weak 1 (Some inner);
              let n = Effect.perform Ask in
              n + Bytes.length inner)
            () { effc = (fun _ -> None) }
        in
        x + Bytes.length outer)
      () { effc }
  in
  assert (result = 42);
  Gc.full_major ();
  assert (not (Weak.check weak 0));
  assert (not (Weak.check weak 1))

let () =
  discontinue ();
  forwarding ();
  abandon ();
  print_endline "deep continuation lifecycle: ok"

let shallow () =
  let open Effect.Shallow in
  let started = ref false in
  let initial =
    fiber (fun initial ->
      started := true;
      let a = Effect.perform Ask in
      let b = Effect.perform Ask in
      initial + a + b)
  in
  let finish =
    { retc = string_of_int; exnc = raise; effc = (fun _ -> None) }
  in
  let second : (int, string) handler =
    let effc : type a. a Effect.t -> ((a, int) continuation -> string) option =
      function
      | Ask -> Some (fun k -> continue_with k 37 finish)
      | _ -> None
    in
    { retc = (fun _ -> assert false); exnc = raise; effc }
  in
  let first : (int, string) handler =
    let effc : type a. a Effect.t -> ((a, int) continuation -> string) option =
      function
      | Ask -> Some (fun k -> continue_with k 3 second)
      | _ -> None
    in
    { retc = (fun _ -> assert false); exnc = raise; effc }
  in
  assert (not !started);
  assert (continue_with initial 2 first = "42" && !started);
  (match continue_with initial 2 first with
  | exception Effect.Continuation_already_resumed -> ()
  | _ -> assert false);
  let stop = fiber (fun () -> assert false) in
  let handler =
    { retc = (fun _ -> assert false);
      exnc = (function Cancel -> 7 | e -> raise e);
      effc = (fun _ -> None) }
  in
  assert (discontinue_with_backtrace stop Cancel
    (Printexc.get_callstack 0) handler = 7)

let () =
  shallow ();
  print_endline "shallow: ok"
