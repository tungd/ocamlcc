open Ocpkg_format
open Sys_util
open Result_syntax

type fetch = url:string -> destination:string -> (unit, string) result

let show = Package_name.to_string
let package_name recipe = recipe.package.name
let max_download = 64 * 1024 * 1024

let filesystem f =
  try f () with
  | Sys_error msg -> Error msg
  | Unix.Unix_error (code, op, path) ->
      Error (Printf.sprintf "%s %s: %s" op path (Unix.error_message code))

let stat path =
  match Unix.lstat path with
  | stat -> Some stat
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None

let rec each f = function
  | [] -> Ok ()
  | next :: rest ->
      let* () = f next in
      each f rest

let resolve ~catalog requirements =
  let entries = Hashtbl.create (List.length catalog) in
  let state = Hashtbl.create (List.length catalog) in
  let ordered = ref [] in
  let* () = each (fun recipe ->
    let key = package_name recipe in
    if Hashtbl.mem entries key then Error ("duplicate package: " ^ show key)
    else (Hashtbl.add entries key recipe; Ok ())) catalog in
  let missing key = Error ("missing package: " ^ show key) in
  let rec visit key =
    match Hashtbl.find_opt state key, Hashtbl.find_opt entries key with
    | Some `Done, _ -> Ok ()
    | Some `Visiting, _ -> Error ("package dependency cycle: " ^ show key)
    | None, None -> missing key
    | None, Some recipe ->
        Hashtbl.add state key `Visiting;
        let* () = each visit recipe.dependencies in
        Hashtbl.replace state key `Done;
        ordered := recipe :: !ordered;
        Ok ()
  in
  let* () = each (fun (required : requirement) ->
    match Hashtbl.find_opt entries required.name with
    | Some recipe when recipe.package.version = required.version -> visit required.name
    | Some recipe ->
        Error (Printf.sprintf "package %s is pinned at %s, requested %s"
                 (show required.name) recipe.package.version required.version)
    | None -> missing required.name) requirements in
  Ok (List.rev !ordered)

let checked_local ~catalog_root relative =
  let canonical = Unix.realpath catalog_root in
  let path = Rel_path.resolve ~root:canonical relative in
  let actual = Unix.realpath path in
  if actual = canonical || String.starts_with ~prefix:(canonical ^ "/") actual then Ok path
  else Error ("local recipe source escapes its root: " ^ Rel_path.to_string relative)

let replacement_path ~project_root path =
  if Filename.is_relative path then Filename.concat project_root path else path

let pin ~project_root ~catalog_root ~replacements recipes =
  filesystem (fun () ->
    let* () = each (fun (name, _) ->
      if List.exists (fun recipe -> package_name recipe = name) recipes then Ok ()
      else Error ("replacement is outside the dependency closure: " ^ show name)) replacements in
    let rec visit pinned = function
      | [] -> Ok (List.rev pinned)
      | recipe :: rest ->
          let* recipe =
            match List.assoc_opt (package_name recipe) replacements, recipe.source with
            | Some directory, _ ->
                let+ tree = Sha256.tree_hash (replacement_path ~project_root directory) in
                {recipe with source = Replacement directory; tree}
            | None, Local relative ->
                let* path = checked_local ~catalog_root relative in
                let* tree = Sha256.tree_hash path in
                if Sha256.equal tree recipe.tree then Ok recipe
                else Error ("local recipe source changed: " ^ path)
            | None, _ -> Ok recipe
          in
          visit (recipe :: pinned) rest
    in
    visit [] recipes)

let verify_archive ~digest path =
  match stat path with
  | Some {Unix.st_kind = Unix.S_REG; st_size; _} ->
      if st_size > max_download then Error "archive exceeds the 64 MiB download limit"
      else
        let* received = Sha256.file path in
        if Sha256.equal received digest then Ok ()
        else Error ("archive digest mismatch: " ^ path)
  | _ -> Error ("archive must be a regular file: " ^ path)

let archive ~fetch ~offline ~cache (source : archive) =
  filesystem (fun () ->
    let hex = Sha256.to_hex source.digest in
    let path = Filename.concat cache hex in
    match stat path with
    | Some _ ->
        let+ () = verify_archive ~digest:source.digest path in
        path
    | None when offline -> Error ("archive absent from offline cache: " ^ hex)
    | None when not (String.starts_with ~prefix:"https://" source.url) ->
        Error "source archives require HTTPS"
    | None ->
        mkdir_p cache;
        let tmp, output = Filename.open_temp_file ~temp_dir:cache ".download-" "" in
        close_out output;
        Fun.protect ~finally:(fun () -> rm_rf tmp) (fun () ->
          let* () = fetch ~url:source.url ~destination:tmp in
          let+ () = verify_archive ~digest:source.digest tmp in
          Unix.rename tmp path;
          path))

let path_for root recipe = Filename.concat root (show (package_name recipe))

let changed ?index recipe path =
  let tree = Option.fold ~none:(fun path -> Sha256.tree_hash path) ~some:Digest_index.tree index in
  let+ current = tree path in
  not (Sha256.equal recipe.tree current)

let checked_vendor root =
  match stat root with
  | Some {Unix.st_kind = Unix.S_DIR; _} -> Ok ()
  | _ -> Error ("vendor must be a directory: " ^ root)

let verify ?index ~vendor recipes =
  filesystem (fun () ->
    let* () = if recipes = [] then Ok () else checked_vendor vendor in
    each (fun recipe ->
      let path = path_for vendor recipe in
      let* changed = changed ?index recipe path in
      if changed then Error ("vendored source changed: " ^ path)
      else Ok ()) recipes)

