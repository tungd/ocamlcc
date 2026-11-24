open Ocpkg_format
open Sys_util
open Result_syntax

module Product = struct
  type t = Native of { target : string; kind : kind option } | Xcframework
end

type options = {
  product : Product.t;
  output : string option;
  single_thread : bool;
  verbose : bool;
  verify_cache : bool;
  emit_header : string option;
  jobs : int;
  progress : bool;
  mode : Build_mode.t;
  debug_info : bool option;
}

let defaults = {
  product = Native {target = "host"; kind = None}; output = None;
  single_thread = false; verbose = false; verify_cache = false; emit_header = None;
  jobs = Pkg_parallel.default_jobs (); progress = true;
  mode = Build_mode.Release; debug_info = None;
}

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

type pkg_event =
  | Pkg_compiling of int
  | Pkg_unit of int * Pkg_compile.event

type prepared_pack = {
  pack : pack;
  hit : bool;
  compiled : int;
  elapsed : float;
}

let prepare_package_task tools ~vendor ~held ~prior recipe =
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
  let finish_pack ~hit ~compiled ~elapsed directory =
    let units = read_file (Filename.concat directory "units") |> String.split_on_char '\n'
                |> List.filter (fun unit -> unit <> "") in
    let archive = package_archive directory recipe in
    let+ outputs = Build_cache.fingerprints ~hasher:(Digest_index.hasher tools.index) [archive; archive ^ ".opt"] in
    let id = Build_cache.key (("recipe", Sha256.to_hex key) :: outputs) in
    { pack = {recipe; id; directory; archive; units}; hit; compiled; elapsed }
  in
  let hasher = Digest_index.hasher tools.Pkg_toolchain.index in
  match Build_cache.peek ~hasher ~store ~key () with
  | Some entry ->
      let+ prepared = finish_pack ~hit:true ~compiled:0 ~elapsed:0.0 entry.directory in
      `Ready prepared
  | None ->
      Ok (`Run (fun report ->
        let started = Unix.gettimeofday () in
        let compiled_count = ref 0 in
        let* entry = Build_cache.ensure ~hasher ~store ~key (fun directory ->
          let source_root = Filename.concat vendor (package_name recipe) in
          let staging = Filename.temp_dir "ocpkg-package-" "" in
          Fun.protect ~finally:(fun () -> rm_rf staging) (fun () ->
            let files = List.map (fun item ->
                let source = Rel_path.resolve ~root:source_root (Comp_input.source item) in
                let target = Filename.concat staging (Comp_input.name item) in
                write_file target (read_file source);
                target) recipe.files in
            let sources = module_sources files in
            let c_sources = native_sources files in
            report (Pkg_compiling (List.length sources + List.length c_sources));
            let* output =
              Pkg_compile.compile ~tools ~scope ~wrapping:recipe.wrapping ~exports:recipe.exports
                ~cflags:recipe.cflags ~held
                ~on_event:(fun total ev -> report (Pkg_unit (total, ev)))
                ~sources ~c_sources ~directory ()
            in
            compiled_count := output.compiled;
            let archive = package_archive directory recipe in
            let* () = Pkg_toolchain.archive tools archive output.objects in
            let units = List.map (fun obj -> Filename.remove_extension obj ^ ".opt") output.objects
                        |> List.filter Sys.file_exists in
            Export_summary.write_archive ~archive ~units;
            write_file (Filename.concat directory "units") (String.concat "\n" output.units);
            (* The generated alias source is only needed while compiling the units. *)
            rm_rf (Filename.concat directory "aliases");
            Ok ())) in
        let elapsed = Unix.gettimeofday () -. started in
        finish_pack ~hit:entry.hit ~compiled:!compiled_count ~elapsed entry.directory))

