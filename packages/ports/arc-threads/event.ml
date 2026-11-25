(* Synchronous inter-thread communication over channels, in the style of
   John Reppy's Concurrent ML.  One global lock serializes offer queues
   and commits; each [sync] waits on its own condition under that lock.
   Offers carry their owner's commit and liveness closures so channels
   stay homogeneous while branches translate payloads to results. *)

type 'a channel = {
  mutable sends : 'a slot list; (* FIFO queues under [event_lock] *)
  mutable receives : 'a slot list;
}

and 'a slot = {
  sl_channel : 'a channel;
  sl_payload : 'a option; (* [Some v] for send offers *)
  sl_sync_id : int;
  sl_can_commit : unit -> bool;
  sl_commit : 'a -> unit;
  mutable sl_live : bool;
}

type +'a event = unit -> 'a branch list

and 'a branch = {
  br_act :
    register:((unit -> unit) -> unit) ->
    can_commit:(unit -> bool) ->
    commit:('a -> unit) ->
    sync_id:int ->
    bool;
  br_aborts : (unit -> unit) list;
}

let event_lock = Mutex.create ()
let sync_counter = ref 0

let fresh_sync_id () =
  incr sync_counter;
  !sync_counter

let unlink_send ch s = ch.sends <- List.filter (fun x -> x != s) ch.sends

let unlink_receive ch r =
  ch.receives <- List.filter (fun x -> x != r) ch.receives

let new_channel () = { sends = []; receives = [] }

let send (ch : 'a channel) (v : 'a) : unit event =
 fun () ->
  [ {
      br_act =
        (fun ~register ~can_commit ~commit ~sync_id ->
          let rec scan = function
            | [] ->
                let slot =
                  {
                    sl_channel = ch;
                    sl_payload = Some v;
                    sl_sync_id = sync_id;
                    sl_can_commit = can_commit;
                    sl_commit = (fun _ -> commit ());
                    sl_live = true;
                  }
                in
                register (fun () ->
                    if slot.sl_live then begin
                      unlink_send ch slot;
                      slot.sl_live <- false
                    end);
                ch.sends <- ch.sends @ [ slot ];
                false
            | r :: rest ->
                if not r.sl_live then scan rest
                else if r.sl_sync_id = sync_id then scan rest
                else if not (r.sl_can_commit ()) then begin
                  unlink_receive ch r;
                  r.sl_live <- false;
                  scan rest
                end
                else begin
                  unlink_receive ch r;
                  r.sl_live <- false;
                  r.sl_commit v;
                  commit ();
                  true
                end
          in
          scan ch.receives);
      br_aborts = [];
    } ]

let receive (ch : 'a channel) : 'a event =
 fun () ->
  [ {
      br_act =
        (fun ~register ~can_commit ~commit ~sync_id ->
          let rec scan = function
            | [] ->
                let slot =
                  {
                    sl_channel = ch;
                    sl_payload = None;
                    sl_sync_id = sync_id;
                    sl_can_commit = can_commit;
                    sl_commit = (fun x -> commit x);
                    sl_live = true;
                  }
                in
                register (fun () ->
                    if slot.sl_live then begin
                      unlink_receive ch slot;
                      slot.sl_live <- false
                    end);
                ch.receives <- ch.receives @ [ slot ];
                false
            | s :: rest ->
                if not s.sl_live then scan rest
                else if s.sl_sync_id = sync_id then scan rest
                else if not (s.sl_can_commit ()) then begin
                  unlink_send ch s;
                  s.sl_live <- false;
                  scan rest
                end
                else begin
                  match s.sl_payload with
                  | None -> scan rest
                  | Some v ->
                      unlink_send ch s;
                      s.sl_live <- false;
                      s.sl_commit v;
                      commit v;
                      true
                end
          in
          scan ch.sends);
      br_aborts = [];
    } ]

let always v : 'a event =
 fun () ->
  [ {
      br_act =
        (fun ~register:_ ~can_commit:_ ~commit ~sync_id:_ ->
          commit v;
          true);
      br_aborts = [];
    } ]

let choose (evs : 'a event list) : 'a event =
 fun () -> List.concat (List.map (fun ev -> ev ()) evs)

let wrap (ev : 'a event) (f : 'a -> 'b) : 'b event =
 fun () ->
  List.map
    (fun b ->
      {
        br_act =
          (fun ~register ~can_commit ~commit ~sync_id ->
            b.br_act ~register ~can_commit
              ~commit:(fun v -> commit (f v))
              ~sync_id);
        br_aborts = b.br_aborts;
      })
    (ev ())

let wrap_abort (ev : 'a event) (f : unit -> unit) : 'a event =
  let fired = ref false in
  let once () =
    if not !fired then begin
      fired := true;
      f ()
    end
  in
  fun () -> List.map (fun b -> { b with br_aborts = once :: b.br_aborts }) (ev ())

let guard (f : unit -> 'a event) : 'a event = fun () -> (f ()) ()

type 'a outcome = { oc_result : 'a option; oc_chosen : int }

let run ~block (ev : 'a event) =
  let branches = ev () in
  let committed = ref false in
  let result = ref None in
  let chosen = ref (-1) in
  let cond = Condition.create () in
  let cleanups = ref [] in
  let sync_id = fresh_sync_id () in
  let can_commit () = not !committed in
  let commit i v =
    if not !committed then begin
      committed := true;
      result := Some v;
      chosen := i;
      Condition.broadcast cond
    end
  in
  Mutex.lock event_lock;
  let rec loop i = function
    | [] ->
        if block then
          while not !committed do
            Condition.wait cond event_lock
          done
    | b :: rest ->
        if not !committed then begin
          let done_ =
            b.br_act
              ~register:(fun cleanup -> cleanups := cleanup :: !cleanups)
              ~can_commit ~commit:(commit i) ~sync_id
          in
          if not done_ then loop (i + 1) rest
        end
  in
  loop 0 branches;
  let outcome = { oc_result = !result; oc_chosen = !chosen } in
  List.iter (fun cleanup -> cleanup ()) !cleanups;
  Mutex.unlock event_lock;
  (branches, outcome)

let aborts_of branches chosen =
  List.iteri
    (fun i b -> if i <> chosen then List.iter (fun f -> f ()) b.br_aborts)
    branches

let sync (ev : 'a event) : 'a =
  let branches, outcome = run ~block:true ev in
  aborts_of branches outcome.oc_chosen;
  match outcome.oc_result with
  | Some v -> v
  | None -> assert false

let poll (ev : 'a event) : 'a option =
  let branches, outcome = run ~block:false ev in
  (match outcome.oc_result with
  | Some _ -> aborts_of branches outcome.oc_chosen
  | None -> List.iter (fun b -> List.iter (fun f -> f ()) b.br_aborts) branches);
  outcome.oc_result

let select (evs : 'a event list) : 'a = sync (choose evs)
