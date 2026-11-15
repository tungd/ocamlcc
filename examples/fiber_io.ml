open Stdlib

external arc_live : unit -> int = "ocamlcc_arc_live"

let rec write_all fd s off len =
  if off >= len then ()
  else
    let b = Bytes.of_string s in
    let n = Fiber.fd_write fd b off (len - off) in
    if n = -2 then (
      Fiber.fd_wait_write fd;
      write_all fd s off len)
    else if n > 0 then write_all fd s (off + n) len
    else failwith "write_all"

let rec read_all_to_buf fd scratch buf =
  let n = Fiber.fd_read fd scratch 0 (Bytes.length scratch) in
  if n = -2 then (
    Fiber.fd_wait_read fd;
    read_all_to_buf fd scratch buf)
  else if n > 0 then (
    Buffer.add_subbytes buf scratch 0 n;
    read_all_to_buf fd scratch buf)
  else if n = 0 then ()
  else failwith "read_all"

let test_pipe_io () =
  let rfd, wfd = Fiber.pipe () in
  let reader =
    Fiber.spawn (fun () ->
        let buf = Buffer.create 32 in
        let scratch = Bytes.create 4 in
        read_all_to_buf rfd scratch buf;
        Fiber.fd_close rfd;
        Buffer.contents buf)
  in
  let writer =
    Fiber.spawn (fun () ->
        Fiber.yield ();
        write_all wfd "hello " 0 6;
        Fiber.sleep_ms 4;
        write_all wfd "kqueue/epoll!" 0 13;
        Fiber.fd_close wfd)
  in
  Fiber.await writer;
  Fiber.await reader

let test_stdlib_abandon () =
  let w = Weak.create 1 in
  let run () =
    let xs = List.init 5 (fun i -> (i + 1, i + 10)) in
    Weak.set w 0 (Some (List.nth xs 4));
    let c =
      Fiber.create (fun () ->
          List.map
            (fun pair ->
              if fst pair = 3 then List.hd (Fiber.suspend [ fst pair + snd pair ])
              else fst pair + snd pair)
            xs)
    in
    let got = List.hd (Fiber.resume c ()) in
    let alive = if Weak.check w 0 then 1 else 0 in
    let not_done = if Fiber.is_done c then 0 else 1 in
    (got, alive, not_done)
  in
  let got, alive, not_done = run () in
  let after = if Weak.check w 0 then 1 else 0 in
  (got, alive, not_done, after)

let () =
  let live0 = arc_live () in
  let msg = test_pipe_io () in
  let len = String.length msg in
  Printf.printf "pipe=[%s] len=%d " msg len;
  let delta1 = arc_live () - live0 in
  Printf.printf "delta=%d\n" delta1;
  let got, alive_in, not_done, alive_after = test_stdlib_abandon () in
  let delta2 = arc_live () - live0 in
  Printf.printf "list_abandon=%d in=%d open=%d after=%d delta=%d\n" got alive_in
    not_done alive_after delta2