let prepare_dependencies tools workspace (lock : lock) =
  let vendor = Pkg_project.vendor_dir workspace in
  let recipes = Array.of_list lock.packages in
  let n = Array.length recipes in
  if n = 0 then Ok []
  else begin
    let index_by_name = Hashtbl.create n in
    Array.iteri (fun i recipe -> Hashtbl.replace index_by_name recipe.package.name i) recipes;
    let deps i =
      List.filter_map (fun dep -> Hashtbl.find_opt index_by_name dep) recipes.(i).dependencies
    in
    let child_held = Pkg_parallel.Pool.jobs tools.Pkg_toolchain.pool > 1 && not Sys.win32 in
    let scope = Pkg_progress.start_scope tools.progress ~prefix:"deps" ~total:n in
    let unit_done = Array.make n 0 in
    let done_count = ref 0 in
    let on_event i = function
      | Pkg_compiling _ ->
          let name = package_name recipes.(i) in
          Pkg_progress.task_started scope ~id:i ~name
      | Pkg_unit (total, ev) ->
          let name = package_name recipes.(i) in
          let path = match ev with
            | Pkg_compile.Start (_, p) -> p
            | Pkg_compile.Finish (_, p, _) ->
                unit_done.(i) <- unit_done.(i) + 1;
                p
          in
          Pkg_progress.task_detail scope ~id:i
            (Printf.sprintf "%s (%d/%d %s)" name unit_done.(i) total (Filename.basename path))
    in
    let on_done i (prepared : prepared_pack) =
      incr done_count;
      let name = package_name recipes.(i) in
      let milestone =
        if prepared.hit then None
        else
          Some (Printf.sprintf "[deps %d/%d] Built %s (%d units, %s)"
                  !done_count n name prepared.compiled (Pkg_progress.format_duration prepared.elapsed))
      in
      Pkg_progress.task_finished ?milestone ~id:i ~cached:prepared.hit scope
    in
    let prepare i results =
      let prior =
        Array.fold_left (fun acc item ->
          match item with Some p -> p.pack :: acc | None -> acc) [] results
        |> List.rev
      in
      prepare_package_task tools ~vendor ~held:child_held ~prior recipes.(i)
    in
    let res =
      Pkg_parallel.run_dag ~pool:tools.pool ~held:false ~index:tools.index
        ~on_event ~on_done ~deps ~prepare n
    in
    Pkg_progress.end_scope scope;
    Result.map (fun arr -> Array.to_list arr |> List.map (fun p -> p.pack)) res
  end

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
  let+ entry = Build_cache.ensure ~hasher:(Digest_index.hasher tools.Pkg_toolchain.index) ~store ~key (fun directory ->
    let ssa = Filename.concat directory "entry.ssa" in
    let obj = Filename.concat directory "entry.o" in
    let entry = Codegen.entry_point modules in
    write_file ssa (Qbe_il.to_string {funcs = [entry]; datas = []});
    let+ () = Pkg_toolchain.assemble tools ssa obj in
    Sys.remove ssa) in
  Filename.concat entry.directory "entry.o"

let digest_objects index ~work_dir paths =
  let temporary = work_dir ^ Filename.dir_sep in
  let rec collect fields = function
    | [] -> Ok (List.rev fields)
    | path :: rest ->
        let file =
          if String.starts_with ~prefix:temporary path then Sha256.file
          else Digest_index.file index in
        let* digest = file path in
        collect (("object", Sha256.to_hex digest) :: fields) rest
  in
  collect [] paths

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
  let* receipt =
    (* Custom flags can load libraries and other files outside the object list. *)
    if kind <> Static && ldflags <> [] then Ok None
    else
      let+ fingerprints = digest_objects tools.index ~work_dir (user_objects @ internal_objects) in
      let key = Build_cache.key
          (["toolchain", Sha256.to_hex tools.Pkg_toolchain.fingerprint;
            "mode", (match kind with Exe -> "exe" | Static -> "static" | Shared -> "shared");
            "output", output]
            @ List.map (fun flag -> "ldflag", flag) extra_ldflags @ fingerprints) in
      let link_receipt = Filename.concat workspace.root ".ocpkg/cache/link" in
      mkdir_p link_receipt;
      Some (Filename.concat link_receipt (Sha256.to_hex key))
  in
  let hit =
    Option.exists (fun receipt ->
      Sys.file_exists receipt &&
      match Unix.lstat output with
      | {Unix.st_kind = Unix.S_REG; _} ->
          let usable =
            if kind <> Exe || Sys.win32 then true
            else match Unix.access output [Unix.X_OK] with
            | () -> true
            | exception Unix.Unix_error ((Unix.EACCES | Unix.ENOENT), _, _) -> false
          in
          usable && (match Digest_index.file tools.index output with
            | Ok digest -> String.trim (read_file receipt) = Sha256.to_hex digest
            | Error _ -> false)
      | _ | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false) receipt
  in
  if hit then Ok output
  else begin
    Pkg_progress.milestone tools.progress (Printf.sprintf "[link] %s" (Filename.basename output));
    mkdir_p (Filename.dirname output);
    let temporary, channel = Filename.open_temp_file ~temp_dir:(Filename.dirname output) ".ocpkg-link-" "" in
    close_out channel;
    Fun.protect ~finally:(fun () -> rm_rf temporary) (fun () ->
      let* _ =
        Linker.link {mode; target = tools.target; toolchain = tools.commands; work_dir;
          output = temporary; user_objects; internal_objects; extra_ldflags; verbose = tools.verbose}
      in
      let+ seal =
        match receipt with
        | None -> Ok None
        | Some receipt ->
            let+ digest = Sha256.file temporary in
            Some (receipt, Sha256.to_hex digest ^ "\n") in
      Unix.rename temporary output;
      Option.iter (fun (receipt, digest) -> write_if_changed receipt digest) seal;
      output)
  end

