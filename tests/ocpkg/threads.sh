#!/bin/sh
set -eu

runner=$1
case "$runner" in /*) ;; *) runner="$PWD/$runner";; esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OCPKG_CACHE="$scratch/cache"
cd "$scratch"
"$runner" init threads-test
"$runner" add arc-threads

cat > src/main.ml <<'ML'
(* Concurrency smoke test over the arc-threads port and the ARC
   runtime's pthread-backed Mutex/Condition. *)

let () =
  (* 1. mutex-protected counter across 8 threads *)
  let counter = ref 0 in
  let m = Mutex.create () in
  let workers =
    List.init 8 (fun _ ->
        Thread.create
          (fun () ->
            for _ = 1 to 1000 do
              Mutex.lock m;
              incr counter;
              Mutex.unlock m
            done)
          ())
  in
  List.iter Thread.join workers;
  Printf.printf "counter=%d\n" !counter;

  (* 2. condition rendezvous *)
  let cm = Mutex.create () in
  let cv = Condition.create () in
  let ready = ref false in
  let v = ref 0 in
  let producer =
    Thread.create
      (fun () ->
        Thread.delay 0.01;
        Mutex.lock cm;
        v := 42;
        ready := true;
        Condition.signal cv;
        Mutex.unlock cm)
      ()
  in
  Mutex.lock cm;
  while not !ready do
    Condition.wait cv cm
  done;
  let got = !v in
  Mutex.unlock cm;
  Thread.join producer;
  Printf.printf "cond=%d\n" got;

  (* 3. Event channel rendezvous *)
  let ch = Event.new_channel () in
  let sender = Thread.create (fun () -> Event.sync (Event.send ch 7)) () in
  let received = Event.sync (Event.receive ch) in
  Thread.join sender;
  Printf.printf "event=%d\n" received;

  (* 4. Domain.spawn/join result and exception *)
  let d = Domain.spawn (fun () -> 6 * 7) in
  Printf.printf "domain=%d\n" (Domain.join d);
  let boom : int Domain.t = Domain.spawn (fun () -> failwith "boom") in
  (match Domain.join boom with
  | _ -> print_endline "domain-exn=missed"
  | exception Failure msg -> Printf.printf "domain-exn=%s\n" msg);

  (* 5. Thread.Exit terminates silently *)
  let t = Thread.create (fun () -> raise Thread.Exit) () in
  Thread.join t;
  print_endline "exit=ok";

  (* 6. uncaught exception handler *)
  let seen = ref "" in
  Thread.set_uncaught_exception_handler (fun e ->
      seen := Printexc.to_string e);
  let t = Thread.create (fun () -> raise (Failure "caught")) () in
  Thread.join t;
  Printf.printf "uncaught=%s\n" !seen;

  (* 7. delay + yield *)
  let t = Thread.create (fun () -> Thread.delay 0.02; Thread.yield ()) () in
  Thread.join t;
  print_endline "delay=ok";

  (* 8. self and id *)
  Printf.printf "main-id=%d\n" (Thread.id (Thread.self ()));
  print_endline "done"
ML

"$runner" tidy
"$runner" vendor --offline
"$runner" run > out.txt
cat > expected.txt <<'EXPECT'
counter=8000
cond=42
event=7
domain=42
domain-exn=boom
exit=ok
uncaught=Failure("caught")
delay=ok
main-id=0
done
EXPECT
diff -u expected.txt out.txt
echo 'arc-threads concurrency: PASS'
