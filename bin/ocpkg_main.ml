open Ocpkg_format
open Sys_util.Result_syntax

let usage = {|Usage: ocpkg <command>

  init [name]             Create ocpkg.mod and a starter executable
  add|get name [version]  Pin and vendor a package from the snapshot
  vendor [--offline]      Freeze and verify the workspace vendor tree
  tidy                    Canonicalize requirements and update the lock
  verify                  Verify the lock and vendor tree
  query [name]            List selected packages or show a catalog recipe
  env                     Show workspace, cache and toolchain paths
|}

let display_package recipe =
  Printf.printf "%s %s\n" (Package_name.to_string recipe.package.name) recipe.package.version

let acquire ~offline (workspace : Pkg_project.t) catalog lock =
  let* cache = Pkg_project.archive_cache () in
  Pkg_vendor.vendor ~fetch:Http_fetch.download ~offline ~cache
    ~vendor:(Pkg_project.vendor_dir workspace) ~project_root:workspace.root
    ~catalog_root:catalog.Pkg_project.root lock.packages

let add workspace package version =
  let* package = Package_name.of_string package in
  let* catalog = Pkg_project.catalog workspace in
  match List.find_opt (fun recipe -> recipe.package.name = package) catalog.recipes with
  | None -> Error ("missing package: " ^ Package_name.to_string package)
  | Some recipe ->
      let requirement = {recipe.package with version = Option.value ~default:recipe.package.version version} in
      let manifest = workspace.Pkg_project.manifest in
      let requirements =
        requirement :: List.filter (fun (required : requirement) -> required.name <> package)
                         manifest.requirements
      in
      let workspace = {workspace with manifest = {manifest with requirements}} in
      let* lock = Pkg_project.make_lock workspace catalog in
      let* () = acquire ~offline:false workspace catalog lock in
      let* () = Pkg_project.write_lock workspace lock in
      let+ () = Pkg_project.write_manifest workspace in
      display_package recipe

let vendor workspace ~offline =
  let* catalog = Pkg_project.catalog workspace in
  let lock_exists = Sys.file_exists (Filename.concat workspace.Pkg_project.root "ocpkg.lock") in
  let* lock = if lock_exists then Pkg_project.read_lock workspace else Pkg_project.make_lock workspace catalog in
  let* () = acquire ~offline workspace catalog lock in
  let+ () = Pkg_project.write_lock workspace lock in
  Printf.printf "Verified %d vendored packages\n" (List.length lock.packages)

let tidy workspace =
  let* catalog = Pkg_project.catalog workspace in
  let* lock = Pkg_project.make_lock workspace catalog in
  let* () = Pkg_project.write_lock workspace lock in
  Pkg_project.write_manifest workspace

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
      let* catalog = Pkg_project.catalog workspace in
      match List.find_opt (fun recipe -> recipe.package.name = name) catalog.recipes with
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
  show "OCC" (Sys_util.find_in_path "occ");
  show "QBE" (Result.to_option (Target.qbe None));
  show "OCC_STDLIB" (Target.prebuilt_stdlib None);
  show "OCC_RUNTIME" (Target.prebuilt_runtime ~single_thread:false None);
  Ok ()

let with_project command =
  let* workspace = Pkg_project.open_workspace () in
  command workspace

let run = function
  | [] | ["-h"] | ["--help"] -> print_string usage; Ok ()
  | ["env"] -> env ()
  | ["init"] ->
      let+ _ = Pkg_project.initialize ~name:None in
      print_endline "Created ocpkg.mod"
  | ["init"; name] ->
      let+ _ = Pkg_project.initialize ~name:(Some name) in
      print_endline "Created ocpkg.mod"
  | [("add" | "get"); key] -> with_project (fun workspace -> add workspace key None)
  | [("add" | "get"); key; version] ->
      with_project (fun workspace -> add workspace key (Some version))
  | ["vendor"] -> with_project (fun workspace -> vendor workspace ~offline:false)
  | ["vendor"; "--offline"] -> with_project (fun workspace -> vendor workspace ~offline:true)
  | ["tidy"] -> with_project tidy
  | ["verify"] -> with_project verify
  | ["query"] -> with_project (fun workspace -> query workspace None)
  | ["query"; key] -> with_project (fun workspace -> query workspace (Some key))
  | _ -> Error ("invalid arguments\n" ^ usage)

let () =
  match run (List.tl (Array.to_list Sys.argv)) with
  | Ok () -> ()
  | Error message -> prerr_endline ("ocpkg: " ^ message); exit 1