let app_shims tools ~held scope (workspace : Pkg_project.t) options ~sources ~cache ~output ~compiled_dir =
  let files =
    match workspace.manifest.public_mli, options.emit_header with
    | [], Some _ -> List.filter (fun path -> Filename.check_suffix path ".mli") sources
    | paths, _ -> List.map (Rel_path.resolve ~root:workspace.root) paths
  in
  match files, options.emit_header with
  | [], None -> Ok []
  | [], Some _ -> Error "--emit-header requires at least one .mli input"
  | files, emit_header ->
      let header_output = Option.value ~default:(Filename.remove_extension output ^ ".h") emit_header in
      let header = Filename.basename header_output in
      let interfaces = List.map (fun path -> Pipeline.module_name_of_file path, path) files in
      let include_dirs = compiled_dir :: tools.Pkg_toolchain.stdlib :: scope.Pkg_compile.visible in
      let* digests = Build_cache.fingerprints (files @ files_with_suffix compiled_dir ".cmi") in
      let digests = List.map (fun (path, hash) -> Filename.basename path, hash) digests in
      let dependencies = List.map (fun key -> "dependency", Sha256.to_hex key) scope.package_keys in
      let key = Build_cache.key (["toolchain", Sha256.to_hex tools.fingerprint; "bindings", "1"; "header", header]
          @ dependencies @ digests) in
      let* entry = Build_cache.ensure ~hasher:(Digest_index.hasher tools.Pkg_toolchain.index) ~store:cache ~key (fun directory ->
        let headers = Filename.concat directory "headers" in
        let* generated = C_bindgen.generate_headers ~include_dirs ~nopervasives:false ~nostdlib:true
            ~work_dir:directory ~output:(Filename.concat headers header) interfaces in
        let pic = if tools.target.os = Windows then [] else ["-fPIC"] in
        let flags = ["-std=c99"] @ Build_mode.cflags ~debug_info:tools.debug_info tools.mode @ ["-I" ^ headers] @ pic @ tools.cflags in
        let tasks =
          List.mapi (fun index source ->
            fun _report ->
              let base = Filename.chop_extension (Filename.basename source) in
              let object_file = Filename.concat directory (Printf.sprintf "u_%d_%s.o" index base) in
              let+ () = Linker.compile_source ~verbose:tools.verbose tools.commands flags source object_file in
              object_file) generated.shim_files
        in
        let+ _ = Pkg_parallel.map ~pool:tools.pool ~held tasks in
        List.iter Sys.remove generated.shim_files) in
      let destination = Filename.dirname header_output in
      let headers = files_with_suffix (Filename.concat entry.directory "headers") "" in
      mkdir_p destination;
      let collides path =
        Filename.basename path = Filename.basename output &&
        Sys.file_exists (Filename.dirname output) &&
        Unix.realpath destination = Unix.realpath (Filename.dirname output)
      in
      if List.exists collides headers then Error "the library or executable and its headers need distinct paths"
      else begin
        List.iter (fun path ->
          write_if_changed (Filename.concat destination (Filename.basename path)) (read_file path)) headers;
        Ok (files_with_suffix entry.directory ".o")
      end

