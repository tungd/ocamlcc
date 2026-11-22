open Ocpkg_format
open Sys_util
open Result_syntax

type options = {
  target : string;
  kind : kind option;
  output : string option;
  single_thread : bool;
  verbose : bool;
}

let defaults = {target = "host"; kind = None; output = None; single_thread = false; verbose = false}

type pack = {
  recipe : recipe;
  id : Sha256.t;
  directory : string;
  archive : string;
  units : string list;
}

let empty_scope : Pkg_compile.scope =
  {visible = []; hidden = []; archives = []; package_keys = []}

let package_name recipe = Package_name.to_string recipe.package.name

let package_scope packs =
  List.fold_right (fun pack (scope : Pkg_compile.scope) ->
    let hidden =
      match pack.recipe.wrapping with
      | Flat -> scope.hidden
      | Wrapped _ -> Filename.concat pack.directory "private" :: scope.hidden
    in
    { visible = pack.directory :: scope.visible;
      hidden; archives = pack.archive :: scope.archives;
      package_keys = pack.id :: scope.package_keys }) packs empty_scope

let module_sources paths =
  List.filter (fun file -> Filename.check_suffix file ".ml" || Filename.check_suffix file ".mli") paths

let native_sources paths = List.filter (fun file -> Filename.check_suffix file ".c") paths
let package_archive directory recipe = Filename.concat directory ("lib" ^ package_name recipe ^ ".a")

let prepare_package tools ~vendor ~prior recipe =
  let rec all_dependencies seen todo =
    match todo with
    | [] -> seen
    | dep :: rest when List.mem dep seen -> all_dependencies seen rest
    | dep :: rest ->
        let next = (List.find (fun pack -> pack.recipe.package.name = dep) prior).recipe.dependencies in
        all_dependencies (dep :: seen) (next @ rest)
  in
  let dependencies = all_dependencies [] recipe.dependencies in
  let selected = List.filter (fun pack -> List.mem pack.recipe.package.name dependencies) prior in
  let scope = package_scope selected in
  let key =
    Build_cache.key (["toolchain", Sha256.to_hex tools.Pkg_toolchain.fingerprint;
                        "recipe", print_snapshot [recipe]]
        @ List.map (fun key -> "dependency", Sha256.to_hex key) scope.package_keys)
  in
  let store = Filename.concat tools.cache "pkg" in
  let* entry = Build_cache.ensure ~store ~key (fun directory ->
    let source_root = Filename.concat vendor (package_name recipe) in
    let staging = Filename.temp_dir "ocpkg-package-" "" in
    Fun.protect ~finally:(fun () -> rm_rf staging) (fun () ->
      let files = List.map (fun item ->
          let source = Rel_path.resolve ~root:source_root (Comp_input.source item) in
          let target = Filename.concat staging (Comp_input.name item) in
          write_file target (read_file source);
          target) recipe.files in
      let* output =
        Pkg_compile.compile ~tools ~scope ~wrapping:recipe.wrapping ~exports:recipe.exports
          ~sources:(module_sources files) ~c_sources:(native_sources files) ~directory ()
      in
      let archive = package_archive directory recipe in
      let* () = Pkg_toolchain.archive tools archive output.objects in
      let units = List.map (fun obj -> Filename.remove_extension obj ^ ".opt") output.objects
                  |> List.filter Sys.file_exists in
      Export_summary.write_archive ~archive ~units;
      write_file (Filename.concat directory "units") (String.concat "\n" output.units);
      (* The generated alias source is only needed while compiling the units. *)
      rm_rf (Filename.concat directory "aliases");
      Ok ())) in
  let directory = entry.directory in
  let units = read_file (Filename.concat directory "units") |> String.split_on_char '\n'
              |> List.filter (fun unit -> unit <> "") in
  let archive = package_archive directory recipe in
  let* outputs = Build_cache.fingerprints [archive; archive ^ ".opt"] in
  let id = Build_cache.key (("recipe", Sha256.to_hex key) :: outputs) in
  Ok {recipe; id; directory; archive; units}

let prepare_dependencies tools workspace (lock : lock) =
  let vendor = Pkg_project.vendor_dir workspace in
  let rec build packed = function
    | [] -> Ok (List.rev packed)
    | recipe :: rest ->
        let* pack = prepare_package tools ~vendor ~prior:(List.rev packed) recipe in
        build (pack :: packed) rest
  in
  build [] lock.packages

let files_with_suffix directory suffix =
  if not (Sys.file_exists directory && Sys.is_directory directory) then []
  else Sys.readdir directory |> Array.to_list |> List.sort String.compare
       |> List.filter (fun name -> Filename.check_suffix name suffix)
       |> List.map (Filename.concat directory)

let package_objects pack =
  files_with_suffix pack.directory ".o"
  @ files_with_suffix (Filename.concat pack.directory "private") ".o"

