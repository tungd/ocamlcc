#!/bin/sh
set -eu

compiler=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/fixture.ml" <<'ML'
module F = Stdlib.Fiber

let with_pipe f =
  let reader, writer = F.pipe () in
  Fun.protect ~finally:(fun () -> F.fd_close reader; F.fd_close writer)
    (fun () -> f reader writer)

let send fd =
  assert (F.fd_write fd (Bytes.of_string "x") 0 1 = 1)

let receive fd =
  let buffer = Bytes.create 1 in
  assert (F.fd_read fd buffer 0 1 = 1 && Bytes.get buffer 0 = 'x')

let () =
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

"$compiler" build "$work/fixture.ml" -o "$work/normal"
"$work/normal"
"$compiler" build --single-thread-rc "$work/fixture.ml" -o "$work/single"
"$work/single"