let copy_regular source destination mode =
  In_channel.with_open_bin source (fun input ->
    Out_channel.with_open_bin destination (fun output ->
      let bytes = Bytes.create (64 * 1024) in
      let rec copy () =
        let size = In_channel.input input bytes 0 (Bytes.length bytes) in
        if size <> 0 then begin
          Out_channel.output output bytes 0 size;
          copy ()
        end
      in
      copy ()));
  Unix.chmod destination (if mode land 0o111 <> 0 then 0o755 else 0o644)

let rec copy_tree source destination =
  let file = Unix.lstat source in
  match file.Unix.st_kind with
  | Unix.S_DIR ->
      Unix.mkdir destination 0o755;
      Sys.readdir source |> Array.iter (fun name ->
        copy_tree (Filename.concat source name) (Filename.concat destination name))
  | Unix.S_REG -> copy_regular source destination file.st_perm
  | _ -> raise (Sys_error ("unsupported source entry: " ^ source))

let lock_vendor root f =
  let lockfile = Filename.concat root ".ocpkg.lock" in
  match stat lockfile with
  | Some file when file.Unix.st_kind <> Unix.S_REG -> Error ("invalid vendor lock file: " ^ lockfile)
  | _ ->
      let descriptor = Unix.openfile lockfile [Unix.O_CREAT; Unix.O_RDWR; Unix.O_CLOEXEC] 0o600 in
      Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
        Unix.lockf descriptor Unix.F_LOCK 0;
        f ())

let vendor ~fetch ~offline ~cache ~vendor ~project_root ~catalog_root recipes =
  filesystem (fun () ->
    mkdir_p vendor;
    let* () = checked_vendor vendor in
    lock_vendor vendor (fun () ->
      let local scratch recipe path =
        let* modified = changed recipe path in
        if modified then Error ("local recipe source changed: " ^ path)
        else
          let destination = Filename.concat scratch "source" in
          let () = copy_tree path destination in
          Ok destination
      in
      let publish recipe =
        let target = path_for vendor recipe in
        match stat target with
        | Some _ ->
            (match changed recipe target with
            | Ok false -> Ok ()
            | _ -> Error ("refusing to overwrite changed vendor directory: " ^ target))
        | None ->
            let scratch = Filename.temp_dir ~temp_dir:vendor ".source-" "" in
            Fun.protect ~finally:(fun () -> rm_rf scratch) (fun () ->
              let* staged =
                match recipe.source with
                | Local relative ->
                    let* path = checked_local ~catalog_root relative in
                    local scratch recipe path
                | Replacement directory -> local scratch recipe (replacement_path ~project_root directory)
                | Archive source ->
                    let* archive = archive ~fetch ~offline ~cache source in
                    Pkg_archive.unpack ~archive ~root:source.root ~into:scratch
              in
              let* modified = changed recipe staged in
              if modified then Error ("extracted source tree mismatch: " ^ show (package_name recipe))
              else
                match stat target with
                | Some _ -> Error ("refusing to overwrite vendor directory: " ^ target)
                | None -> Unix.rename staged target; Ok ())
      in
      let* () = each publish recipes in
      verify ~vendor recipes))

let reconcile ~fetch ~cache ~directory ~project_root ~catalog_root ~previous ~next commit =
  filesystem (fun () ->
    mkdir_p directory;
    let* () = checked_vendor directory in
    lock_vendor directory (fun () ->
      let find source recipe = List.find_opt (fun item -> package_name item = package_name recipe) source in
      let obsolete = List.filter (fun recipe ->
        match find next recipe with
        | Some replacement -> not (Sha256.equal recipe.tree replacement.tree)
        | None -> true) previous in
      let known_old recipe = Option.is_some (find obsolete recipe) in
      let check_old recipe =
        let path = path_for directory recipe in
        match stat path with
        | None -> Ok ()
        | Some _ ->
            (match changed recipe path with
            | Ok false -> Ok ()
            | _ -> Error ("refusing to overwrite changed vendor directory: " ^ path)) in
      let* () = each check_old obsolete in
      let staged = List.filter (fun recipe ->
        known_old recipe || stat (path_for directory recipe) = None) next in
      let* () = verify ~vendor:directory (List.filter (fun recipe ->
          not (List.exists (fun item -> package_name item = package_name recipe) staged)) next) in
      let scratch = Filename.temp_dir ~temp_dir:directory ".update-" "" in
      let rollback_complete = ref true in
      Fun.protect ~finally:(fun () -> if !rollback_complete then rm_rf scratch) (fun () ->
        let incoming = Filename.concat scratch "incoming" in
        let* () = vendor ~fetch ~offline:false ~cache ~vendor:incoming ~project_root ~catalog_root staged in
        let* () = each check_old obsolete in
        let backup = Filename.concat scratch "backup" in
        Unix.mkdir backup 0o700;
        let moved = ref [] in
        let installed = ref [] in
        let committed = ref false in
        Fun.protect ~finally:(fun () ->
          if not !committed then begin
            rollback_complete := false;
            List.iter (fun (source, destination) -> Unix.rename destination source) !installed;
            List.iter (fun (source, destination) -> Unix.rename destination source) !moved;
            rollback_complete := true
          end) (fun () ->
          List.iter (fun recipe ->
            let source = path_for directory recipe in
            if stat source <> None then begin
              let destination = path_for backup recipe in
              Unix.rename source destination;
              moved := (source, destination) :: !moved
            end) obsolete;
          let* () = each (fun recipe ->
            let source = path_for incoming recipe in
            let destination = path_for directory recipe in
            match stat destination with
            | Some _ -> Error ("refusing to overwrite vendor directory: " ^ destination)
            | None ->
                Unix.rename source destination;
                installed := (source, destination) :: !installed;
                Ok ()) staged in
          let+ () = commit () in
          committed := true))))
