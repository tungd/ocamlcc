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
external raw_poller_unwatch : int -> int -> int -> unit = "ocamlcc_poller_unwatch_waiter"
external raw_poller_wait : int array -> int -> int = "ocamlcc_poller_wait"
external raw_poller_wait_adding : int array -> int -> int array -> int -> int =
  "ocamlcc_poller_wait_adding"

external pipe : unit -> int * int = "ocamlcc_pipe"
external fd_read : int -> bytes -> int -> int -> int = "ocamlcc_fd_read"
external fd_write : int -> bytes -> int -> int -> int = "ocamlcc_fd_write"
external fd_close : int -> unit = "ocamlcc_fd_close"

external array_get : 'a array -> int -> 'a = "%array_unsafe_get"
external array_set : 'a array -> int -> 'a -> unit = "%array_unsafe_set"

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

module Wait_owner = struct
  type t = Main | Task of Task.Handle.t
end

module Wait_options = struct
  type t = { deadline : Deadline.t option; cancel : Cancel.t option }

  let create ~invalid_timeout timeout_ms cancel =
    let deadline =
      match timeout_ms with
      | None -> None
      | Some ms when ms < 0 -> raise (Invalid_argument invalid_timeout)
      | Some ms -> Some (Deadline.after_ms ms)
    in
    { deadline; cancel }

  let cancellation t =
    match t.cancel with
    | Some token when Cancel.is_cancelled token -> Some Wait_result.Cancelled
    | _ -> None

  let expiry ~now t =
    match t.deadline with
    | Some deadline when Deadline.reached ~now deadline -> Some Wait_result.Timed_out
    | _ -> None
end

module Condition_key = struct
  type t = unit array

  (* The wait queue is owned by the scheduler. This value is only its key. *)
  let create () : t = array_make 1 ()
end

module Condition_wait = struct
  module Progress = struct
    type t = { mutable result : Wait_result.t option }
  end

  type t = {
    key : Condition_key.t;
    owner : Wait_owner.t;
    options : Wait_options.t;
    progress : Progress.t;
  }

  let cancellation entry = Wait_options.cancellation entry.options
  let expiry ~now entry = Wait_options.expiry ~now entry.options
end

