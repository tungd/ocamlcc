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

external array_make : int -> 'a -> 'a array = "caml_array_make"

type ('a, 'b) coro

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
external raw_poller_unwatch : int -> int -> int -> unit = "ocamlcc_poller_unwatch_waiter"
external raw_poller_wait : int array -> int -> int = "ocamlcc_poller_wait"

external pipe : unit -> int * int = "ocamlcc_pipe"
external fd_read : int -> bytes -> int -> int -> int = "ocamlcc_fd_read"
external fd_write : int -> bytes -> int -> int -> int = "ocamlcc_fd_write"
external fd_close : int -> unit = "ocamlcc_fd_close"

external array_get : 'a array -> int -> 'a = "%array_unsafe_get"

module Deadline : sig
  type t
  val after_ms : int -> t
  val reached : now:int -> t -> bool
  val remaining_ms : now:int -> t -> int
  val earlier : t -> t -> t
end = struct
  type t = int
  let max_poll_ms = 0x7fffffff
  let max_ns = 0x3fff_ffff_ffff_ffff

  let after_ms ms =
    let now = raw_monotonic_ns () in
    if ms > (max_ns - now) / 1000000 then max_ns else now + (ms * 1000000)

  let reached ~now deadline = deadline <= now

  let remaining_ms ~now deadline =
    if reached ~now deadline then 0
    else
      let ms = ((deadline - now - 1) / 1000000) + 1 in
      if ms > max_poll_ms then max_poll_ms else ms

  let earlier a b = if a <= b then a else b
end

let raise_invalid () = raise (Invalid_argument "Fiber: invalid operation")

module Command = struct
  type t = Done | Yield | Sleep of Deadline.t | Wait_fd | Park
end

module Task = struct
  module Handle = struct
    type t = {
      coro : (unit, Command.t) coro;
      mutable awaiting : t option;
      mutable waiters : t list;
    }
  end

  module Outcome = struct
    type 'a t = Pending | Returned of 'a | Raised of exn
  end

  module Completion = struct
    type 'a t = { mutable outcome : 'a Outcome.t }
  end

  type 'a t = { handle : Handle.t; completion : 'a Completion.t }

  let create fn =
    let completion : _ Completion.t = { outcome = Pending } in
    let coro = create (fun () ->
      completion.outcome <- (try Returned (fn ()) with e -> Raised e);
      Command.Done) in
    { handle = { coro; awaiting = None; waiters = [] }; completion }

  let outcome task = task.completion.outcome

  let is_pending task =
    match outcome task with Pending -> true | Returned _ | Raised _ -> false
end

type 'a t = 'a Task.t

module Timer = struct
  type t = { deadline : Deadline.t; task : Task.Handle.t }
end

module Cancel : sig
  type t
  val create : unit -> t
  val cancel : t -> unit
  val is_cancelled : t -> bool
end = struct
  type t = { mutable cancelled : bool }
  let create () = { cancelled = false }
  let cancel token = token.cancelled <- true
  let is_cancelled token = token.cancelled
end

module Direction = struct
  type t = Read | Write
  let events = function Read -> 1 | Write -> 2
end

module Wait_result = struct
  type t = Ready | Timed_out | Cancelled
end

module Registration = struct
  module Owner = struct
    type t = Main | Task of Task.Handle.t
  end

  module Completion = struct
    type t = { mutable outcome : Wait_result.t option }
  end

  type t = {
    token : int;
    fd : int;
    direction : Direction.t;
    owner : Owner.t;
    deadline : Deadline.t option;
    cancellation : Cancel.t option;
    completion : Completion.t;
  }

  let cancelled = function None -> false | Some token -> Cancel.is_cancelled token

  let cancellation wait =
    if cancelled wait.cancellation then Some Wait_result.Cancelled else None

  let expiry ~now wait =
    match wait.deadline with
    | Some deadline when Deadline.reached ~now deadline -> Some Wait_result.Timed_out
    | _ -> None

  let unregister wait =
    raw_poller_unwatch wait.fd (Direction.events wait.direction) wait.token

  let settle wait outcome =
    wait.completion.outcome <- Some outcome;
    wait.owner
end

let rec rev_append xs acc =
  match xs with
  | [] -> acc
  | x :: tl -> rev_append tl (x :: acc)

module Scheduler = struct
  type t = {
    mutable active : Task.Handle.t option;
    mutable ready : Task.Handle.t list;
    mutable ready_rev : Task.Handle.t list;
    mutable timers : Timer.t list;
    mutable io_waiters : Registration.t list;
    mutable next_tok : int;
    poll_buf : int array;
  }

  let create () : t =
    {
      active = None;
      ready = [];
      ready_rev = [];
      timers = [];
      io_waiters = [];
      next_tok = 1;
      poll_buf = array_make 64 0;
    }

  let existing () : t option = raw_sched_get ()

  let current () : t =
    match existing () with
    | Some s -> s
    | None ->
        let s = create () in
        raw_sched_set (Some s);
        s

  let is_idle (s : t) =
    match s.active, s.ready, s.ready_rev, s.timers, s.io_waiters with
    | None, [], [], [], [] -> true
    | _ -> false

  let release_if_idle (s : t) =
    if is_idle s then raw_sched_set None

  let has_ready (s : t) =
    match s.ready, s.ready_rev with
    | [], [] -> false
    | _ -> true

  let push (s : t) (task : Task.Handle.t) =
    s.ready_rev <- task :: s.ready_rev

  let pop (s : t) : Task.Handle.t option =
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
end

