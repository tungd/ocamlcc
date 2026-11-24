let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path data =
  let out = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr out) (fun () ->
      output_string out data;
      close_out out)

let replace_file ?mode path data =
  let tmp, out =
    Filename.open_temp_file ~mode:[Open_binary] ~perms:0o666
      ~temp_dir:(Filename.dirname path)
      (Printf.sprintf ".ocamlcc-%d-" (Unix.getpid ())) ".tmp"
  in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr out;
      try Unix.unlink tmp with Unix.Unix_error (Unix.ENOENT, _, _) -> ())
    (fun () ->
      output_string out data;
      close_out out;
      Option.iter (Unix.chmod tmp) mode;
      Sys.rename tmp path)

let write_atomic path data = replace_file path data

let write_if_changed path data =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> write_atomic path data
  | { Unix.st_kind = Unix.S_REG; st_perm; _ } ->
      if read_file path <> data then replace_file ~mode:st_perm path data
  | _ -> write_atomic path data

let rec mkdir_p dir =
  if dir <> "" && dir <> "." && not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    try Sys.mkdir dir 0o755 with Sys_error _ -> ()
  end

let rec rm_rf path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun e -> rm_rf (Filename.concat path e)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let capture_process prog args stream =
  let read_fd, write_fd = Unix.pipe ~cloexec:true () in
  let stdout, stderr =
    match stream with
    | `Stdout -> (write_fd, Unix.stderr)
    | `Stderr stdout_fd -> (stdout_fd, write_fd)
  in
  let channel = Unix.in_channel_of_descr read_fd in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      match
        Fun.protect ~finally:(fun () -> Unix.close write_fd) (fun () ->
            Unix.create_process prog (Array.of_list (prog :: args))
              Unix.stdin stdout stderr)
      with
      | exception Unix.Unix_error (err, _, _) ->
          Error (Printf.sprintf "cannot start command `%s`: %s" prog (Unix.error_message err))
      | pid ->
          let output = In_channel.input_all channel in
          let _, status = Unix.waitpid [] pid in
          Ok (status, String.trim output))

let run_cmd ~verbose ?stdout_file prog args =
  if verbose then
    Printf.eprintf "+ %s %s\n%!" prog (String.concat " " args);
  let run stdout_fd = capture_process prog args (`Stderr stdout_fd) in
  let result =
    match stdout_file with
    | None -> run Unix.stdout
    | Some path ->
        let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> run fd)
  in
  match result with
  | Error _ as error -> error
  | Ok (Unix.WEXITED 0, _) -> Ok ()
  | Ok (Unix.WEXITED c, msg) ->
      Error
        (Printf.sprintf "command `%s` exited with %d%s" prog c
           (if msg = "" then "" else ": " ^ msg))
  | Ok ((Unix.WSIGNALED s | Unix.WSTOPPED s), _) ->
      Error (Printf.sprintf "command `%s` terminated by signal %d" prog s)

let capture_cmd prog args =
  match capture_process prog args `Stdout with
  | Error _ as error -> error
  | Ok (Unix.WEXITED 0, output) -> Ok output
  | Ok _ -> Error (Printf.sprintf "command `%s` failed" prog)

let find_in_path exe =
  let path_var = try Sys.getenv "PATH" with Not_found -> "" in
  let dirs = String.split_on_char ':' path_var in
  List.find_map
    (fun d ->
      let p = Filename.concat d exe in
      if Sys.file_exists p && not (Sys.is_directory p) then Some p else None)
    dirs

module Result_syntax = Result.Syntax
module Option_syntax = Option.Syntax
