type stamp = {
  device : int64;
  inode : int64;
  size : int64;
  mtime : int;
  mtime_ns : int;
  ctime : int;
  ctime_ns : int;
}

external stamp : string -> stamp = "ocpkg_digest_stat"

type memo = {
  entries : (string, stamp * Sha256.t) Hashtbl.t;
  updates : (string, stamp * Sha256.t) Hashtbl.t;
}

type t = Verify | Memoize of memo

let file index path = match index with
  | Verify -> Sha256.file path
  | Memoize index ->
    try
      let before = stamp path in
      match Hashtbl.find_opt index.entries path with
      | Some (seen, digest) when seen = before -> Ok digest
      | _ ->
          Result.bind (Sha256.file path) (fun digest ->
            if stamp path <> before then Error ("file changed during hashing: " ^ path)
            else begin
              let entry = before, digest in
              Hashtbl.replace index.entries path entry;
              Hashtbl.replace index.updates path entry;
              Ok digest
            end)
    with Unix.Unix_error (error, _, _) ->
      Error (path ^ ": " ^ Unix.error_message error)

let tree index path = Sha256.tree_hash ~file:(file index) path

let read path =
  let entries = Hashtbl.create 512 in
  (try In_channel.with_open_bin path (fun input ->
    let parse row =
      match String.split_on_char '\t' row with
      | [path; device; inode; size; mtime; mtime_ns; ctime; ctime_ns; digest] ->
          (try
            let stamp = {device = Int64.of_string device; inode = Int64.of_string inode;
              size = Int64.of_string size; mtime = int_of_string mtime; mtime_ns = int_of_string mtime_ns;
              ctime = int_of_string ctime; ctime_ns = int_of_string ctime_ns} in
            Result.iter (fun digest ->
              Hashtbl.replace entries (Scanf.unescaped path) (stamp, digest)) (Sha256.of_hex digest)
          with Failure _ | Scanf.Scan_failure _ | End_of_file -> ())
      | _ -> () in
    let rec loop () = match In_channel.input_line input with
      | Some row -> parse row; loop ()
      | None -> () in
    loop ())
   with Sys_error _ -> ());
  entries

let save path updates =
  let directory = Filename.dirname path in
  Sys_util.mkdir_p directory;
  let fd = Unix.openfile (path ^ ".lock") [O_RDWR; O_CREAT; O_CLOEXEC] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    Unix.lockf fd Unix.F_LOCK 0;
    let entries = read path in
    Hashtbl.iter (Hashtbl.replace entries) updates;
    let data = Buffer.create 65536 in
    Hashtbl.iter (fun file (s, digest) ->
      Printf.bprintf data "%s\t%Ld\t%Ld\t%Ld\t%d\t%d\t%d\t%d\t%s\n"
        (String.escaped file) s.device s.inode s.size s.mtime s.mtime_ns s.ctime s.ctime_ns
        (Sha256.to_hex digest)
    ) entries;
    Sys_util.write_atomic path (Buffer.contents data))

let with_index ~cache ~workspace ~verify f =
  if verify then f Verify
  else
    let directory = Filename.concat cache "stat-index" in
    let path = Filename.concat directory (Digest.to_hex (Digest.string workspace)) in
    let memo = {entries = read path; updates = Hashtbl.create 64} in
    Fun.protect ~finally:(fun () ->
      if Hashtbl.length memo.updates > 0 then
        try save path memo.updates with Sys_error _ | Unix.Unix_error _ -> ())
      (fun () -> f (Memoize memo))
