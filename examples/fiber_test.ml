open Stdlib

external arc_live : unit -> int = "ocamlcc_arc_live"

type box =
  | Leaf
  | PairBox of box * int

let test_coro () =
  let c =
    Fiber.create (fun init ->
        let y1 = Fiber.suspend (fst init, snd init + 1) in
        let y2 = Fiber.suspend (fst y1 + snd y1, 99) in
        (fst y2 + 100, snd y2 + 1))
  in
  let r1 = Fiber.resume c (10, 20) in
  let d1 = if Fiber.is_done c then 1 else 0 in
  let r2 = Fiber.resume c (3, 4) in
  let d2 = if Fiber.is_done c then 1 else 0 in
  let r3 = Fiber.resume c (50, 9) in
  let d3 = if Fiber.is_done c then 1 else 0 in
  (fst r1, snd r1, d1, fst r2, snd r2, d2, fst r3, snd r3, d3)

let test_abandon_suspended () =
  let w = Weak.create 1 in
  let make_and_drop () =
    let c =
      Fiber.create (fun seed ->
          let outer = (seed + 1, seed + 2) in
          Weak.set w 0 (Some outer);
          let r = ref (seed + 3, seed + 4) in
          let rec loop i b =
            match b with
            | Leaf -> 0
            | PairBox (next, v) ->
                if i = 0 then
                  let yielded = Fiber.suspend (fst !r + v) in
                  fst outer + snd !r + yielded
                else
                  let tmp = (i, fst outer) in
                  let sub = loop (i - 1) next in
                  PairBox (Leaf, sub + fst tmp) |> ignore;
                  sub + fst tmp
          in
          let acc = ref 0 in
          for _ = 1 to 2 do
            let tree = PairBox (PairBox (Leaf, 7), 5) in
            acc := !acc + loop 1 tree
          done;
          !acc + snd outer)
    in
    let y = Fiber.resume c 10 in
    let alive_susp = if Weak.check w 0 then 1 else 0 in
    let still_open = if Fiber.is_done c then 0 else 1 in
    (y, alive_susp, still_open)
  in
  let y, alive_susp, still_open = make_and_drop () in
  let alive_after = if Weak.check w 0 then 1 else 0 in
  (y, alive_susp, still_open, alive_after)

let test_exns () =
  let c =
    Fiber.create (fun () ->
        let tmp = (100, 200) in
        let _ = Fiber.suspend (fst tmp) in
        failwith "boom")
  in
  let v1 = Fiber.resume c () in
  let caught1 =
    try
      let _ = Fiber.resume c () in
      -1
    with Failure msg -> String.length msg
  in
  let f =
    Fiber.spawn (fun () ->
        let p = ("bad", 42) in
        Fiber.yield ();
        invalid_arg (fst p))
  in
  let caught2 =
    try
      let _ = Fiber.await f in
      -1
    with Invalid_argument msg -> String.length msg
  in
  (v1, caught1, caught2)

let test_coop_scheduler () =
  let log = Buffer.create 32 in
  let f1 =
    Fiber.spawn (fun () ->
        Buffer.add_string log "A1 ";
        Fiber.yield ();
        Buffer.add_string log "A2 ";
        Fiber.sleep_ms 4;
        Buffer.add_string log "A3 ";
        10)
  in
  let f2 =
    Fiber.spawn (fun () ->
        Buffer.add_string log "B1 ";
        let child =
          Fiber.spawn (fun () ->
              Buffer.add_string log "C1 ";
              Fiber.yield ();
              Buffer.add_string log "C2 ";
              22)
        in
        let cv = Fiber.await child in
        Buffer.add_string log "B2 ";
        cv + 8)
  in
  let s1 = Fiber.await f1 in
  let s2 = Fiber.await f2 in
  Fiber.run_all ();
  (Buffer.contents log, s1 + s2)

let test_cross_calls () =
  (* Fiber.yield inside a coroutine must raise, not queue the coroutine on
     the scheduler without ownership and return the resume payload. *)
  let c =
    Fiber.create (fun () ->
        try (Fiber.yield (); 0) with Invalid_argument _ -> 1)
  in
  let yield_in_coro = Fiber.resume c () in
  let d1 = if Fiber.is_done c then 1 else 0 in
  (* Fiber.suspend inside a spawned fiber must raise, not strand the fiber
     off every scheduler queue (leaking it and its payload). *)
  let f =
    Fiber.spawn (fun () ->
        try (Fiber.suspend 0; 0) with Invalid_argument _ -> 1)
  in
  let suspend_in_sched = Fiber.await f in
  (* Fiber.await inside a coroutine must raise: waiter handoff is only
     sound between scheduler fibers. *)
  let c2 =
    Fiber.create (fun () ->
        let child = Fiber.spawn (fun () -> 42) in
        try (Fiber.await child; 0) with Invalid_argument _ -> 1)
  in
  let await_in_coro = Fiber.resume c2 () in
  let d2 = if Fiber.is_done c2 then 1 else 0 in
  (* Drain the child spawn fiber queued by the await probe so the live
     object count returns to baseline. *)
  Fiber.run_all ();
  (yield_in_coro, d1, suspend_in_sched, await_in_coro, d2)

let () =
  let live0 = arc_live () in
  let a1, a2, d1, b1, b2, d2, c1, c2, d3 = test_coro () in
  let delta1 = arc_live () - live0 in
  let y, alive_susp, still_open, alive_after = test_abandon_suspended () in
  let delta2 = arc_live () - live0 in
  let v1, caught1, caught2 = test_exns () in
  let delta3 = arc_live () - live0 in
  let trace, total = test_coop_scheduler () in
  let x1, x2, x3, x4, x5 = test_cross_calls () in
  Printf.printf "coro=%d,%d,%d,%d,%d,%d,%d,%d,%d delta=%d\n" a1 a2 d1 b1 b2 d2
    c1 c2 d3 delta1;
  Printf.printf "abandon=%d susp=%d open=%d after=%d delta=%d\n" y alive_susp
    still_open alive_after delta2;
  Printf.printf "exns=%d,%d,%d delta=%d\n" v1 caught1 caught2 delta3;
  Printf.printf "sched=[%s] sum=%d " trace total;
  let delta4 = arc_live () - live0 in
  Printf.printf "delta=%d\n" delta4;
  Printf.printf "cross=%d,%d,%d,%d,%d\n" x1 x2 x3 x4 x5