let rec gather_source directory =
  let names = Sys.readdir directory |> Array.to_list |> List.sort String.compare in
  List.concat_map (fun name ->
    if name = "" || name.[0] = '.' || name = "vendor" then []
    else
      let path = Filename.concat directory name in
      match (Unix.lstat path).st_kind with
      | Unix.S_DIR -> gather_source path
      | Unix.S_REG when Filename.check_suffix name ".ml" || Filename.check_suffix name ".mli" -> [path]
      | _ -> []) names

let include_sources root relative_paths =
  List.concat_map (fun relative -> gather_source (Rel_path.resolve ~root relative)) relative_paths

let inputs (workspace : Pkg_project.t) selected_test =
  let {entry; source_dirs; public_mli; _} = workspace.manifest in
  let root = workspace.root in
  let here = Rel_path.resolve ~root in
  let project = include_sources root source_dirs in
  let interfaces = List.map here public_mli in
  let entry, project =
    match selected_test with
    | None -> Option.map here entry, project
    | Some (test : test) ->
        let only_library = match entry with
          | None -> project
          | Some entry -> List.filter (fun source -> source <> here entry) project in
        Some (here test.entry), only_library @ gather_source (here test.source_dir)
  in
  let seen = Hashtbl.create (List.length project) in
  let add path =
    if Hashtbl.mem seen path || Some path = entry then false
    else (Hashtbl.add seen path (); true)
  in
  List.filter add (project @ interfaces) @ Option.to_list entry

let output_name tools kind name =
  match kind with
  | Exe -> if tools.Pkg_toolchain.target.os = Windows then name ^ ".exe" else name
  | Static -> "lib" ^ name ^ ".a"
  | Shared ->
      let ext = if tools.target.os = Darwin then ".dylib" else if tools.target.os = Windows then ".dll" else ".so" in
      "lib" ^ name ^ ext

let entry_point tools store modules =
  let key = Build_cache.key (["toolchain", Sha256.to_hex tools.Pkg_toolchain.fingerprint; "entry", "1"]
      @ List.map (fun name -> "module", name) modules) in
  let+ entry = Build_cache.ensure ~store ~key (fun directory ->
    let ssa = Filename.concat directory "entry.ssa" in
    let obj = Filename.concat directory "entry.o" in
    let entry = Codegen.entry_point modules in
    write_file ssa (Qbe_il.to_string {funcs = [entry]; datas = []});
    let+ () = Pkg_toolchain.assemble tools ssa obj in
    Sys.remove ssa) in
  Filename.concat entry.directory "entry.o"

let digest_objects paths =
  let+ digests = Build_cache.fingerprints paths in
  List.map (fun (_, digest) -> "object", digest) digests

let link tools ~workspace ~work_dir ~kind ~output ~user_objects ~internal_objects =
  let mode = match kind with
    | Exe -> Linker.Executable | Static -> Static | Shared -> Shared None
  in
  let extra_ldflags = workspace.Pkg_project.manifest.ldflags in
  let* fingerprints = digest_objects (user_objects @ internal_objects) in
  let key = Build_cache.key
      (["toolchain", Sha256.to_hex tools.Pkg_toolchain.fingerprint;
        "mode", (match kind with Exe -> "exe" | Static -> "static" | Shared -> "shared");
        "output", output]
        @ List.map (fun flag -> "ldflag", flag) extra_ldflags @ fingerprints) in
  let link_receipt = Filename.concat workspace.root ".ocpkg/cache/link" in
  mkdir_p link_receipt;
  let receipt = Filename.concat link_receipt (Sha256.to_hex key) in
  let hit =
    Sys.file_exists receipt && Sys.file_exists output &&
    match Sha256.file output with
    | Ok digest -> String.trim (read_file receipt) = Sha256.to_hex digest
    | Error _ -> false
  in
  if hit then Ok output
  else begin
    mkdir_p (Filename.dirname output);
    let temporary, channel = Filename.open_temp_file ~temp_dir:(Filename.dirname output) ".ocpkg-link-" "" in
    close_out channel;
    Fun.protect ~finally:(fun () -> rm_rf temporary) (fun () ->
      let* _ =
        Linker.link {mode; target = tools.target; toolchain = tools.commands; work_dir;
          output = temporary; user_objects; internal_objects; extra_ldflags; verbose = tools.verbose}
      in
      let+ digest = Sha256.file temporary in
      Unix.rename temporary output;
      write_if_changed receipt (Sha256.to_hex digest ^ "\n");
      output)
  end

let app_shims tools scope workspace work_dir output compiled_dir =
  match workspace.Pkg_project.manifest.public_mli with
  | [] -> Ok []
  | rel_paths ->
      let files = List.map (Rel_path.resolve ~root:workspace.root) rel_paths in
      let headers = Filename.remove_extension output ^ ".h" in
      let interfaces = List.map (fun path -> Pipeline.module_name_of_file path, path) files in
      let include_dirs = compiled_dir :: tools.Pkg_toolchain.stdlib :: scope.Pkg_compile.visible in
      let* generated = C_bindgen.generate_headers ~include_dirs ~nopervasives:false ~nostdlib:true
          ~work_dir ~output:headers interfaces in
      Linker.compile_many ~verbose:tools.verbose ~work_dir tools.commands
        (["-std=c99"; "-O2"; "-fPIC"; "-I" ^ Filename.dirname headers] @ tools.cflags)
        generated.shim_files