let resume c v =
  match Scheduler.existing () with
  | None -> raw_resume c v
  | Some s -> (
      let prev = s.active in
      s.active <- None;
      match raw_resume c v with
      | value -> s.active <- prev; value
      | exception error -> s.active <- prev; raise error)

let suspend v =
  raw_can_yield ();
  if raw_is_main () then raise_invalid ();
  let blocked =
    match Scheduler.existing () with
    | None -> false
    | Some s -> s.active <> None
  in
  if blocked then raise_invalid ();
  raw_suspend v

let drain_timers (s : Scheduler.t) =
  match s.timers with
  | [] -> ()
  | ts ->
      let now = raw_monotonic_ns () in
      let rec loop acc (timers : Timer.t list) =
        match timers with
        | [] -> s.timers <- acc
        | entry :: rest ->
            if Deadline.reached ~now entry.deadline then begin
              Scheduler.push s entry.task;
              loop acc rest
            end else
              loop (entry :: acc) rest
      in
      loop [] ts

let next_timer_timeout_ms (s : Scheduler.t) =
  let min_deadline earlier other =
    match earlier with
    | Some deadline -> Some (Deadline.earlier deadline other)
    | None -> Some other
  in
  let rec timer_min earliest (timers : Timer.t list) = match timers with
    | [] -> earliest
    | e :: rest -> timer_min (min_deadline earliest e.deadline) rest
  in
  let rec io_min earliest (waits : Registration.t list) = match waits with
    | [] -> earliest
    | {deadline = None; _} :: rest -> io_min earliest rest
    | {deadline = Some deadline; _} :: rest ->
        io_min (min_deadline earliest deadline) rest
  in
  match io_min (timer_min None s.timers) s.io_waiters with
  | None -> -1
  | Some deadline -> Deadline.remaining_ms ~now:(raw_monotonic_ns ()) deadline

let rec remove_io_waiter tok acc (waits : Registration.t list) = match waits with
  | [] -> (None, acc)
  | e :: rest ->
      if e.token = tok then (Some e, rev_append acc rest)
      else remove_io_waiter tok (e :: acc) rest

let complete_wait (s : Scheduler.t) entry result =
  match Registration.settle entry result with
  | Main -> ()
  | Task task -> Scheduler.push s task

let drop_io (s : Scheduler.t) decide =
  let rec drop = function
    | [] -> None
    | entry :: rest ->
        match decide entry with
        | None ->
            (match drop rest with
             | None -> None
             | Some rest -> Some (entry :: rest))
        | Some result ->
            Registration.unregister entry;
            complete_wait s entry result;
            (match drop rest with None -> Some rest | updated -> updated)
  in
  match drop s.io_waiters with
  | None -> false
  | Some remaining -> s.io_waiters <- remaining; true

let sched_poll (s : Scheduler.t) timeout_ms =
  drain_timers s;
  let removed = drop_io s Registration.cancellation in
  let timeout_ms = if removed || Scheduler.has_ready s then 0 else timeout_ms in
  let n =
    if timeout_ms > 0 || s.io_waiters <> [] then raw_poller_wait s.poll_buf timeout_ms
    else 0 in
  for i = 0 to n - 1 do
    let tok = array_get s.poll_buf i in
    let found, rest = remove_io_waiter tok [] s.io_waiters in
    s.io_waiters <- rest;
    match found with
    | None -> ()
    | Some entry -> complete_wait s entry Wait_result.Ready
  done;
  let expired =
    match s.io_waiters with
    | [] -> false
    | _ ->
        let now = raw_monotonic_ns () in
        drop_io s (Registration.expiry ~now) in
  drain_timers s;
  removed || n > 0 || expired

let complete_task (s : Scheduler.t) (t : Task.Handle.t) =
  let ws = rev_append t.waiters [] in
  t.waiters <- [];
  let rec wake (waiters : Task.Handle.t list) = match waiters with
    | [] -> ()
    | w :: rest ->
        w.awaiting <- None;
        Scheduler.push s w;
        wake rest
  in
  wake ws

let step_task (s : Scheduler.t) (t : Task.Handle.t) =
  let prev = s.active in
  s.active <- Some t;
  let cmd = raw_resume t.coro () in
  s.active <- prev;
  match cmd with
  | Done -> complete_task s t
  | Yield -> Scheduler.push s t
  | Sleep deadline -> s.timers <- { deadline; task = t } :: s.timers
  | Wait_fd | Park -> ()

