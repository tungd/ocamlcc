open Sys_util
open Result_syntax

let key fields =
  let buffer = Buffer.create 512 in
  List.iter (fun (name, value) ->
    Printf.bprintf buffer "%d:%s%d:%s" (String.length name) name (String.length value) value)
    fields;
  Sha256.string (Buffer.contents buffer)

let fingerprints paths =
  let rec collect digests = function
    | [] -> Ok (List.rev digests)
    | path :: rest ->
        let* digest = Sha256.file path in
        collect ((path, Sha256.to_hex digest) :: digests) rest
  in
  collect [] paths

type entry = { directory : string; hit : bool }

let verify directory =
  let data = Filename.concat directory "data" in
  let seal = Filename.concat directory "digest" in
  match Unix.lstat seal with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
  | {Unix.st_kind = Unix.S_REG; _} ->
      (match Sha256.tree_hash data with
       | Ok digest -> Sha256.to_hex digest = String.trim (read_file seal)
       | Error _ -> false)
  | _ -> false

let ensure ~store ~key build =
  try
    mkdir_p store;
    let key = Sha256.to_hex key in
    let target = Filename.concat store key in
    let lock = Filename.concat store (key ^ ".lock") in
    let fd = Unix.openfile lock [Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC] 0o600 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      let data = Filename.concat target "data" in
      if verify target then Ok {directory = data; hit = true}
      else
        let staging = Filename.temp_dir ~temp_dir:store ".stage-" "" in
        Fun.protect ~finally:(fun () -> rm_rf staging) (fun () ->
          let temporary = Filename.concat staging "data" in
          Unix.mkdir temporary 0o700;
          let* () = build temporary in
          let+ digest = Sha256.tree_hash temporary in
          write_file (Filename.concat staging "digest") (Sha256.to_hex digest ^ "\n");
          rm_rf target;
          Unix.rename staging target;
          {directory = data; hit = false}))
  with
  | Sys_error msg -> Error msg
  | Unix.Unix_error (code, op, path) ->
      Error (Printf.sprintf "%s %s: %s" op path (Unix.error_message code))
