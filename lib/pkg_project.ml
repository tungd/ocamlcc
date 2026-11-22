open Ocpkg_format
open Sys_util
open Result_syntax

type t = { root : string; manifest : manifest }
type catalog = { root : string; digest : Sha256.t; recipes : recipe list }

let io f =
  try f () with
  | Sys_error msg -> Error msg
  | Unix.Unix_error (code, op, path) ->
      Error (Printf.sprintf "%s %s: %s" op path (Unix.error_message code))

let manifest_path root = Filename.concat root "ocpkg.mod"
let lock_path root = Filename.concat root "ocpkg.lock"
let vendor_dir (workspace : t) = Filename.concat workspace.root "vendor"

let existing_file path =
  match Unix.lstat path with
  | {Unix.st_kind = Unix.S_REG; _} -> true
  | _ -> false
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false

let decode path parser =
  let contents = read_file path in
  Result.map_error (fun msg -> path ^ ": " ^ msg) (parser contents)

let open_workspace () =
  let rec find directory =
    let path = manifest_path directory in
    if existing_file path then
      let+ manifest = decode path parse_manifest in
      {root = directory; manifest}
    else
      let parent = Filename.dirname directory in
      if parent = directory then Error "cannot find ocpkg.mod"
      else find parent
  in
  io (fun () -> find (Sys.getcwd ()))

let root_catalog () =
  match Target.installed_toolchain () with
  | Some root ->
      let path = Filename.concat root "snapshots/default.snap" in
      if Sys.file_exists path then Some path else None
  | None -> Target.search_upwards "packages/snapshots/default.snap"

let catalog_root (workspace : t) =
  let snapshot = workspace.manifest.snapshot in
  if Rel_path.to_string snapshot = "default" then
    match Target.installed_toolchain () with
    | Some path -> path
    | None -> Option.value (Target.search_upwards "packages") ~default:workspace.root
  else Filename.dirname (Rel_path.resolve ~root:workspace.root snapshot)

let catalog (workspace : t) =
  io (fun () ->
    let snapshot = workspace.manifest.snapshot in
    let path =
      if Rel_path.to_string snapshot = "default" then root_catalog ()
      else Some (Rel_path.resolve ~root:workspace.root snapshot)
    in
    match path with
    | None -> Error "cannot find the default package snapshot"
    | Some path ->
        let contents = read_file path in
        let* recipes = Result.map_error (fun msg -> path ^ ": " ^ msg) (parse_snapshot contents) in
        let root = catalog_root workspace in
        Ok {root; digest = Sha256.string contents; recipes})

let cache_dir () =
  match Sys.getenv_opt "OCPKG_CACHE", Sys.getenv_opt "XDG_CACHE_HOME", Sys.getenv_opt "HOME" with
  | Some path, _, _ when path <> "" -> Ok path
  | _, Some xdg, _ when xdg <> "" -> Ok (Filename.concat xdg "ocpkg")
  | _, _, Some home when home <> "" -> Ok (Filename.concat home ".cache/ocpkg")
  | _ -> Error "set OCPKG_CACHE to locate the package cache"

let archive_cache () =
  let+ dir = cache_dir () in
  Filename.concat dir "archives"

let make_lock (workspace : t) catalog =
  let* closure = Pkg_vendor.resolve ~catalog:catalog.recipes workspace.manifest.requirements in
  let+ packages = Pkg_vendor.pin ~project_root:workspace.root ~catalog_root:catalog.root
      ~replacements:workspace.manifest.replacements closure in
  {catalog = workspace.manifest.snapshot; digest = catalog.digest; packages}

let read_lock ?missing (workspace : t) =
  let path = lock_path workspace.root in
  let validate () =
    let* saved = decode path parse_lock in
    let manifest = workspace.manifest in
    if saved.catalog <> manifest.snapshot then Error "lock snapshot selection does not match the manifest"
    else
      let* packages = Pkg_vendor.resolve ~catalog:saved.packages manifest.requirements in
      let replacement (recipe : recipe) =
        match recipe.source with
        | Replacement path -> Some (recipe.package.name, path)
        | Archive _ | Local _ -> None
      in
      let sorted = List.sort compare in
      if List.length packages <> List.length saved.packages ||
         sorted (List.filter_map replacement packages) <> sorted manifest.replacements
      then Error "locked packages or replacements do not match the manifest"
      else Ok {saved with packages} in
  io (fun () ->
    match Unix.lstat path with
    | _ -> validate ()
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        match missing with Some lock -> Ok lock | None -> Error ("cannot find " ^ path))

let write_lock (workspace : t) lock =
  io (fun () ->
    write_if_changed (lock_path workspace.root) (print_lock lock);
    Ok ())

let write_manifest (workspace : t) =
  io (fun () ->
    write_if_changed (manifest_path workspace.root) (print_manifest workspace.manifest);
    Ok ())

let initialize ~name =
  io (fun () ->
    let root = Sys.getcwd () in
    if Sys.file_exists (manifest_path root) then Error "ocpkg.mod already exists"
    else
      let* name = match name with
        | Some name -> Package_name.of_string name
        | None -> match Package_name.of_string (Filename.basename root) with
          | Ok _ as found -> found
          | Error _ -> Package_name.of_string "app"
      in
      let* entry = Rel_path.of_string "src/main.ml" in
      let* source = Rel_path.of_string "src" in
      let manifest = { (project name) with entry = Some entry; source_dirs = [source] } in
      let workspace = {root; manifest} in
      let lock = {catalog = manifest.snapshot; digest = Sha256.string ""; packages = []} in
      let entry = Rel_path.resolve ~root entry in
      mkdir_p (Filename.dirname entry);
      if not (Sys.file_exists entry) then write_if_changed entry "let () = print_endline \"Hello from OCaml!\"\n";
      let* () = write_manifest workspace in
      let+ () = write_lock workspace lock in
      workspace)

let write_dependencies (workspace : t) lock =
  io (fun () ->
    let path = lock_path workspace.root in
    let original = if existing_file path then Some (read_file path) else None in
    let* () = write_lock workspace lock in
    match write_manifest workspace with
    | Ok () -> Ok ()
    | Error _ as error ->
        (match original with
         | Some contents -> write_if_changed path contents
         | None -> Sys.remove path);
        error)

let with_dependency_update (workspace : t) f =
  io (fun () ->
    let directory = Filename.concat workspace.root ".ocpkg" in
    mkdir_p directory;
    let lock = Filename.concat directory "dependencies.lock" in
    let fd = Unix.openfile lock [Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC] 0o600 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      Unix.lockf fd Unix.F_LOCK 0;
      let+ manifest = decode (manifest_path workspace.root) parse_manifest in
      f {workspace with manifest})
    |> Result.join)
