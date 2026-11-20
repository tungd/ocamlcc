external raise : exn -> 'a = "%raise"
external ignore : 'a -> unit = "%ignore"
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( == ) : 'a -> 'a -> bool = "%eq"
external ( < ) : 'a -> 'a -> bool = "%lessthan"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external ( <= ) : 'a -> 'a -> bool = "%lessequal"
external ( >= ) : 'a -> 'a -> bool = "%greaterequal"
external not : bool -> bool = "%boolnot"
external ( && ) : bool -> bool -> bool = "%sequand"
external ( || ) : bool -> bool -> bool = "%sequor"
external ( + ) : int -> int -> int = "%addint"
external ( - ) : int -> int -> int = "%subint"
external ( * ) : int -> int -> int = "%mulint"
external ( / ) : int -> int -> int = "%divint"
external cast : 'a -> 'b = "%identity"

external array_make : int -> 'a -> 'a array = "caml_array_make"

type ('a, 'b) coro
type obj_t

external create : ('a -> 'b) -> ('a, 'b) coro = "ocamlcc_fiber_create"
external raw_resume : ('a, 'b) coro -> 'a -> 'b = "ocamlcc_fiber_resume"
external raw_suspend : 'b -> 'a = "ocamlcc_fiber_suspend"
external is_done : ('a, 'b) coro -> bool = "ocamlcc_fiber_is_done"

external raw_is_main : unit -> bool = "ocamlcc_fiber_is_main"
external raw_can_yield : unit -> unit = "ocamlcc_fiber_can_yield"
external raw_sched_get : unit -> 's option = "ocamlcc_fiber_sched_get"
external raw_sched_set : 's option -> unit = "ocamlcc_fiber_sched_set"
external raw_monotonic_ns : unit -> int = "ocamlcc_monotonic_ns"
external raw_poller_watch : int -> int -> int -> unit = "ocamlcc_poller_watch"
external raw_poller_wait : int array -> int -> int = "ocamlcc_poller_wait"

external pipe : unit -> int * int = "ocamlcc_pipe"
external fd_read : int -> bytes -> int -> int -> int = "ocamlcc_fd_read"
external fd_write : int -> bytes -> int -> int -> int = "ocamlcc_fd_write"
external fd_close : int -> unit = "ocamlcc_fd_close"

external array_get : 'a array -> int -> 'a = "%array_unsafe_get"

let poll_read = 1
let poll_write = 2
let max_poll_ms = 0x7fffffff

let raise_invalid () = raise (Invalid_argument "Fiber: invalid operation")

type outcome =
  | Pending
  | Ok of obj_t
  | Err of exn

type sched_cmd =
  | CmdDone of outcome
  | CmdYield
  | CmdSleep of int
  | CmdWaitFd
  | CmdPark

type any_task = {
  coro : (unit, sched_cmd) coro;
  mutable state : outcome;
  mutable awaiting : any_task option;
  mutable waiters : any_task list;
}

type 'a t = any_task

type timer_entry = {
  deadline : int;
  t_task : any_task;
}

type io_entry = {
  io_tok : int;
  io_main : bool;
  io_task : any_task option;
}

type sched_state = {
  mutable active : any_task option;
  mutable ready : any_task list;
  mutable ready_rev : any_task list;
  mutable timers : timer_entry list;
  mutable io_waiters : io_entry list;
  mutable next_tok : int;
  mutable main_io_pending : bool;
  mutable main_io_ready : bool;
  poll_buf : int array;
}

let make_sched () : sched_state =
  {
    active = None;
    ready = [];
    ready_rev = [];
    timers = [];
    io_waiters = [];
    next_tok = 1;
    main_io_pending = false;
    main_io_ready = false;
    poll_buf = array_make 64 0;
  }

let get_sched () : sched_state =
  match raw_sched_get () with
  | Some s -> s
  | None ->
      let s = make_sched () in
      raw_sched_set (Some s);
      s

let is_idle (s : sched_state) =
  match s.active, s.ready, s.ready_rev, s.timers, s.io_waiters with
  | None, [], [], [], [] -> not s.main_io_pending && not s.main_io_ready
  | _ -> false

let release_if_idle (s : sched_state) =
  if is_idle s then raw_sched_set None

