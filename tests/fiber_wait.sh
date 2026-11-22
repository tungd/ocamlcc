#!/bin/sh
set -eu

compiler=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/fixture.ml" <<'ML'
module F = Stdlib.Fiber

external monotonic_ns : unit -> int = "ocamlcc_monotonic_ns"

let with_pipe f =
  let reader, writer = F.pipe () in
  Fun.protect ~finally:(fun () -> F.fd_close reader; F.fd_close writer)
    (fun () -> f reader writer)

let send fd =
  assert (F.fd_write fd (Bytes.of_string "x") 0 1 = 1)

let receive fd =
  let buffer = Bytes.create 1 in
  assert (F.fd_read fd buffer 0 1 = 1 && Bytes.get buffer 0 = 'x')

let test_step_ready () =
  assert (not (F.step_ready ()));
  let count = ref 0 in
  let bump () = incr count in
  let first = F.spawn (fun () -> bump (); F.yield (); bump ()) in
  let second = F.spawn bump in
  assert (F.step_ready () && !count = 1);
  assert (F.step_ready () && !count = 2);
  assert (F.step_ready () && !count = 3);
  assert (not (F.step_ready ()));
  F.await first;
  F.await second;
  with_pipe (fun reader writer ->
    let waiter = F.spawn (fun () -> F.fd_wait reader Read) in
    assert (F.step_ready ());
    send writer;
    assert (not (F.step_ready ()));
    assert (F.await waiter = F.Wait_result.Ready);
    receive reader);
  let nested = F.spawn (fun () ->
    match F.step_ready () with exception Invalid_argument _ -> true | _ -> false) in
  assert (F.step_ready () && F.await nested)

let test_main_sleep ~already_registered =
  with_pipe (fun reader _ ->
    let cancel = F.Cancel.create () in
    let watcher = F.spawn (fun () -> F.fd_wait ~cancel reader Read) in
    F.yield ();
    if already_registered then F.yield ();
    let start = monotonic_ns () in
    F.sleep_ms 2;
    assert (monotonic_ns () - start >= 2_000_000);
    F.Cancel.cancel cancel;
    assert (F.await watcher = F.Wait_result.Cancelled))

let test_conditions () =
  let condition = F.Condition.create () in
  let other = F.Condition.create () in
  let cancel = F.Cancel.create () in
  let cancelled = F.spawn (fun () -> F.Condition.wait ~cancel condition) in
  let first = F.spawn (fun () -> F.Condition.wait condition) in
  let peer_awake = ref false and other_awake = ref false in
  let observe condition awake =
    F.spawn (fun () ->
      let result = F.Condition.wait condition in
      awake := true;
      result)
  in
  let peer = observe condition peer_awake in
  let second_peer = F.spawn (fun () -> F.Condition.wait condition) in
  let untouched = observe other other_awake in
  F.run_all ();
  F.Cancel.cancel cancel;
  F.Condition.signal condition;
  assert (F.await cancelled = F.Wait_result.Cancelled);
  assert (F.await first = F.Wait_result.Ready);
  F.run_all ();
  assert (not !peer_awake && not !other_awake);
  F.Condition.broadcast condition;
  assert (F.await peer = F.Wait_result.Ready);
  assert (F.await second_peer = F.Wait_result.Ready && not !other_awake);
  F.Condition.signal other;
  assert (F.await untouched = F.Wait_result.Ready);
  let timeout = F.spawn (fun () -> F.Condition.wait ~timeout_ms:2 condition) in
  assert (F.await timeout = F.Wait_result.Timed_out);
  F.Condition.signal condition;
  assert (F.Condition.wait ~timeout_ms:0 condition = F.Wait_result.Timed_out);
  assert (F.Condition.wait ~cancel condition = F.Wait_result.Cancelled);
  let cancel_alone = F.Cancel.create () in
  let waiting = F.spawn (fun () -> F.Condition.wait ~cancel:cancel_alone condition) in
  F.run_all ();
  F.Cancel.cancel cancel_alone;
  assert (F.await waiting = F.Wait_result.Cancelled);
  let signaller = F.spawn (fun () -> F.Condition.signal condition) in
  assert (F.Condition.wait condition = F.Wait_result.Ready);
  F.await signaller;
  assert (match F.Condition.wait condition with
    | exception Invalid_argument _ -> true
    | _ -> false)

let () =
  test_step_ready ();
  test_main_sleep ~already_registered:false;
  test_main_sleep ~already_registered:true;
  test_conditions ();
  let typed = F.spawn (fun () -> "value", Bytes.of_string "payload") in
  let error = F.spawn (fun () -> raise Not_found) in
  let label, data = F.await typed in
  assert (label = "value" && Bytes.to_string data = "payload");
  assert (fst (F.await typed) = label);
  assert (match F.await error with exception Not_found -> true | _ -> false);
  with_pipe (fun reader writer ->
    assert (F.fd_wait ~timeout_ms:2 reader Read = Timed_out);
    send writer;
    assert (F.fd_wait ~timeout_ms:0 reader Read = Ready);
    receive reader);
  with_pipe (fun idle_reader _ ->
    let cancellation = F.Cancel.create () in
    let idle = F.spawn (fun () -> F.fd_wait ~cancel:cancellation idle_reader Read) in
    F.yield ();
    with_pipe (fun reader writer ->
      send writer;
      assert (F.fd_wait ~timeout_ms:max_int reader Read = Ready);
      receive reader);
    F.Cancel.cancel cancellation;
    assert (F.await idle = Cancelled));
  with_pipe (fun reader writer ->
    let cancellation = F.Cancel.create () in
    let cancelled = F.spawn (fun () -> F.fd_wait ~cancel:cancellation reader Read) in
    let peer = F.spawn (fun () -> F.fd_wait reader Read) in
    F.yield ();
    F.yield ();
    F.Cancel.cancel cancellation;
    assert (F.await cancelled = Cancelled);
    assert (F.fd_wait ~cancel:cancellation reader Read = Cancelled);
    send writer;
    assert (F.await peer = Ready);
    receive reader;
    assert (F.fd_wait writer Write = Ready));
  with_pipe (fun reader writer ->
    let closed = with_pipe (fun reader _ -> reader) in
    send writer;
    let invalid = F.spawn (fun () -> F.fd_wait closed Read) in
    let ready = List.init 70 (fun _ ->
      F.spawn (fun () -> F.fd_wait ~timeout_ms:0 reader Read)) in
    assert (match F.await invalid with exception Invalid_argument _ -> true | _ -> false);
    List.iter (fun task -> assert (F.await task = F.Wait_result.Ready)) ready;
    receive reader);
  F.run_all ();
  print_endline "Fiber descriptor waits: PASS"
ML

run_fixture() {
  python3 - "$1" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run([sys.argv[1]], timeout=15)
except subprocess.TimeoutExpired:
    print("Fiber wait fixture timed out", file=sys.stderr)
    sys.exit(124)
sys.exit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
PY
}

"$compiler" build "$work/fixture.ml" -o "$work/normal"
run_fixture "$work/normal"
"$compiler" build --single-thread-rc "$work/fixture.ml" -o "$work/single"
run_fixture "$work/single"
