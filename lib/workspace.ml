open Ocpkg_format
open Sys_util
open Result_syntax

type options = {
  target : string;
  kind : kind option;
  output : string option;
  single_thread : bool;
  verbose : bool;
  verify_cache : bool;
  xcframework : bool;
  emit_header : string option;
}

let defaults = {target = "host"; kind = None; output = None; single_thread = false; verbose = false; verify_cache = false; xcframework = false; emit_header = None}

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
  let* entry = Build_cache.ensure ~index:tools.Pkg_toolchain.index ~store ~key (fun directory ->
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
          ~cflags:recipe.cflags ~sources:(module_sources files) ~c_sources:(native_sources files) ~directory ()
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
  let* outputs = Build_cache.fingerprints ~index:tools.index [archive; archive ^ ".opt"] in
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
      let ext = match tools.target.os with
        | Darwin | Ios | Ios_sim -> ".dylib"
        | Windows -> ".dll"
        | Linux | Android -> ".so"
      in
      "lib" ^ name ^ ext

let entry_point tools store modules =
  let key = Build_cache.key (["toolchain", Sha256.to_hex tools.Pkg_toolchain.fingerprint; "entry", "1"]
      @ List.map (fun name -> "module", name) modules) in
  let+ entry = Build_cache.ensure ~index:tools.Pkg_toolchain.index ~store ~key (fun directory ->
    let ssa = Filename.concat directory "entry.ssa" in
    let obj = Filename.concat directory "entry.o" in
    let entry = Codegen.entry_point modules in
    write_file ssa (Qbe_il.to_string {funcs = [entry]; datas = []});
    let+ () = Pkg_toolchain.assemble tools ssa obj in
    Sys.remove ssa) in
  Filename.concat entry.directory "entry.o"

let digest_objects index paths =
  let+ digests = Build_cache.fingerprints ~index paths in
  List.map (fun (_, digest) -> "object", digest) digests

let link tools ~workspace ~work_dir ~kind ~output ~user_objects ~internal_objects ~dependency_ldflags =
  let mode = match kind with
    | Exe -> Linker.Executable | Static -> Static | Shared -> Shared None
  in
  let ldflags = dependency_ldflags @ workspace.Pkg_project.manifest.ldflags in
  let explicit_install_name =
    List.exists (fun flag ->
      String.split_on_char ',' flag |> List.exists (fun part ->
        part = "-install_name" || String.starts_with ~prefix:"-install_name=" part)) ldflags
  in
  let extra_ldflags =
    match kind, tools.Pkg_toolchain.target.os with
    | Shared, (Darwin | Ios | Ios_sim) when not explicit_install_name ->
        ["-Xlinker"; "-install_name"; "-Xlinker"; output] @ ldflags
    | _ -> ldflags
  in
  let* fingerprints = digest_objects tools.index (user_objects @ internal_objects) in
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
    match Digest_index.file tools.index output with
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

let app_shims tools scope (workspace : Pkg_project.t) options ~sources ~cache ~output ~compiled_dir =
  let files =
    match workspace.manifest.public_mli, options.emit_header with
    | [], Some _ -> List.filter (fun path -> Filename.check_suffix path ".mli") sources
    | paths, _ -> List.map (Rel_path.resolve ~root:workspace.root) paths
  in
  match files, options.emit_header with
  | [], None -> Ok []
  | [], Some _ -> Error "--emit-header requires at least one .mli input"
  | files, emit_header ->
      let output = Option.value ~default:(Filename.remove_extension output ^ ".h") emit_header in
      let header = Filename.basename output in
      let interfaces = List.map (fun path -> Pipeline.module_name_of_file path, path) files in
      let include_dirs = compiled_dir :: tools.Pkg_toolchain.stdlib :: scope.Pkg_compile.visible in
      let* digests = Build_cache.fingerprints (files @ files_with_suffix compiled_dir ".cmi") in
      let digests = List.map (fun (path, hash) -> Filename.basename path, hash) digests in
      let dependencies = List.map (fun key -> "dependency", Sha256.to_hex key) scope.package_keys in
      let key = Build_cache.key (["toolchain", Sha256.to_hex tools.fingerprint; "header", header]
          @ dependencies @ digests) in
      let+ entry = Build_cache.ensure ~index:tools.Pkg_toolchain.index ~store:cache ~key (fun directory ->
        let* generated = C_bindgen.generate_headers ~include_dirs ~nopervasives:false ~nostdlib:true
            ~work_dir:directory ~output:(Filename.concat directory header) interfaces in
        let pic = if tools.target.os = Windows then [] else ["-fPIC"] in
        let flags = ["-std=c99"; "-O2"; "-I" ^ directory] @ pic @ tools.cflags in
        let+ _ = Linker.compile_many ~verbose:tools.verbose ~work_dir:directory
            tools.commands flags generated.shim_files in
        List.iter Sys.remove generated.shim_files) in
      let destination = Filename.dirname output in
      mkdir_p destination;
      List.iter (fun path ->
        write_if_changed (Filename.concat destination (Filename.basename path)) (read_file path))
        (files_with_suffix entry.directory ".h"
         |> fun paths ->
           let primary = Filename.concat entry.directory header in
           if List.mem primary paths then paths else primary :: paths);
      files_with_suffix entry.directory ".o"

let build_target (workspace : Pkg_project.t) (options : options) selected_test =
  let kind = Option.value ~default:workspace.manifest.kind options.kind in
  let single_thread = options.single_thread || workspace.manifest.single_thread_rc in
  let* cache = Pkg_project.cache_dir () in
  Digest_index.with_index ~cache ~workspace:workspace.root ~verify:options.verify_cache (fun index ->
  let* lock = Pkg_project.read_lock workspace in
  let* () = Pkg_vendor.verify ~index ~vendor:(Pkg_project.vendor_dir workspace) lock.packages in
  let* tools = Pkg_toolchain.prepare ~index ~cache ~target:options.target ~single_thread
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
      let* shims = app_shims tools scope workspace options ~sources ~cache ~output ~compiled_dir in
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
      let dependency_ldflags = List.concat_map (fun pack -> pack.recipe.ldflags) (List.rev packs) in
      link tools ~workspace ~work_dir ~kind ~output ~user_objects ~internal_objects ~dependency_ldflags))