let rec rev_append xs acc =
  match xs with
  | [] -> acc
  | x :: tl -> rev_append tl (x :: acc)

let has_ready (s : sched_state) =
  match s.ready, s.ready_rev with
  | [], [] -> false
  | _ -> true

let push_ready (s : sched_state) (task : any_task) =
  s.ready_rev <- task :: s.ready_rev

let pop_ready (s : sched_state) : any_task option =
  match s.ready with
  | x :: rest ->
      s.ready <- rest;
      Some x
  | [] -> (
      match rev_append s.ready_rev [] with
      | [] -> None
      | x :: rest ->
          s.ready <- rest;
          s.ready_rev <- [];
          Some x)

let resume c v =
  match raw_sched_get () with
  | None -> raw_resume c v
  | Some s -> (
      let prev = s.active in
      s.active <- None;
      let res = try Ok (cast (raw_resume c v)) with e -> Err e in
      s.active <- prev;
      match res with
      | Ok r -> cast r
      | Err e -> raise e
      | Pending -> raise_invalid ())

let suspend v =
  raw_can_yield ();
  if raw_is_main () then raise_invalid ();
  let blocked =
    match raw_sched_get () with
    | None -> false
    | Some s -> s.active <> None
  in
  if blocked then raise_invalid ();
  raw_suspend v

let drain_timers (s : sched_state) =
  match s.timers with
  | [] -> ()
  | ts ->
      let now = raw_monotonic_ns () in
      let rec loop acc = function
        | [] -> s.timers <- acc
        | entry :: rest ->
            if entry.deadline <= now then begin
              push_ready s entry.t_task;
              loop acc rest
            end else
              loop (entry :: acc) rest
      in
      loop [] ts

let next_timer_timeout_ms (s : sched_state) =
  match s.timers with
  | [] -> -1
  | first :: rest ->
      let rec find_min best = function
        | [] -> best
        | e :: tl ->
            find_min (if e.deadline < best then e.deadline else best) tl
      in
      let earliest = find_min first.deadline rest in
      let now = raw_monotonic_ns () in
      if earliest <= now then 0
      else
        let diff_ns = earliest - now in
        let ms = (diff_ns + 999999) / 1000000 in
        if ms > max_poll_ms then max_poll_ms else ms

let rec remove_io_waiter tok acc = function
  | [] -> (None, acc)
  | e :: rest ->
      if e.io_tok = tok then (Some e, rev_append acc rest)
      else remove_io_waiter tok (e :: acc) rest

let sched_poll (s : sched_state) timeout_ms =
  drain_timers s;
  if s.io_waiters = [] then begin
    if timeout_ms > 0 then begin
      ignore (raw_poller_wait s.poll_buf timeout_ms);
      drain_timers s
    end
  end else begin
    let tms = if has_ready s then 0 else timeout_ms in
    let n = raw_poller_wait s.poll_buf tms in
    for i = 0 to n - 1 do
      let tok = array_get s.poll_buf i in
      let found, rest = remove_io_waiter tok [] s.io_waiters in
      s.io_waiters <- rest;
      match found with
      | None -> ()
      | Some e ->
          if e.io_main then begin
            s.main_io_pending <- false;
            s.main_io_ready <- true
          end else begin
            match e.io_task with
            | Some t -> push_ready s t
            | None -> ()
          end
    done;
    drain_timers s
  end

let complete_task (s : sched_state) (t : any_task) outcome =
  t.state <- outcome;
  let ws = rev_append t.waiters [] in
  t.waiters <- [];
  let rec wake = function
    | [] -> ()
    | w :: rest ->
        w.awaiting <- None;
        push_ready s w;
        wake rest
  in
  wake ws

let step_task (s : sched_state) (t : any_task) =
  let prev = s.active in
  s.active <- Some t;
  let cmd = raw_resume t.coro () in
  s.active <- prev;
  match cmd with
  | CmdDone outcome -> complete_task s t outcome
  | CmdYield -> push_ready s t
  | CmdSleep deadline -> s.timers <- { deadline; t_task = t } :: s.timers
  | CmdWaitFd | CmdPark -> ()