module Registration = struct
  module State = struct
    type t = Queued | Watching | Completed of Wait_result.t | Invalid_fd
  end

  module Progress = struct
    type t = { mutable state : State.t }

    let pending t =
      match t.state with Queued | Watching -> true | Completed _ | Invalid_fd -> false
  end

  type t = {
    token : int;
    fd : int;
    direction : Direction.t;
    owner : Wait_owner.t;
    options : Wait_options.t;
    progress : Progress.t;
  }

  let batch_size = 64

  let stage requests i wait =
    let offset = i * 3 in
    array_set requests offset wait.fd;
    array_set requests (offset + 1) (Direction.events wait.direction);
    array_set requests (offset + 2) wait.token;
    wait.progress.state <- Watching

  let cancellation entry = Wait_options.cancellation entry.options

  let expiry ~now entry =
    match entry.progress.state with
    | Watching -> Wait_options.expiry ~now entry.options
    | _ -> None

  let unregister wait =
    match wait.progress.state with
    | Watching -> raw_poller_unwatch wait.fd (Direction.events wait.direction) wait.token
    | Queued | Completed _ | Invalid_fd -> ()
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
    mutable condition_waiters : Condition_wait.t list;
    mutable queued_watches : Registration.t list;
    mutable steps_since_poll : int;
    mutable next_tok : int;
    poll_buf : int array;
    watch_buf : int array;
  }

  let create () : t =
    {
      active = None;
      ready = [];
      ready_rev = [];
      timers = [];
      io_waiters = [];
      condition_waiters = [];
      queued_watches = [];
      steps_since_poll = 0;
      next_tok = 1;
      poll_buf = array_make Registration.batch_size 0;
      watch_buf = array_make (Registration.batch_size * 3) 0;
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
    match s.active, s.ready, s.ready_rev, s.timers, s.io_waiters, s.condition_waiters with
    | None, [], [], [], [], [] -> true
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

let next_deadline (s : Scheduler.t) =
  let rec earliest deadline_of current = function
    | [] -> current
    | entry :: rest ->
        let next =
          match current, deadline_of entry with
          | Some a, Some b -> Some (Deadline.earlier a b)
          | None, (Some _ as deadline) -> deadline
          | _, None -> current
        in
        earliest deadline_of next rest
  in
  let earliest_timer = earliest (fun (t : Timer.t) -> Some t.deadline) None s.timers in
  let earliest_io =
    earliest (fun (t : Registration.t) -> t.options.deadline) earliest_timer s.io_waiters in
  earliest (fun (t : Condition_wait.t) -> t.options.deadline) earliest_io s.condition_waiters

let next_timer_timeout_ms s =
  match next_deadline s with
  | None -> -1
  | Some deadline -> Deadline.remaining_ms ~now:(raw_monotonic_ns ()) deadline

let rec remove_io_waiter tok acc (waits : Registration.t list) = match waits with
  | [] -> (None, acc)
  | e :: rest ->
      if e.token = tok then (Some e, rev_append acc rest)
      else remove_io_waiter tok (e :: acc) rest

let wake_owner s = function
  | Wait_owner.Main -> ()
  | Task task -> Scheduler.push s task

let complete_wait s (entry : Registration.t) state =
  entry.progress.state <- state;
  wake_owner s entry.owner

let complete_condition s (entry : Condition_wait.t) result =
  entry.progress.result <- Some result;
  wake_owner s entry.owner

let drop_waiters decide resolve waits =
  let rec drop = function
    | [] -> None
    | entry :: rest ->
        match decide entry with
        | None ->
            (match drop rest with
             | None -> None
             | Some rest -> Some (entry :: rest))
        | Some result ->
            resolve entry result;
            (match drop rest with None -> Some rest | updated -> updated)
  in
  drop waits

let drop_io (s : Scheduler.t) decide =
  let resolve entry result =
    Registration.unregister entry;
    complete_wait s entry (Registration.State.Completed result)
  in
  match drop_waiters decide resolve s.io_waiters with
  | None -> false
  | Some remaining -> s.io_waiters <- remaining; true

let drop_conditions (s : Scheduler.t) decide =
  match drop_waiters decide (complete_condition s) s.condition_waiters with
  | None -> false
  | Some remaining -> s.condition_waiters <- remaining; true

let poll_watches (s : Scheduler.t) timeout_ms =
  let rec stage count (queued : Registration.t list) =
    match queued with
    | [] -> count, []
    | _ when count = Registration.batch_size -> count, queued
    | entry :: rest ->
        match entry.progress.state with
        | Queued ->
            Registration.stage s.watch_buf count entry;
            stage (count + 1) rest
        | Watching | Completed _ | Invalid_fd -> stage count rest
  in
  match s.queued_watches with
  | [] ->
      if timeout_ms > 0 || s.io_waiters <> [] then raw_poller_wait s.poll_buf timeout_ms
      else 0
  | queued ->
      let count, pending = stage 0 (rev_append queued []) in
      s.queued_watches <- rev_append pending [];
      let timeout_ms = if pending <> [] then 0 else timeout_ms in
      raw_poller_wait_adding s.watch_buf count s.poll_buf timeout_ms

let sched_poll (s : Scheduler.t) timeout_ms =
  s.steps_since_poll <- 0;
  drain_timers s;
  let removed_io = drop_io s Registration.cancellation in
  let removed_conditions = drop_conditions s Condition_wait.cancellation in
  let removed = removed_io || removed_conditions in
  let timeout_ms = if removed || Scheduler.has_ready s then 0 else timeout_ms in
  let n = poll_watches s timeout_ms in
  for i = 0 to n - 1 do
    let ready = array_get s.poll_buf i in
    let tok, state =
      if ready < 0 then 0 - ready, Registration.State.Invalid_fd
      else ready, Registration.State.Completed Wait_result.Ready in
    let found, rest = remove_io_waiter tok [] s.io_waiters in
    s.io_waiters <- rest;
    match found with
    | None -> ()
    | Some entry -> complete_wait s entry state
  done;
  let expired =
    match s.io_waiters, s.condition_waiters with
    | [], [] -> false
    | _ ->
        let now = raw_monotonic_ns () in
        let io = drop_io s (Registration.expiry ~now) in
        let conditions = drop_conditions s (Condition_wait.expiry ~now) in
        io || conditions in
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
  s.steps_since_poll <- s.steps_since_poll + 1;
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
  let progressed =
    if s.ready = [] || s.steps_since_poll >= Registration.batch_size then
      let timeout = if Scheduler.has_ready s then 0 else next_timer_timeout_ms s in
      sched_poll s timeout
    else false in
  match Scheduler.pop s with
  | Some next ->
      step_task s next;
      true
  | None -> progressed || s.io_waiters <> [] || next_deadline s <> None

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

let wait_owner (s : Scheduler.t) =
  match s.active with
  | Some task -> Wait_owner.Task task
  | None when raw_is_main () -> Wait_owner.Main
  | None -> Scheduler.release_if_idle s; raise_invalid ()

let fd_wait ?timeout_ms ?cancel fd direction =
  raw_can_yield ();
  let options = Wait_options.create ~invalid_timeout:"Fiber.fd_wait: negative timeout"
      timeout_ms cancel in
  let s = Scheduler.current () in
  let owner = wait_owner s in
  if Wait_options.cancellation options <> None then begin
    Scheduler.release_if_idle s;
    Wait_result.Cancelled
  end else begin
    if fd < 0 || fd > 0x7fffffff then begin
      Scheduler.release_if_idle s;
      raise_invalid ()
    end;
    let tok = s.next_tok in
    s.next_tok <- tok + 1;
    let progress : Registration.Progress.t = { state = Queued } in
    let wait : Registration.t =
      { token = tok; fd; direction; owner; options; progress } in
    s.io_waiters <- wait :: s.io_waiters;
    s.queued_watches <- wait :: s.queued_watches;
    (match owner with
     | Task _ -> ignore (raw_suspend Command.Wait_fd)
     | Main ->
         while Registration.Progress.pending progress do
           ignore (sched_step s)
         done;
         Scheduler.release_if_idle s);
    match progress.state with
    | Completed result -> result
    | Invalid_fd | Queued | Watching -> raise_invalid ()
  end

let fd_wait_read fd = ignore (fd_wait fd Direction.Read)
let fd_wait_write fd = ignore (fd_wait fd Direction.Write)

module Condition = struct
  type t = Condition_key.t

  let create = Condition_key.create

  let wait ?timeout_ms ?cancel key =
    raw_can_yield ();
    let options =
      Wait_options.create ~invalid_timeout:"Fiber.Condition.wait: negative timeout"
        timeout_ms cancel in
    let s = Scheduler.current () in
    let owner = wait_owner s in
    match Wait_options.cancellation options with
    | Some result -> Scheduler.release_if_idle s; result
    | None ->
        let progress : Condition_wait.Progress.t = { result = None } in
        let entry : Condition_wait.t = { key; owner; options; progress } in
        s.condition_waiters <- entry :: s.condition_waiters;
        (match owner with
         | Task _ -> ignore (raw_suspend Command.Park)
         | Main ->
             while progress.result = None do
               if not (sched_step s) then begin
                 ignore (drop_conditions s (fun entry ->
                   if entry.progress == progress then Some Wait_result.Cancelled else None));
                 Scheduler.release_if_idle s;
                 raise_invalid ()
               end
             done;
             Scheduler.release_if_idle s);
        match progress.result with Some result -> result | None -> raise_invalid ()

  let notify ~all key =
    match Scheduler.existing () with
    | None -> ()
    | Some s ->
        let matches (entry : Condition_wait.t) = entry.key == key in
        ignore (drop_conditions s (fun entry ->
          if matches entry then Condition_wait.cancellation entry else None));
        if all then
          ignore (drop_conditions s (fun entry ->
            if matches entry then Some Wait_result.Ready else None))
        else
          let rec oldest found = function
            | [] -> found
            | entry :: rest ->
                oldest (if matches entry then Some entry else found) rest
          in
          match oldest None s.condition_waiters with
          | None -> ()
          | Some first ->
              ignore (drop_conditions s (fun entry ->
                if entry == first then Some Wait_result.Ready else None))

  let signal key = notify ~all:false key
  let broadcast key = notify ~all:true key
end

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
