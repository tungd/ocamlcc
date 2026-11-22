(* TDD contract test for bootstrap/unix/ covering shared filesystem and process operations. *)

let () =
  let base =
    Printf.sprintf "/tmp/ocamlcc_bunix_test_%d" (Random.self_init (); Random.int 1000000)
  in
  Sys.mkdir base 0o755;

  (* 1. openfile + close + lstat on regular file and directory *)
  let fpath = Filename.concat base "hello.txt" in
  let fd = Unix.openfile fpath [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644 in
  Unix.close fd;
  Unix.chmod fpath 0o640;
  Sys_util.write_if_changed fpath "updated";
  let st_f = Unix.lstat fpath in
  assert (st_f.Unix.st_kind = Unix.S_REG);
  assert (st_f.Unix.st_perm = 0o640);
  assert (Sys_util.read_file fpath = "updated");
  let st_d = Unix.lstat base in
  assert (st_d.Unix.st_kind = Unix.S_DIR);

  (* 2. lstat on missing path raises Unix_error (ENOENT, _, _) *)
  let missing_ok =
    match Unix.lstat (Filename.concat base "does_not_exist") with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
    | _ -> false
  in
  assert missing_ok;

  (* 3. pipe ~cloexec:true + in_channel_of_descr + create_process + waitpid (success) *)
  let rfd, wfd = Unix.pipe ~cloexec:true () in
  let ic = Unix.in_channel_of_descr rfd in
  let pid =
    Unix.create_process "/bin/sh" [| "/bin/sh"; "-c"; "printf 'unix-ok'" |]
      Unix.stdin wfd Unix.stderr
  in
  Unix.close wfd;
  let out = In_channel.input_all ic in
  close_in ic;
  let wpid, status = Unix.waitpid [] pid in
  assert (wpid = pid);
  assert (status = Unix.WEXITED 0);
  assert (out = "unix-ok");

  (* 4. create_process + waitpid non-zero exit *)
  let pid2 =
    Unix.create_process "/bin/sh" [| "/bin/sh"; "-c"; "exit 7" |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  let _, status2 = Unix.waitpid [] pid2 in
  assert (status2 = Unix.WEXITED 7);

  (* 5. create_process on missing binary raises Unix_error + non-empty error_message *)
  let missing_exec_ok =
    match
      Unix.create_process "/nonexistent_ocamlcc_cmd_xyz"
        [| "/nonexistent_ocamlcc_cmd_xyz" |] Unix.stdin Unix.stdout Unix.stderr
    with
    | exception Unix.Unix_error (err, _, _) ->
        String.length (Unix.error_message err) > 0
    | _ -> false
  in
  assert missing_exec_ok;

  (* 6. unlink + rmdir *)
  Unix.unlink fpath;
  Unix.rmdir base;
  let gone_ok =
    match Unix.lstat base with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
    | _ -> false
  in
  assert gone_ok;
  print_endline "bootstrap_unix_test: PASS"