let short_path ~root path =
  let prefix = if String.ends_with ~suffix:Filename.dir_sep root then root else root ^ Filename.dir_sep in
  if String.starts_with ~prefix path then
    String.sub path (String.length prefix) (String.length path - String.length prefix)
  else path

let build_target ?pool ?(held = false) ?progress (workspace : Pkg_project.t) (options : options) ~target ~kind selected_test =
  let owned_pool, pool =
    match pool with
    | Some p -> None, p
    | None -> let p = Pkg_parallel.Pool.create options.jobs in Some p, p
  in
  let owned_progress, progress =
    match progress with
    | Some p -> None, p
    | None ->
        let p = Pkg_progress.create ~enabled:options.progress ~verbose:options.verbose in
        Some p, p
  in
  Fun.protect ~finally:(fun () ->
    Option.iter Pkg_progress.finish owned_progress;
    Option.iter Pkg_parallel.Pool.close owned_pool) (fun () ->
  let single_thread = options.single_thread || workspace.manifest.single_thread_rc in
  let* cache = Pkg_project.cache_dir () in
  Digest_index.with_index ~cache ~workspace:workspace.root ~verify:options.verify_cache (fun index ->
  let* lock = Pkg_project.read_lock workspace in
  let* () = Pkg_vendor.verify ~index ~vendor:(Pkg_project.vendor_dir workspace) lock.packages in
  let* tools = Pkg_toolchain.prepare ~index ~cache ~target ~single_thread
      ~cflags:workspace.manifest.cflags ~verbose:options.verbose
      ~mode:options.mode ?debug_info:options.debug_info ~pool ~held ~progress () in
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
      let app_scope = ref None in
      let app_done = ref 0 in
      let app_started = Unix.gettimeofday () in
      let on_event total ev =
        let s = match !app_scope with
          | Some s -> s
          | None ->
              let s = Pkg_progress.start_scope tools.progress ~prefix:"app" ~total in
              app_scope := Some s;
              s
        in
        match ev with
        | Pkg_compile.Start (id, path) ->
            Pkg_progress.task_started s ~id ~name:(short_path ~root:workspace.root path)
        | Pkg_compile.Finish (id, path, cached) ->
            incr app_done;
            let rel = short_path ~root:workspace.root path in
            let milestone =
              if cached then None
              else Some (Printf.sprintf "[%d/%d] Compiled %s" !app_done total rel)
            in
            Pkg_progress.task_finished ?milestone ~id ~cached s
      in
      let* app =
        let res =
          Pkg_compile.compile ~tools ~scope ~wrapping:Flat ~exports:[] ~cache
            ~held ~on_event ~sources ~c_sources ~directory:compiled_dir ()
        in
        Option.iter (fun s ->
          let elapsed = Pkg_progress.format_duration (Unix.gettimeofday () -. app_started) in
          let summary = match res with
            | Ok app -> Some (Printf.sprintf "Built %s (%d compiled, %d cached, %s)" name app.compiled app.hits elapsed)
            | Error _ -> None
          in
          Pkg_progress.end_scope ?summary s) !app_scope;
        res
      in
      if tools.verbose then
        Printf.eprintf "%d fresh units, %d cached units\n%!" app.compiled app.hits;
      let* shims = app_shims tools ~held scope workspace options ~sources ~cache ~output ~compiled_dir in
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
      let* runtime = Pkg_toolchain.runtime ~held tools ~include_main in
      let internal_objects = Pkg_toolchain.stdlib_link_inputs tools ~archive:include_main @ runtime in
      let dependency_ldflags = List.concat_map (fun pack -> pack.recipe.ldflags) (List.rev packs) in
      link tools ~workspace ~work_dir ~kind ~output ~user_objects ~internal_objects ~dependency_ldflags)))

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
    let slice_spec = [("ios-arm64", "device"); ("ios-sim-arm64", "simulator")] in
    let pool = Pkg_parallel.Pool.create options.jobs in
    let progress = Pkg_progress.create ~enabled:options.progress ~verbose:options.verbose in
    Fun.protect ~finally:(fun () -> Pkg_progress.finish progress; Pkg_parallel.Pool.close pool) (fun () ->
    let parallel_slices = Pkg_parallel.Pool.jobs pool >= 2 && not Sys.win32 in
    let slice_progress =
      if parallel_slices then Pkg_progress.create ~enabled:false ~verbose:options.verbose
      else progress
    in
    let slice target name =
      let path = Filename.concat temporary (name ^ ".a") in
      let directory = if headers then Some (Filename.concat temporary name) else None in
      let emit_header = Option.map (fun dir -> Filename.concat dir header_basename) directory in
      let options = {options with output = Some path; emit_header} in
      let+ library =
        build_target ~pool ~held:parallel_slices ~progress:slice_progress
          workspace options ~target ~kind:Static None
      in
      { Linker.Xcframework_slice.library; headers = directory }
    in
    let* slices =
      if parallel_slices then begin
        let scope = Pkg_progress.start_scope progress ~prefix:"xcframework" ~total:2 in
        let tasks =
          List.map (fun (target, slice_name) ->
            fun _report -> slice target slice_name) slice_spec
        in
        let res =
          Pkg_parallel.map ~pool ~held:false
            ~on_start:(fun i ->
              let target, _ = List.nth slice_spec i in
              Pkg_progress.task_started scope ~id:i ~name:target)
            ~on_done:(fun i _ ->
              let target, _ = List.nth slice_spec i in
              Pkg_progress.task_finished
                ~milestone:(Printf.sprintf "[xcframework %d/2] Built %s" (i + 1) target)
                ~id:i ~cached:false scope)
            tasks
        in
        Pkg_progress.end_scope scope;
        res
      end else
        let* device = slice "ios-arm64" "device" in
        let+ simulator = slice "ios-sim-arm64" "simulator" in
        [device; simulator]
    in
    let device = List.hd slices in
    let product = Filename.concat temporary "product" in
    Unix.mkdir product 0o700;
    let staged = Filename.concat product (Filename.basename output) in
    let* _ = Linker.xcframework ~verbose:options.verbose ~output:staged slices in
    let previous = Filename.concat temporary ".previous" in
    let had_previous = Sys.file_exists output in
    if had_previous && not (Sys.file_exists (Filename.concat output "Info.plist")) then
      Error ("output is not an XCFramework: " ^ output)
    else begin
      if had_previous then Unix.rename output previous;
      (try Unix.rename staged output with error ->
        if had_previous then Unix.rename previous output;
        raise error);
      (match options.emit_header, device.headers with
       | Some destination, Some directory ->
           mkdir_p (Filename.dirname destination);
           Array.iter (fun file ->
             write_if_changed (Filename.concat (Filename.dirname destination) file)
               (read_file (Filename.concat directory file))) (Sys.readdir directory)
       | _ -> ());
      Ok output
    end))

