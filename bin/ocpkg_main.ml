open Ocpkg_format
open Sys_util.Result_syntax

let usage = {|Usage: ocpkg <command>

  init [name]             Create ocpkg.mod and a starter executable
  add|get name[@version] ...  Pin and vendor packages from the snapshot
  remove name ...         Remove direct dependencies and unused vendor trees
  upgrade [name ...]      Adopt catalog recipes for selected dependencies
  clean [--global]       Clear workspace or shared cache artifacts
  version                 Show the tool version
  vendor [--offline]      Freeze and verify the workspace vendor tree
  tidy                    Canonicalize requirements and update the lock
  verify                  Verify the lock and vendor tree
  query [name]            List selected packages or show a locked recipe
  build [options]         Compile and link the workspace offline
        [-j N|--jobs N] [--no-progress] [--debug|--release] [-g]
        [--target TARGET] [--shared|--static|--exe|--xcframework]
        [--emit-header FILE] [--verify-cache] [-o PATH]
  run [options] [-- args] Build and run the executable
  test [options] [names] [-- args]  Run configured tests
  env                     Show workspace, cache and toolchain paths
|}

let display_package recipe =
  Printf.printf "%s %s\n" (Package_name.to_string recipe.package.name) recipe.package.version

let clean directory names =
  try List.iter (fun name -> Sys_util.rm_rf (Filename.concat directory name)) names; Ok ()
  with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, _, path) -> Error (path ^ ": " ^ Unix.error_message error)

let print_verified count = Printf.printf "Verified %d vendored packages\n" count

let add workspace specs =
  let+ selected = Pkg_project.add ~fetch:Http_fetch.download workspace specs in
  List.iter (fun (item : requirement) ->
    Printf.printf "%s %s\n" (Package_name.to_string item.name) item.version) selected

let vendor workspace ~offline =
  let+ count = Pkg_project.vendor ~fetch:Http_fetch.download ~offline workspace in
  print_verified count

let verify workspace =
  let* lock = Pkg_project.read_lock workspace in
  let+ () = Pkg_vendor.verify ~vendor:(Pkg_project.vendor_dir workspace) lock.packages in
  print_verified (List.length lock.packages)

let query workspace = function
  | None ->
      let+ lock = Pkg_project.read_lock workspace in
      List.iter display_package lock.packages
  | Some key ->
      let* name = Package_name.of_string key in
      let* lock = Pkg_project.read_lock workspace in
      match List.find_opt (fun recipe -> recipe.package.name = name) lock.packages with
      | Some recipe -> print_string (print_snapshot [recipe]); Ok ()
      | None -> Error ("missing package: " ^ key)

let env () =
  let* cache = Pkg_project.cache_dir () in
  let show name = function Some value -> Printf.printf "%s=%s\n" name value | None -> () in
  (match Pkg_project.open_workspace () with
   | Ok workspace -> show "OCPKG_ROOT" (Some workspace.root)
   | Error _ -> ());
  show "OCPKG_CACHE" (Some cache);
  show "OCPKG_SNAPSHOT" (Pkg_project.root_catalog ());
  show "OCC" (Pkg_toolchain.compiler_binary ());
  show "QBE" (Result.to_option (Target.qbe None));
  show "OCC_STDLIB" (Target.prebuilt_stdlib None);
  show "OCC_RUNTIME" (Target.prebuilt_runtime ~single_thread:false None);
  Ok ()

let with_project command =
  let* workspace = Pkg_project.open_workspace () in
  command workspace

let with_dependencies command =
  with_project (fun workspace -> Pkg_project.with_dependencies workspace command)

let split_args args =
  let rec split prefix = function
    | [] -> List.rev prefix, []
    | "--" :: rest -> List.rev prefix, rest
    | arg :: rest -> split (arg :: prefix) rest
  in
  split [] args

