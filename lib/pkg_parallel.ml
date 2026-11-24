let default_jobs () =
  let env =
    match Sys.getenv_opt "OCPKG_JOBS" with
    | Some s -> (match int_of_string_opt (String.trim s) with Some n when n >= 1 -> Some n | _ -> None)
    | None -> None
  in
  match env with
  | Some n -> n
  | None -> max 1 (Domain.recommended_domain_count ())

let rec retry_eintr f =
  try f () with Unix.Unix_error (Unix.EINTR, _, _) -> retry_eintr f

let rec write_all fd bytes off len =
  if len > 0 then
    let wrote = retry_eintr (fun () -> Unix.write fd bytes off len) in
    write_all fd bytes (off + wrote) (len - wrote)

module Pool = struct
  type t = {
    jobs : int;
    pipe : (Unix.file_descr * Unix.file_descr) option;
  }

  let create n =
    let jobs = max 1 n in
    if jobs <= 1 || Sys.win32 then { jobs = 1; pipe = None }
    else
      let read_fd, write_fd = Unix.pipe ~cloexec:true () in
      Unix.set_nonblock read_fd;
      let tokens = Bytes.make jobs 't' in
      write_all write_fd tokens 0 jobs;
      { jobs; pipe = Some (read_fd, write_fd) }

  let jobs t = t.jobs

  let close t =
    match t.pipe with
    | None -> ()
    | Some (r, w) ->
        (try Unix.close r with Unix.Unix_error _ -> ());
        (try Unix.close w with Unix.Unix_error _ -> ())

  let try_acquire t =
    match t.pipe with
    | None -> false
    | Some (read_fd, _) ->
        let buf = Bytes.create 1 in
        let rec attempt () =
          match Unix.read read_fd buf 0 1 with
          | 1 -> true
          | 0 -> false
          | _ -> false
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> attempt ()
          | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> false
        in
        attempt ()

  let release t =
    match t.pipe with
    | None -> ()
    | Some (_, write_fd) ->
        let buf = Bytes.make 1 't' in
        write_all write_fd buf 0 1
end