let sched_step (s : Scheduler.t) =
  let progressed = sched_poll s 0 in
  match Scheduler.pop s with
  | Some next ->
      step_task s next;
      true
  | None when progressed -> true
  | None ->
      if s.io_waiters <> [] || s.timers <> [] then begin
        let tms = next_timer_timeout_ms s in
        ignore (sched_poll s tms);
        true
      end else
        false

let spawn (fn : unit -> 'a) : 'a t =
  let s = Scheduler.current () in
  let task = Task.create fn in
  Scheduler.push s task.handle;
  task

let yield () =
  raw_can_yield ();
  let s = Scheduler.current () in
  match s.active with
  | Some _ -> ignore (raw_suspend Command.Yield)
  | None ->
      if not (raw_is_main ()) then begin
        Scheduler.release_if_idle s;
        raise_invalid ()
      end else begin
        ignore (sched_poll s 0);
        (match Scheduler.pop s with
         | Some next -> step_task s next
         | None -> ());
        Scheduler.release_if_idle s
      end

let sleep_ms ms =
  raw_can_yield ();
  if ms <= 0 then yield ()
  else
    let s = Scheduler.current () in
    let deadline = Deadline.after_ms ms in
    match s.active with
    | Some _ -> ignore (raw_suspend (Command.Sleep deadline))
    | None ->
        if not (raw_is_main ()) then begin
          Scheduler.release_if_idle s;
          raise_invalid ()
        end else begin
          let rec loop () =
            let now = raw_monotonic_ns () in
            if not (Deadline.reached ~now deadline) then begin
              if sched_step s then loop ()
              else begin
                let rem = Deadline.remaining_ms ~now deadline in
                ignore (raw_poller_wait s.poll_buf rem);
                loop ()
              end
            end
          in
          loop ();
          Scheduler.release_if_idle s
        end

let fd_wait ?timeout_ms ?cancel fd direction =
  raw_can_yield ();
  let deadline =
    match timeout_ms with
    | None -> None
    | Some ms when ms < 0 -> raise (Invalid_argument "Fiber.fd_wait: negative timeout")
    | Some ms -> Some (Deadline.after_ms ms)
  in
  let s = Scheduler.current () in
  let owner =
    match s.active with
    | Some task -> Registration.Owner.Task task
    | None when raw_is_main () -> Registration.Owner.Main
    | None -> Scheduler.release_if_idle s; raise_invalid ()
  in
  if Registration.cancelled cancel then begin
    Scheduler.release_if_idle s;
    Wait_result.Cancelled
  end else begin
    let tok = s.next_tok in
    s.next_tok <- tok + 1;
    (try raw_poller_watch fd (Direction.events direction) tok
     with e -> Scheduler.release_if_idle s; raise e);
    let completion : Registration.Completion.t = { outcome = None } in
    s.io_waiters <- {
      token = tok; fd; direction; owner; deadline; cancellation = cancel; completion;
    } :: s.io_waiters;
    (match owner with
     | Task _ -> ignore (raw_suspend Command.Wait_fd)
     | Main ->
         while completion.outcome = None do
           ignore (sched_step s)
         done;
         Scheduler.release_if_idle s);
    match completion.outcome with Some result -> result | None -> raise_invalid ()
  end

let fd_wait_read fd = ignore (fd_wait fd Direction.Read)
let fd_wait_write fd = ignore (fd_wait fd Direction.Write)

let await (target : 'a t) : 'a =
  raw_can_yield ();
  let s = Scheduler.current () in
  (match Task.outcome target with
   | Pending -> (
       match s.active with
       | Some cur ->
           let handle = target.handle in
           if handle == cur then raise_invalid ();
           let rec has_cycle (waiting : Task.Handle.t option) = match waiting with
             | None -> ()
             | Some p -> if p == cur then raise_invalid () else has_cycle p.awaiting
           in
           has_cycle handle.awaiting;
           cur.awaiting <- Some handle;
           handle.waiters <- cur :: handle.waiters;
           ignore (raw_suspend Command.Park)
       | None ->
           if not (raw_is_main ()) then begin
             Scheduler.release_if_idle s;
             raise_invalid ()
           end else begin
             while Task.is_pending target do
               if not (sched_step s) then begin
                 Scheduler.release_if_idle s;
                 raise_invalid ()
               end
             done
           end)
   | Returned _ | Raised _ -> ());
  Scheduler.release_if_idle s;
  match Task.outcome target with
  | Returned value -> value
  | Raised error -> raise error
  | Pending -> raise_invalid ()

let run_all () =
  raw_can_yield ();
  if not (raw_is_main ()) then raise_invalid ();
  let s = Scheduler.current () in
  if s.active <> None then raise_invalid ();
  while sched_step s do
    ()
  done;
  Scheduler.release_if_idle s
