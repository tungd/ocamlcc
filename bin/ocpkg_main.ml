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
        [--target TARGET] [--shared|--static|--exe|--xcframework]
        [--emit-header FILE] [--verify-cache] [-o PATH]
  run [options] [-- args] Build and run the executable
  test [options] [names] [-- args]  Run configured tests
  env                     Show workspace, cache and toolchain paths
|}

let display_package recipe =
  Printf.printf "%s %s\n" (Package_name.to_string recipe.package.name) recipe.package.version

let acquire ~offline (workspace : Pkg_project.t) lock =
  let* cache = Pkg_project.archive_cache () in
  Pkg_vendor.vendor ~fetch:Http_fetch.download ~offline ~cache
    ~vendor:(Pkg_project.vendor_dir workspace) ~project_root:workspace.root
    ~catalog_root:(Pkg_project.catalog_root workspace) lock.packages

let catalog_package (catalog : Pkg_project.catalog) key =
  match List.find_opt (fun recipe -> recipe.package.name = key) catalog.recipes with
  | Some recipe -> Ok recipe
  | None -> Error ("missing package: " ^ Package_name.to_string key)

let map_result f values =
  let rec collect acc = function
    | [] -> Ok (List.rev acc)
    | value :: rest ->
        let* value = f value in
        collect (value :: acc) rest
  in
  collect [] values

let update workspace previous next =
  let* cache = Pkg_project.archive_cache () in
  Pkg_vendor.reconcile ~fetch:Http_fetch.download ~cache
    ~directory:(Pkg_project.vendor_dir workspace) ~project_root:workspace.Pkg_project.root
    ~catalog_root:(Pkg_project.catalog_root workspace) ~previous:previous.packages
    ~next:next.packages (fun () -> Pkg_project.write_dependencies workspace next)

let replace_requirements (manifest : manifest) (selected : requirement list) =
  let names = List.map (fun (item : requirement) -> item.name) selected in
  {manifest with requirements = selected @ List.filter (fun (item : requirement) ->
    not (List.mem item.name names)) manifest.requirements}

let pin_selection workspace previous (catalog : Pkg_project.catalog) selected =
  let* latest = Pkg_vendor.resolve ~catalog:catalog.recipes selected in
  let names = List.map (fun recipe -> recipe.package.name) latest in
  let retained = List.filter (fun recipe -> not (List.mem recipe.package.name names)) previous.packages in
  let known = List.map (fun recipe -> recipe.package.name) (latest @ retained) in
  let recipes = latest @ retained @ List.filter (fun recipe ->
    not (List.mem recipe.package.name known)) catalog.recipes in
  Pkg_project.make_lock workspace {catalog with recipes}

let add (workspace : Pkg_project.t) specs =
  let missing = {catalog = workspace.manifest.snapshot; digest = Sha256.string ""; packages = []} in
  let* previous = Pkg_project.read_lock ~missing workspace in
  let* catalog = Pkg_project.catalog workspace in
  let specs =
    match specs with
    | [name; version] when not (String.contains name '@') &&
                           List.exists (fun recipe -> Package_name.to_string recipe.package.name = name &&
                             recipe.package.version = version) catalog.recipes &&
                           not (List.exists (fun recipe -> Package_name.to_string recipe.package.name = version) catalog.recipes) ->
        [name ^ "@" ^ version]
    | specs -> specs
  in
  let request spec =
    let raw_name, version = match String.index_opt spec '@' with
      | Some i -> String.sub spec 0 i, Some (String.sub spec (i + 1) (String.length spec - i - 1))
      | None -> spec, None in
    let* name = Package_name.of_string raw_name in
    let* recipe = catalog_package catalog name in
    Ok {recipe.package with version = Option.value ~default:recipe.package.version version}
  in
  let* selected = map_result request (List.sort_uniq String.compare specs) in
  let names = List.map (fun (item : requirement) -> item.name) selected in
  if List.length names <> List.length (List.sort_uniq Package_name.compare names) then
    Error "a package was requested with multiple versions"
  else
    let workspace = {workspace with Pkg_project.manifest = replace_requirements workspace.manifest selected} in
    let* lock = pin_selection workspace previous catalog selected in
    let+ () = update workspace previous lock in
    List.iter (fun (item : requirement) ->
      Printf.printf "%s %s\n" (Package_name.to_string item.name) item.version) selected

let direct_names (manifest : manifest) specs =
  let* names = map_result Package_name.of_string specs in
  match List.find_opt (fun name ->
    not (List.exists (fun (item : requirement) -> item.name = name) manifest.requirements)) names with
  | Some name -> Error ("not a direct dependency: " ^ Package_name.to_string name)
  | None -> Ok (List.sort_uniq Package_name.compare names)