let build workspace options =
  protect (fun () ->
    Pkg_project.with_dependencies workspace (fun workspace ->
      match options.product with
      | Xcframework -> build_xcframework workspace options
      | Native {target; kind} ->
          let kind = Option.value ~default:workspace.manifest.kind kind in
          build_target workspace options ~target ~kind None))

let executable_target command = function
  | Product.Native {target; kind = None | Some Exe} -> Ok target
  | Native {kind = Some (Shared | Static); _} | Xcframework ->
      Error (command ^ " requires an executable target")

let run workspace options args =
  protect (fun () ->
    let* target = executable_target "run" options.product in
    let* output = Pkg_project.with_dependencies workspace (fun workspace ->
      build_target workspace options ~target ~kind:Exe None) in
    Unix.chdir workspace.Pkg_project.root;
    Unix.execv output (Array.of_list (output :: args)))

let test workspace options selectors args =
  protect (fun () ->
      let* target = executable_target "test" options.product in
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
              let* path = Pkg_project.with_dependencies workspace (fun workspace ->
                build_target workspace {options with output = None} ~target ~kind:Exe (Some test)) in
              run_cmd ~verbose:options.verbose path args in
            match result with
            | Ok () -> Printf.printf "PASS %s\n%!" name; run (passed + 1) failed rest
            | Error message ->
                Printf.eprintf "FAIL %s: %s\n%!" name message;
                run passed (failed + 1) rest
      in
      run 0 0 tests)
