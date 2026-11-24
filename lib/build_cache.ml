open Sys_util
open Result_syntax

type hasher = {
  file : string -> (Sha256.t, string) result;
  tree : string -> (Sha256.t, string) result;
}

let default_hasher = { file = Sha256.file; tree = (fun path -> Sha256.tree_hash path) }

let key fields =
  let buffer = Buffer.create 512 in
  List.iter (fun (name, value) ->
    Printf.bprintf buffer "%d:%s%d:%s" (String.length name) name (String.length value) value)
    fields;
  Sha256.string (Buffer.contents buffer)

let fingerprints ?(hasher = default_hasher) paths =
  let rec collect digests = function
    | [] -> Ok (List.rev digests)
    | path :: rest ->
        let* digest = hasher.file path in
        collect ((path, Sha256.to_hex digest) :: digests) rest
  in
  collect [] paths

type entry = { directory : string; hit : bool }

let verify hasher directory =
  let data = Filename.concat directory "data" in
  let seal = Filename.concat directory "digest" in
  match Unix.lstat seal with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
  | {Unix.st_kind = Unix.S_REG; _} ->
      (match hasher.tree data with
       | Ok digest -> Sha256.to_hex digest = String.trim (read_file seal)
       | Error _ -> false)
  | _ -> false

let peek ?(hasher = default_hasher) ~store ~key () =
  try
    let key = Sha256.to_hex key in
    let target = Filename.concat store key in
    let seal = Filename.concat target "digest" in
    match Unix.lstat seal with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None
    | _ ->
        let lock = Filename.concat store (key ^ ".lock") in
        let fd = Unix.openfile lock [Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC] 0o600 in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
          Unix.lockf fd Unix.F_LOCK 0;
          if verify hasher target then Some {directory = Filename.concat target "data"; hit = true}
          else None)
  with Sys_error _ | Unix.Unix_error _ -> None

let ensure ?(hasher = default_hasher) ~store ~key build =
  try
    mkdir_p store;
    let key = Sha256.to_hex key in
    let target = Filename.concat store key in
    let lock = Filename.concat store (key ^ ".lock") in
    let fd = Unix.openfile lock [Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC] 0o600 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      let data = Filename.concat target "data" in
      if verify hasher target then Ok {directory = data; hit = true}
      else
        let staging = Filename.temp_dir ~temp_dir:store
            (Printf.sprintf ".stage-%d-" (Unix.getpid ())) "" in
        let renamed = ref false in
        Fun.protect ~finally:(fun () -> if not !renamed then rm_rf staging) (fun () ->
          let temporary = Filename.concat staging "data" in
          Sys.mkdir temporary 0o700;
          let* () = build temporary in
          let+ digest = Sha256.tree_hash temporary in
          write_file (Filename.concat staging "digest") (Sha256.to_hex digest ^ "\n");
          rm_rf target;
          Sys.rename staging target;
          renamed := true;
          {directory = data; hit = false}))
  with
  | Sys_error msg -> Error msg
  | Unix.Unix_error (code, op, path) ->
      Error (Printf.sprintf "%s %s: %s" op path (Unix.error_message code))