type ('a, 'e) message =
  | Event of 'e
  | Done of ('a, string) result * Digest_index.delta option

let encode_int32_be buf n =
  Bytes.set buf 0 (Char.chr ((n lsr 24) land 0xff));
  Bytes.set buf 1 (Char.chr ((n lsr 16) land 0xff));
  Bytes.set buf 2 (Char.chr ((n lsr 8) land 0xff));
  Bytes.set buf 3 (Char.chr (n land 0xff))

let decode_int32_be s =
  (Char.code s.[0] lsl 24)
  lor (Char.code s.[1] lsl 16)
  lor (Char.code s.[2] lsl 8)
  lor Char.code s.[3]

let send_frame fd v =
  let payload = Marshal.to_bytes v [] in
  let len = Bytes.length payload in
  let header = Bytes.create 4 in
  encode_int32_be header len;
  write_all fd header 0 4;
  write_all fd payload 0 len

type ('a, 'e) worker = {
  id : int;
  pid : int;
  fd : Unix.file_descr;
  buf : Buffer.t;
  owns_token : bool;
  mutable outcome : (('a, string) result * Digest_index.delta option) option;
}

let drain_frames w ~on_event =
  let rec loop () =
    let avail = Buffer.length w.buf in
    if avail >= 4 then
      let len = decode_int32_be (Buffer.sub w.buf 0 4) in
      if avail >= 4 + len then begin
        let payload = Buffer.sub w.buf 4 len in
        let rest = Buffer.sub w.buf (4 + len) (avail - 4 - len) in
        Buffer.clear w.buf;
        Buffer.add_string w.buf rest;
        (match (Marshal.from_string payload 0 : ('a, 'e) message) with
         | Event ev -> on_event w.id ev
         | Done (res, delta) -> w.outcome <- Some (res, delta));
        loop ()
      end
  in
  loop ()

let format_unexpected_exit = function
  | Unix.WEXITED code -> Printf.sprintf "worker process exited with status %d" code
  | Unix.WSIGNALED sig_num -> Printf.sprintf "worker process terminated by signal %d" sig_num
  | Unix.WSTOPPED sig_num -> Printf.sprintf "worker process stopped by signal %d" sig_num

let insert_sorted x xs =
  let rec go = function
    | [] -> [x]
    | y :: rest as l -> if x <= y then x :: l else y :: go rest
  in
  go xs

let run_dag
    ?pool
    ?(held = false)
    ?index
    ?(on_start = fun _ -> ())
    ?(on_event = fun _ _ -> ())
    ?(on_done = fun _ _ -> ())
    ~deps
    ~prepare
    n =
  if n = 0 then Ok [||]
  else
    let owned_pool, pool =
      match pool with
      | Some p -> None, p
      | None -> let p = Pool.create (default_jobs ()) in Some p, p
    in
    Fun.protect ~finally:(fun () -> Option.iter Pool.close owned_pool) (fun () ->
      let indeg = Array.make n 0 in
      let rev = Array.make n [] in
      for i = 0 to n - 1 do
        let ds = List.sort_uniq Int.compare (deps i) in
        indeg.(i) <- List.length ds;
        List.iter (fun d -> rev.(d) <- i :: rev.(d)) ds
      done;
      let ready = ref [] in
      for i = n - 1 downto 0 do
        if indeg.(i) = 0 then ready := i :: !ready
      done;
      let results = Array.make n None in
      let unblock i =
        List.iter (fun nxt ->
          indeg.(nxt) <- indeg.(nxt) - 1;
          if indeg.(nxt) = 0 then ready := insert_sorted nxt !ready)
          rev.(i)
      in
      let jobs = Pool.jobs pool in
      if jobs <= 1 || Sys.win32 then begin
        let rec loop () =
          match !ready with
          | [] -> Ok (Array.map Option.get results)
          | i :: rest ->
              ready := rest;
              match prepare i results with
              | Error _ as err -> err
              | Ok (`Ready value) ->
                  results.(i) <- Some value;
                  on_done i value;
                  unblock i;
                  loop ()
              | Ok (`Run fn) ->
                  on_start i;
                  match fn (on_event i) with
                  | Error _ as err -> err
                  | Ok value ->
                      results.(i) <- Some value;
                      on_done i value;
                      unblock i;
                      loop ()
        in
        loop ()
      end else begin
        let active : ('a, 'e) worker list ref = ref [] in
        let caller_token_in_use = ref false in
        let error : string option ref = ref None in
        let pending : (int * (('e -> unit) -> ('a, string) result)) option ref = ref None in
        let acquire_slot () =
          if held && not !caller_token_in_use then begin
            caller_token_in_use := true;
            Some false
          end else if Pool.try_acquire pool then
            Some true
          else
            None
        in
        let release_slot owns_token =
          if owns_token then Pool.release pool
          else caller_token_in_use := false
        in
        let spawn i fn owns_token =
          flush_all ();
          let read_fd, write_fd = Unix.pipe ~cloexec:true () in
          match Unix.fork () with
          | 0 ->
              List.iter (fun w -> try Unix.close w.fd with Unix.Unix_error _ -> ()) !active;
              (try Unix.close read_fd with Unix.Unix_error _ -> ());
              Option.iter Digest_index.reset_updates index;
              let res =
                try fn (fun ev -> send_frame write_fd (Event ev))
                with exn -> Error (Printexc.to_string exn)
              in
              let delta = Option.map Digest_index.take_updates index in
              (try send_frame write_fd (Done (res, delta)) with _ -> ());
              (try Unix.close write_fd with Unix.Unix_error _ -> ());
              Unix._exit 0
          | pid ->
              (try Unix.close write_fd with Unix.Unix_error _ -> ());
              let w =
                { id = i; pid; fd = read_fd; buf = Buffer.create 4096;
                  owns_token; outcome = None }
              in
              active := w :: !active;
              on_start i
          | exception exn ->
              (try Unix.close read_fd with Unix.Unix_error _ -> ());
              (try Unix.close write_fd with Unix.Unix_error _ -> ());
              release_slot owns_token;
              raise exn
        in
        let cleanup () =
          List.iter (fun w ->
            (try Unix.close w.fd with Unix.Unix_error _ -> ());
            (try ignore (retry_eintr (fun () -> Unix.waitpid [] w.pid)) with Unix.Unix_error _ -> ());
            release_slot w.owns_token)
            !active;
          active := []
        in
        Fun.protect ~finally:cleanup (fun () ->
          let rec dispatch () =
            if !error = None then
              match !pending with
              | Some (i, fn) -> (
                  match acquire_slot () with
                  | Some owns_token ->
                      pending := None;
                      spawn i fn owns_token;
                      dispatch ()
                  | None -> ())
              | None -> (
                  match !ready with
                  | [] -> ()
                  | i :: rest -> (
                      ready := rest;
                      match prepare i results with
                      | Error msg -> error := Some msg
                      | Ok (`Ready value) ->
                          results.(i) <- Some value;
                          on_done i value;
                          unblock i;
                          dispatch ()
                      | Ok (`Run fn) -> (
                          match acquire_slot () with
                          | Some owns_token ->
                              spawn i fn owns_token;
                              dispatch ()
                          | None ->
                              pending := Some (i, fn))))
          in
          let scratch = Bytes.create 8192 in
          let rec wait_loop () =
            dispatch ();
            match !active with
            | [] -> (
                match !error with
                | Some msg -> Error msg
                | None ->
                    if !pending <> None || !ready <> [] then begin
                      Unix.sleepf 0.005;
                      wait_loop ()
                    end else
                      Ok (Array.map Option.get results))
            | workers ->
                let fds = List.map (fun w -> w.fd) workers in
                let readable, _, _ = retry_eintr (fun () -> Unix.select fds [] [] (-1.0)) in
                List.iter (fun fd ->
                  match List.find_opt (fun w -> w.fd = fd) !active with
                  | None -> ()
                  | Some w ->
                      let nread =
                        try retry_eintr (fun () -> Unix.read fd scratch 0 (Bytes.length scratch))
                        with Unix.Unix_error _ -> 0
                      in
                      if nread > 0 then begin
                        Buffer.add_subbytes w.buf scratch 0 nread;
                        drain_frames w ~on_event:(fun id ev ->
                          if !error = None then on_event id ev)
                      end else begin
                        (try Unix.close w.fd with Unix.Unix_error _ -> ());
                        let _, status = retry_eintr (fun () -> Unix.waitpid [] w.pid) in
                        active := List.filter (fun x -> x != w) !active;
                        release_slot w.owns_token;
                        match w.outcome with
                        | Some (Ok value, delta) ->
                            (match index, delta with
                             | Some idx, Some d -> Digest_index.merge_updates idx d
                             | _ -> ());
                            if !error = None then begin
                              results.(w.id) <- Some value;
                              on_done w.id value;
                              unblock w.id
                            end
                        | Some (Error msg, delta) ->
                            (match index, delta with
                             | Some idx, Some d -> Digest_index.merge_updates idx d
                             | _ -> ());
                            if !error = None then error := Some msg
                        | None ->
                            if !error = None then error := Some (format_unexpected_exit status)
                      end)
                  readable;
                wait_loop ()
          in
          wait_loop ())
      end)

let map
    ?pool
    ?held
    ?index
    ?on_start
    ?on_event
    ?on_done
    tasks =
  let arr = Array.of_list tasks in
  let n = Array.length arr in
  Result.map Array.to_list
    (run_dag ?pool ?held ?index ?on_start ?on_event ?on_done
       ~deps:(fun _ -> [])
       ~prepare:(fun i _ -> Ok (`Run arr.(i)))
       n)