let build_options args =
  let product target mode =
    let native kind =
      let target = Option.value ~default:"host" target in
      Ok (Workspace.Product.Native {target; kind}) in
    match target, mode with
    | (None | Some "ios-xcframework"), Some `Xcframework
    | Some "ios-xcframework", None -> Ok Workspace.Product.Xcframework
    | Some "ios-xcframework", Some (`Native _) -> Error "conflicting output modes"
    | Some _, Some `Xcframework -> Error "--xcframework selects its own targets"
    | _, None -> native None
    | _, Some (`Native kind) -> native (Some kind)
  in
  let parse_jobs raw =
    match int_of_string_opt raw with
    | Some n when n >= 1 -> Ok n
    | _ -> Error ("invalid job count: " ^ raw)
  in
  let rec parse (options : Workspace.options) target mode positional = function
    | [] ->
        let+ product = product target mode in
        {options with product}, List.rev positional
    | "--target" :: name :: rest -> parse options (Some name) mode positional rest
    | "-o" :: path :: rest -> parse {options with output = Some path} target mode positional rest
    | ("-j" | "--jobs") :: raw :: rest ->
        let* jobs = parse_jobs raw in
        parse {options with jobs} target mode positional rest
    | flag :: rest when String.starts_with ~prefix:"--jobs=" flag ->
        let* jobs = parse_jobs (String.sub flag 7 (String.length flag - 7)) in
        parse {options with jobs} target mode positional rest
    | flag :: rest when String.starts_with ~prefix:"-j" flag && String.length flag > 2 ->
        let* jobs = parse_jobs (String.sub flag 2 (String.length flag - 2)) in
        parse {options with jobs} target mode positional rest
    | ("-j" | "--jobs") :: [] -> Error "missing job count"
    | "--no-progress" :: rest -> parse {options with progress = false} target mode positional rest
    | ("--debug" | "-O0") :: rest -> parse {options with mode = Build_mode.Debug} target mode positional rest
    | ("--release" | "-O2") :: rest -> parse {options with mode = Build_mode.Release} target mode positional rest
    | "-g" :: rest -> parse {options with debug_info = Some true} target mode positional rest
    | "-g0" :: rest -> parse {options with debug_info = Some false} target mode positional rest
    | ("--exe" | "--shared" | "--static" | "--xcframework" as flag) :: rest ->
        let selected =
          match flag with
          | "--exe" -> `Native Exe
          | "--shared" -> `Native Shared
          | "--static" -> `Native Static
          | _ -> `Xcframework
        in
        if mode <> None && mode <> Some selected then Error "conflicting output modes"
        else parse options target (Some selected) positional rest
    | "--emit-header" :: path :: rest ->
        parse {options with emit_header = Some path} target mode positional rest
    | "--verify-cache" :: rest -> parse {options with verify_cache = true} target mode positional rest
    | "--single-thread-rc" :: rest -> parse {options with single_thread = true} target mode positional rest
    | ("-v" | "--verbose") :: rest -> parse {options with verbose = true} target mode positional rest
    | flag :: _ when String.starts_with ~prefix:"-" flag -> Error ("unknown build option: " ^ flag)
    | arg :: rest -> parse options target mode (arg :: positional) rest
  in
  parse Workspace.defaults None None [] args

let run = function
  | [] | ["-h"] | ["--help"] -> print_string usage; Ok ()
  | ["env"] -> env ()
  | ["init"] ->
      let+ _ = Pkg_project.initialize ~name:None in
      print_endline "Created ocpkg.mod"
  | ["init"; name] ->
      let+ _ = Pkg_project.initialize ~name:(Some name) in
      print_endline "Created ocpkg.mod"
  | ("add" | "get") :: (_ :: _ as specs) ->
      with_project (fun workspace -> add workspace specs)
  | "remove" :: (_ :: _ as specs) ->
      with_project (fun workspace -> Pkg_project.remove workspace specs)
  | "upgrade" :: specs ->
      with_project (fun workspace -> Pkg_project.upgrade ~fetch:Http_fetch.download workspace specs)
  | ["clean"] -> with_project (fun workspace -> clean (Filename.concat workspace.root ".ocpkg") ["bin"; "cache"])
  | ["clean"; "--global"] ->
      let* cache = Pkg_project.cache_dir () in
      clean cache ["pkg"; "stdlib"; "runtime"; "stat-index"; "archives"; "occ-unit"; "occ-obj"; "occ-c"]
  | ["version"] | ["--version"] -> print_endline ("ocpkg " ^ Ocpkg_version.value); Ok ()
  | ["vendor"] -> with_project (fun workspace -> vendor workspace ~offline:false)
  | ["vendor"; "--offline"] -> with_project (fun workspace -> vendor workspace ~offline:true)
  | ["tidy"] -> with_project Pkg_project.tidy
  | ["verify"] -> with_dependencies verify
  | ["query"] -> with_dependencies (fun workspace -> query workspace None)
  | ["query"; key] -> with_dependencies (fun workspace -> query workspace (Some key))
  | "build" :: flags ->
      let* options, positional = build_options flags in
      if positional <> [] then Error "build expects options"
      else with_project (fun workspace ->
        let+ output = Workspace.build workspace options in print_endline output)
  | "run" :: flags ->
      let flags, forwarded = split_args flags in
      let* options, args = build_options flags in
      with_project (fun workspace -> Workspace.run workspace options (args @ forwarded))
  | "test" :: flags ->
      let flags, args = split_args flags in
      let* options, names = build_options flags in
      with_project (fun workspace -> Workspace.test workspace options names args)
  | _ -> Error ("invalid arguments\n" ^ usage)

let () =
  match run (List.tl (Array.to_list Sys.argv)) with
  | Ok () -> ()
  | Error message -> prerr_endline ("ocpkg: " ^ message); exit 1