let sched_step (s : sched_state) =
  sched_poll s 0;
  match pop_ready s with
  | Some next ->
      step_task s next;
      true
  | None ->
      if s.io_waiters <> [] || s.timers <> [] || s.main_io_pending then begin
        let tms = next_timer_timeout_ms s in
        sched_poll s tms;
        true
      end else
        false

let spawn (fn : unit -> 'a) : 'a t =
  let s = get_sched () in
  let coro =
    create (fun () ->
        let outcome =
          try Ok (cast (fn ()))
          with e -> Err e
        in
        CmdDone outcome)
  in
  let task = { coro; state = Pending; awaiting = None; waiters = [] } in
  push_ready s task;
  task

let yield () =
  raw_can_yield ();
  let s = get_sched () in
  match s.active with
  | Some _ -> ignore (raw_suspend CmdYield)
  | None ->
      if not (raw_is_main ()) then begin
        release_if_idle s;
        raise_invalid ()
      end else begin
        sched_poll s 0;
        (match pop_ready s with
         | Some next -> step_task s next
         | None -> ());
        release_if_idle s
      end

let sleep_ms ms =
  raw_can_yield ();
  if ms <= 0 then yield ()
  else
    let s = get_sched () in
    let deadline = raw_monotonic_ns () + (ms * 1000000) in
    match s.active with
    | Some _ -> ignore (raw_suspend (CmdSleep deadline))
    | None ->
        if not (raw_is_main ()) then begin
          release_if_idle s;
          raise_invalid ()
        end else begin
          let rec loop () =
            let now = raw_monotonic_ns () in
            if now < deadline then begin
              if sched_step s then loop ()
              else begin
                let rem = (deadline - now + 999999) / 1000000 in
                let rem = if rem > max_poll_ms then max_poll_ms else rem in
                ignore (raw_poller_wait s.poll_buf rem);
                loop ()
              end
            end
          in
          loop ();
          release_if_idle s
        end

let fd_wait_dir fd events =
  raw_can_yield ();
  let s = get_sched () in
  if s.active = None && not (raw_is_main ()) then begin
    release_if_idle s;
    raise_invalid ()
  end;
  let tok = s.next_tok in
  s.next_tok <- tok + 1;
  (try raw_poller_watch fd events tok
   with e ->
     release_if_idle s;
     raise e);
  match s.active with
  | Some cur ->
      s.io_waiters <- { io_tok = tok; io_main = false; io_task = Some cur } :: s.io_waiters;
      ignore (raw_suspend CmdWaitFd)
  | None ->
      s.io_waiters <- { io_tok = tok; io_main = true; io_task = None } :: s.io_waiters;
      s.main_io_pending <- true;
      s.main_io_ready <- false;
      while not s.main_io_ready do
        ignore (sched_step s)
      done;
      s.main_io_ready <- false;
      release_if_idle s

let fd_wait_read fd = fd_wait_dir fd poll_read
let fd_wait_write fd = fd_wait_dir fd poll_write

let unwrap_outcome = function
  | Ok v -> cast v
  | Err e -> raise e
  | Pending -> raise_invalid ()

let await (target : 'a t) : 'a =
  raw_can_yield ();
  let s = get_sched () in
  (match target.state with
   | Pending -> (
       match s.active with
       | Some cur ->
           if target == cur then raise_invalid ();
           let rec has_cycle = function
             | None -> ()
             | Some p -> if p == cur then raise_invalid () else has_cycle p.awaiting
           in
           has_cycle target.awaiting;
           cur.awaiting <- Some target;
           target.waiters <- cur :: target.waiters;
           ignore (raw_suspend CmdPark)
       | None ->
           if not (raw_is_main ()) then begin
             release_if_idle s;
             raise_invalid ()
           end else begin
             while target.state = Pending do
               if not (sched_step s) then begin
                 release_if_idle s;
                 raise_invalid ()
               end
             done
           end)
   | Ok _ | Err _ -> ());
  release_if_idle s;
  unwrap_outcome target.state

let run_all () =
  raw_can_yield ();
  if not (raw_is_main ()) then raise_invalid ();
  let s = get_sched () in
  if s.active <> None then raise_invalid ();
  while sched_step s do
    ()
  done;
  release_if_idle s