let remove (workspace : Pkg_project.t) specs =
  let manifest = workspace.manifest in
  let* previous = Pkg_project.read_lock workspace in
  let* names = direct_names manifest specs in
  let requirements = List.filter (fun (item : requirement) -> not (List.mem item.name names))
    manifest.requirements in
  let* packages = Pkg_vendor.resolve ~catalog:previous.packages requirements in
  let replacements = List.filter (fun (name, _) ->
    List.exists (fun recipe -> name = recipe.package.name) packages) manifest.replacements in
  let workspace = {workspace with manifest = {manifest with requirements; replacements}} in
  update workspace previous {previous with packages}

let upgrade (workspace : Pkg_project.t) specs =
  let manifest = workspace.manifest in
  let* previous = Pkg_project.read_lock workspace in
  let* catalog = Pkg_project.catalog workspace in
  let* names = if specs = [] then Ok (List.map (fun (item : requirement) -> item.name) manifest.requirements)
    else direct_names manifest specs in
  let* selected = map_result (fun name -> let+ recipe = catalog_package catalog name in recipe.package) names in
  let workspace = {workspace with manifest = replace_requirements manifest selected} in
  let* lock = pin_selection workspace previous catalog selected in
  update workspace previous lock

let clean directory names =
  try List.iter (fun name -> Sys_util.rm_rf (Filename.concat directory name)) names; Ok ()
  with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, _, path) -> Error (path ^ ": " ^ Unix.error_message error)

let vendor workspace ~offline =
  let* lock = Pkg_project.read_lock workspace in
  let+ () = acquire ~offline workspace lock in
  Printf.printf "Verified %d vendored packages\n" (List.length lock.packages)

let tidy workspace =
  let* catalog = Pkg_project.catalog workspace in
  let* lock = Pkg_project.make_lock workspace catalog in
  Pkg_project.write_dependencies workspace lock

let verify workspace =
  let* lock = Pkg_project.read_lock workspace in
  let+ () = Pkg_vendor.verify ~vendor:(Pkg_project.vendor_dir workspace) lock.packages in
  Printf.printf "Verified %d vendored packages\n" (List.length lock.packages)

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

let with_dependency_update command =
  with_project (fun workspace -> Pkg_project.with_dependency_update workspace command)

let split_args args =
  let rec split prefix = function
    | [] -> List.rev prefix, []
    | "--" :: rest -> List.rev prefix, rest
    | arg :: rest -> split (arg :: prefix) rest
  in
  split [] args

let build_options args =
  let rec parse (options : Workspace.options) positional = function
    | [] -> Ok (options, List.rev positional)
    | "--target" :: target :: rest -> parse {options with target} positional rest
    | "-o" :: path :: rest -> parse {options with output = Some path} positional rest
    | "--exe" :: rest -> parse {options with kind = Some Exe} positional rest
    | "--shared" :: rest -> parse {options with kind = Some Shared} positional rest
    | "--static" :: rest -> parse {options with kind = Some Static} positional rest
    | "--xcframework" :: rest -> parse {options with xcframework = true} positional rest
    | "--emit-header" :: path :: rest -> parse {options with emit_header = Some path} positional rest
    | "--verify-cache" :: rest -> parse {options with verify_cache = true} positional rest
    | "--single-thread-rc" :: rest -> parse {options with single_thread = true} positional rest
    | ("-v" | "--verbose") :: rest -> parse {options with verbose = true} positional rest
    | flag :: _ when String.starts_with ~prefix:"-" flag -> Error ("unknown build option: " ^ flag)
    | arg :: rest -> parse options (arg :: positional) rest
  in
  parse Workspace.defaults [] args

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
      with_dependency_update (fun workspace -> add workspace specs)
  | "remove" :: (_ :: _ as specs) ->
      with_dependency_update (fun workspace -> remove workspace specs)
  | "upgrade" :: specs ->
      with_dependency_update (fun workspace -> upgrade workspace specs)
  | ["clean"] -> with_project (fun workspace -> clean (Filename.concat workspace.root ".ocpkg") ["bin"; "cache"])
  | ["clean"; "--global"] ->
      let* cache = Pkg_project.cache_dir () in
      clean cache ["pkg"; "stdlib"; "runtime"; "stat-index"; "archives"]
  | ["version"] | ["--version"] -> print_endline ("ocpkg " ^ Ocpkg_version.value); Ok ()
  | ["vendor"] -> with_dependency_update (fun workspace -> vendor workspace ~offline:false)
  | ["vendor"; "--offline"] -> with_dependency_update (fun workspace -> vendor workspace ~offline:true)
  | ["tidy"] -> with_dependency_update tidy
  | ["verify"] -> with_project verify
  | ["query"] -> with_project (fun workspace -> query workspace None)
  | ["query"; key] -> with_project (fun workspace -> query workspace (Some key))
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