let build_target (workspace : Pkg_project.t) (options : options) selected_test =
  let kind = Option.value ~default:workspace.manifest.kind options.kind in
  let single_thread = options.single_thread || workspace.manifest.single_thread_rc in
  let* lock = Pkg_project.read_lock workspace in
  let* () = Pkg_vendor.verify ~vendor:(Pkg_project.vendor_dir workspace) lock.packages in
  let* tools = Pkg_toolchain.prepare ~target:options.target ~single_thread
      ~cflags:workspace.manifest.cflags ~verbose:options.verbose in
  let* packs = prepare_dependencies tools workspace lock in
  let catalog_exe =
    if workspace.manifest.source_dirs = [] && workspace.manifest.entry = None then
      List.find_map (fun pack ->
        if pack.recipe.package.name = workspace.manifest.project
        then pack.recipe.executable else None) packs
    else None
  in
  let name =
    match selected_test, catalog_exe with
    | Some (test : test), _ -> "test-" ^ Package_name.to_string test.name
    | None, Some executable -> Package_name.to_string executable
    | None, None -> Package_name.to_string workspace.manifest.project
  in
  let output =
    match options.output with
    | Some path when Filename.is_relative path -> Filename.concat (Sys.getcwd ()) path
    | Some path -> path
    | None -> Filename.concat workspace.root (".ocpkg/bin/" ^ output_name tools kind name)
  in
  let root = Filename.concat workspace.root ".ocpkg" in
  mkdir_p root;
  let work_dir = Filename.temp_dir ~temp_dir:root "build-" "" in
  Fun.protect ~finally:(fun () -> rm_rf work_dir) (fun () ->
    let sources = inputs workspace selected_test in
    if sources = [] && catalog_exe = None then Error "no OCaml sources in the project"
    else
      let compiled_dir = Filename.concat work_dir "units" in
      let cache = Filename.concat root "cache/unit" in
      let scope = package_scope packs in
      let c_sources = List.map (Rel_path.resolve ~root:workspace.root) workspace.manifest.c_sources in
      let* app =
        Pkg_compile.compile ~tools ~scope ~wrapping:Flat ~exports:[] ~cache
          ~sources ~c_sources ~directory:compiled_dir ()
      in
      if tools.verbose then
        Printf.eprintf "%d fresh units, %d cached units\n%!" app.compiled app.hits;
      let* shims = app_shims tools scope workspace work_dir output compiled_dir in
      let modules = List.concat_map (fun pack -> pack.units) packs @ app.units in
      let* entry = match kind with
        | Exe -> let+ obj = entry_point tools cache modules in [obj]
        | _ -> Ok []
      in
      let archives =
        if kind = Static then List.concat_map package_objects packs
        else List.rev_map (fun pack -> pack.archive) packs
      in
      let user_objects = entry @ app.objects @ shims @ archives in
      let include_main = kind = Exe in
      let* runtime = Pkg_toolchain.runtime tools ~include_main in
      let internal_objects = Pkg_toolchain.stdlib_link_inputs tools ~archive:include_main @ runtime in
      link tools ~workspace ~work_dir ~kind ~output ~user_objects ~internal_objects)

let protect f =
  try f () with
  | Sys_error msg -> Error msg
  | Cmi_format.Error _ as error -> Error (Printexc.to_string error)
  | Unix.Unix_error (code, op, path) ->
      Error (Printf.sprintf "%s %s: %s" op path (Unix.error_message code))

let build workspace options = protect (fun () -> build_target workspace options None)

let run workspace options args =
  protect (fun () ->
    let* output = build workspace {options with kind = Some Exe} in
    Unix.chdir workspace.Pkg_project.root;
    Unix.execv output (Array.of_list (output :: args)))

let test workspace options selectors =
  protect (fun () ->
    let tests = workspace.Pkg_project.manifest.tests in
    let choose value =
      List.find_opt (fun (test : test) -> Package_name.to_string test.name = value) tests
    in
    let rec select chosen = function
      | [] -> Ok (List.rev chosen)
      | name :: rest ->
          match choose name with
          | None -> Error ("unknown test: " ^ name)
          | Some test -> select (test :: chosen) rest
    in
    let* tests = if selectors = [] then Ok tests else select [] selectors in
    let rec run = function
      | [] -> Ok ()
      | test :: rest ->
          let* path = build_target workspace {options with kind = Some Exe; output = None} (Some test) in
          let* () = run_cmd ~verbose:options.verbose path [] in
          run rest
    in
    run tests)
