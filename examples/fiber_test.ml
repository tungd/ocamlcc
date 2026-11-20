open Stdlib

external arc_live : unit -> int = "ocamlcc_arc_live"
external arc_collect : unit -> int = "ocamlcc_arc_collect"
external arc_poll_finalizers : unit -> int = "ocamlcc_poll_finalizers"
external gc_major : unit -> unit = "caml_gc_major"
external final_register_no_val : (unit -> unit) -> 'a -> unit
  = "caml_final_register_called_without_value"

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

(* Over-application across a suspending first call: `mk seed seed keep`
   has arity 2 but is applied to 3 arguments, so the codegen splits it into
   a first (suspending) call plus an over-apply tail. The tail argument must
   be shadowed across the first call, or an abandoned fiber leaks it. *)
let test_abandon_over_apply () =
  let w = Weak.create 1 in
  let make_and_drop () =
    let c =
      Fiber.create (fun seed ->
          let keep = { contents = seed + 1 } in
          Weak.set w 0 (Some keep);
          let mk a b =
            Fiber.suspend (a, b);
            fun x -> a + b + x.contents
          in
          ignore (mk seed seed keep);
          (seed, seed))
    in
    let y = Fiber.resume c 10 in
    let still_open = if Fiber.is_done c then 0 else 1 in
    (fst y, snd y, still_open)
  in
  let py1, py2, still_open = make_and_drop () in
  (* The abandoned coroutine's release can queue finalizer / cycle work;
     drain it so the delta measures real leaks only. *)
  ignore (arc_collect ());
  let alive_after = if Weak.check w 0 then 1 else 0 in
  (py1, py2, still_open, alive_after)

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

let test_sched_edges () =
  (* 1. Timer ordering: 14ms vs 2ms -> shorter deadline finishes first. *)
  let tlog = Buffer.create 16 in
  let slow = Fiber.spawn (fun () -> Fiber.sleep_ms 14; Buffer.add_string tlog "S"; 1) in
  let fast = Fiber.spawn (fun () -> Fiber.sleep_ms 2; Buffer.add_string tlog "F"; 2) in
  let s_res = Fiber.await slow + Fiber.await fast in
  (* 2. Multiple waiters on a single fiber + exception propagation to all waiters. *)
  let target = Fiber.spawn (fun () -> Fiber.yield (); 21) in
  let w1 = Fiber.spawn (fun () -> Fiber.await target + 1) in
  let w2 = Fiber.spawn (fun () -> Fiber.await target + 2) in
  let w_sum = Fiber.await w1 + Fiber.await w2 in
  (* 3. Invalid fd + self/cycle await raise Invalid_argument. *)
  let bad_fd =
    try Fiber.fd_wait_read (-1); 0
    with Invalid_argument _ -> 1
  in
  let self_r : int Fiber.t option ref = ref None in
  let self_f = Fiber.spawn (fun () ->
    match !self_r with
    | None -> 0
    | Some me -> (try Fiber.await me; 0 with Invalid_argument _ -> 1))
  in
  self_r := Some self_f;
  let self_ok = Fiber.await self_f in
  self_r := None;
  (* 4. Finalizer must refuse all fiber yield/suspend/wait/await points. *)
  let fin_ok = ref 0 in
  let done_f = Fiber.spawn (fun () -> 7) in
  ignore (Fiber.await done_f);
  let mk () =
    let obj = (10, ref 20) in
    final_register_no_val (fun () ->
      let check f =
        try f (); false with Invalid_argument _ -> true
      in
      if check Fiber.yield
         && check (fun () -> Fiber.suspend 0)
         && check (fun () -> Fiber.sleep_ms 1)
         && check (fun () -> Fiber.fd_wait_read 0)
         && check (fun () -> ignore (Fiber.await done_f))
      then fin_ok := 1) obj
  in
  mk ();
  gc_major ();
  Fiber.run_all ();
  (Buffer.contents tlog, s_res, w_sum, bad_fd, self_ok, !fin_ok)

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
  (* Earlier probes can leave finalizer dispatch pending; drain it so the
     over-apply delta measures only this probe's leaks. *)
  ignore (arc_poll_finalizers ());
  let oa_before = arc_live () in
  let oa1, oa2, oa3, oa4 = test_abandon_over_apply () in
  ignore (arc_poll_finalizers ());
  ignore (arc_collect ());
  let delta5 = arc_live () - oa_before in
  Printf.printf "coro=%d,%d,%d,%d,%d,%d,%d,%d,%d delta=%d\n" a1 a2 d1 b1 b2 d2
    c1 c2 d3 delta1;
  Printf.printf "abandon=%d susp=%d open=%d after=%d delta=%d\n" y alive_susp
    still_open alive_after delta2;
  Printf.printf "exns=%d,%d,%d delta=%d\n" v1 caught1 caught2 delta3;
  Printf.printf "sched=[%s] sum=%d " trace total;
  let delta4 = arc_live () - live0 in
  Printf.printf "delta=%d\n" delta4;
  Printf.printf "cross=%d,%d,%d,%d,%d\n" x1 x2 x3 x4 x5;
  Printf.printf "oapp=%d,%d,%d,%d delta=%d\n" oa1 oa2 oa3 oa4 delta5;
  let ed_before = arc_live () in
  let sres, wsum, badfd, selfok, finok =
    let ttrace, sres, wsum, badfd, selfok, finok = test_sched_edges () in
    Printf.printf "edges=[%s] %d,%d,%d,%d,%d " ttrace sres wsum badfd selfok
      finok;
    (sres, wsum, badfd, selfok, finok)
  in
  ignore (sres, wsum, badfd, selfok, finok);
  gc_major ();
  ignore (arc_collect ());
  let delta6 = arc_live () - ed_before in
  Printf.printf "delta=%d\n" delta6