let protect f =
  try f () with
  | Sys_error msg -> Error msg
  | Cmi_format.Error _ as error -> Error (Printexc.to_string error)
  | Unix.Unix_error (code, op, path) ->
      Error (Printf.sprintf "%s %s: %s" op path (Unix.error_message code))

let build_xcframework (workspace : Pkg_project.t) options =
  let name = Package_name.to_string workspace.manifest.project in
  let default = Filename.concat workspace.root (".ocpkg/bin/" ^ name ^ ".xcframework") in
  let output = Option.value ~default options.output in
  let output = if Filename.is_relative output then Filename.concat (Sys.getcwd ()) output else output in
  mkdir_p (Filename.dirname output);
  let temporary = Filename.temp_dir ~temp_dir:(Filename.dirname output) ".xcframework-" "" in
  Fun.protect ~finally:(fun () -> rm_rf temporary) (fun () ->
    let sources = inputs workspace None in
    let headers = workspace.manifest.public_mli <> [] || options.emit_header <> None ||
      List.exists (fun path -> Filename.check_suffix path ".mli") sources in
    let header_basename = Option.fold ~none:(name ^ ".h") ~some:Filename.basename options.emit_header in
    let slice target name =
      let path = Filename.concat temporary (name ^ ".a") in
      let directory = if headers then Some (Filename.concat temporary name) else None in
      let emit_header = Option.map (fun dir -> Filename.concat dir header_basename) directory in
      let options = {options with target; kind = Some Static; output = Some path; emit_header} in
      let+ library = build_target workspace options None in
      library, directory
    in
    let* device, device_headers = slice "ios-arm64" "device" in
    let* simulator, simulator_headers = slice "ios-sim-arm64" "simulator" in
    let staged = Filename.concat temporary (Filename.basename output) in
    let* _ = Linker.xcframework ~verbose:options.verbose ~work_dir:temporary ~output:staged ~header:None
      ~header_dirs:[device_headers; simulator_headers] [device; simulator] in
    let previous = Filename.concat temporary ".previous" in
    let had_previous = Sys.file_exists output in
    if had_previous && not (Sys.file_exists (Filename.concat output "Info.plist")) then
      Error ("output is not an XCFramework: " ^ output)
    else begin
      if had_previous then Unix.rename output previous;
      (try Unix.rename staged output with error ->
        if had_previous then Unix.rename previous output;
        raise error);
      (match options.emit_header, device_headers with
       | Some destination, Some directory ->
           mkdir_p (Filename.dirname destination);
           Array.iter (fun file ->
             write_if_changed (Filename.concat (Filename.dirname destination) file)
               (read_file (Filename.concat directory file))) (Sys.readdir directory)
       | _ -> ());
      Ok output
    end)

let is_xcframework options = options.xcframework || options.target = "ios-xcframework"

let build workspace options =
  protect (fun () ->
    if is_xcframework options then build_xcframework workspace options
    else build_target workspace options None)

let run workspace options args =
  protect (fun () ->
    if is_xcframework options then Error "run requires an executable target"
    else
      let* output = build workspace {options with kind = Some Exe} in
      Unix.chdir workspace.Pkg_project.root;
      Unix.execv output (Array.of_list (output :: args)))

let test workspace options selectors args =
  protect (fun () ->
    if is_xcframework options then Error "test requires an executable target"
    else
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
      Unix.chdir workspace.root;
      let rec run passed failed = function
        | [] ->
            Printf.printf "%d passed, %d failed (%d tests)\n%!" passed failed (passed + failed);
            if failed = 0 then Ok () else Error "test failures"
        | test :: rest ->
            let name = Package_name.to_string test.name in
            let result =
              let* path = build_target workspace {options with kind = Some Exe; output = None} (Some test) in
              run_cmd ~verbose:options.verbose path args in
            match result with
            | Ok () -> Printf.printf "PASS %s\n%!" name; run (passed + 1) failed rest
            | Error message ->
                Printf.eprintf "FAIL %s: %s\n%!" name message;
                run passed (failed + 1) rest
      in
      run 0 0 tests)
