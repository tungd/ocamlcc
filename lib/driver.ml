open Sys_util
open Result_syntax

(* Single-binary build driver: dependency-ordered .mli/.ml compilation,
   QBE target assembly, C/NDK/xcrun toolchain invocation, optional C header +
   FFI shim generation, and runtime/stdlib linking. *)

type target_os = Target.os =
  | Darwin
  | Linux
  | Ios
  | Ios_sim
  | Android
  | Windows

type target_spec = Target.t = {
  name : string;
  qbe_target : string;
  os : target_os;
  arch : string;
}

type output_kind =
  | Kind_exe
  | Kind_shared
  | Kind_static
  | Kind_obj
  | Kind_asm
  | Kind_xcframework

type build_step = Dep_graph.Step.t = {
  modname : string;
  kind : [ `Mli | `Ml ];
  path : string;
}

type config = {
  inputs : string list;
  output : string option;
  target : string option;
  kind : output_kind option;
  include_dirs : string list;
  nostdlib : bool;
  nopervasives : bool;
  no_main : bool;
  emit_header : string option;
  qbe_path : string option;
  cc_path : string option;
  ar_path : string option;
  sysroot : string option;
  runtime_dir : string option;
  prebuilt_rt_dir : string option;
  inline_single_thread_rc : bool;
  stdlib_src_dir : string option;
  prebuilt_stdlib_dir : string option;
  work_dir : string option;
  mode : Build_mode.t;
  debug_info : bool;
  cache_dir : string option;
  no_cache : bool;
  extra_cflags : string list;
  extra_ldflags : string list;
  verbose : bool;
}

let default_config () =
  { inputs = [];
    output = None;
    target = None;
    kind = None;
    include_dirs = [];
    nostdlib = false;
    nopervasives = false;
    no_main = false;
    emit_header = None;
    qbe_path = None;
    cc_path = None;
    ar_path = None;
    sysroot = None;
    runtime_dir = None;
    prebuilt_rt_dir = None;
    inline_single_thread_rc = false;
    stdlib_src_dir = None;
    prebuilt_stdlib_dir = None;
    work_dir = None;
    mode = Build_mode.Release;
    debug_info = false;
    cache_dir = None;
    no_cache = false;
    extra_cflags = [];
    extra_ldflags = [];
    verbose = false }

let resolve_target = Target.resolve

(* Extract module references using compiler-libs Depend. *)
let plan_build_order = Dep_graph.plan_build_order

let infer_kind cfg =
  match cfg.kind with
  | Some k -> k
  | None -> (
      match cfg.target with
      | Some t when String.lowercase_ascii t = "ios-xcframework" ->
          Kind_xcframework
      | _ -> (
          match cfg.output with
          | Some o ->
              if Filename.check_suffix o ".so" || Filename.check_suffix o ".dylib"
              then Kind_shared
              else if Filename.check_suffix o ".a" then Kind_static
              else if Filename.check_suffix o ".o" then Kind_obj
              else if Filename.check_suffix o ".s" then Kind_asm
              else if Filename.check_suffix o ".xcframework" then
                Kind_xcframework
              else Kind_exe
          | None -> Kind_exe))

let resolve_toolchain cfg =
  Target.toolchain ?cc_path:cfg.cc_path ?ar_path:cfg.ar_path ?sysroot:cfg.sysroot

let is_host_default_toolchain cfg target =
  cfg.cc_path = None && cfg.sysroot = None && Target.is_host target

let input_groups inputs =
  let classify (ocaml, c, native) path =
    if Filename.check_suffix path ".c" then (ocaml, path :: c, native)
    else if Filename.check_suffix path ".o" || Filename.check_suffix path ".a" then
      (ocaml, c, path :: native)
    else (path :: ocaml, c, native)
  in
  let ocaml, c, native = List.fold_left classify ([], [], []) inputs in
  (List.rev ocaml, List.rev c, List.rev native)

let default_output (target : target_spec) = function
  | Kind_exe -> "a.out"
  | Kind_shared -> if target.os = Darwin then "libout.dylib" else "libout.so"
  | Kind_static -> "libout.a"
  | Kind_obj -> "out.o"
  | Kind_asm -> "out.s"
  | Kind_xcframework -> "Out.xcframework"

let headers cfg ~include_dirs ~nostdlib ~work_dir steps =
  match cfg.emit_header with
  | None -> Ok { C_bindgen.shim_files = []; symbols = [] }
  | Some output ->
      let interfaces =
        List.filter_map (fun (step : build_step) ->
          match step.kind with `Mli -> Some (step.modname, step.path) | `Ml -> None)
          steps
      in
      C_bindgen.generate_headers ~include_dirs ~nopervasives:cfg.nopervasives
        ~nostdlib ~work_dir ~output interfaces

let compiler_binary () =
  let exe = Sys.executable_name in
  if Filename.is_implicit exe then Option.value (find_in_path exe) ~default:exe
  else exe

let matching_files directory extensions =
  if not (Sys.file_exists directory && Sys.is_directory directory) then []
  else
    Sys.readdir directory |> Array.to_list
    |> List.filter (fun name -> List.exists (Filename.check_suffix name) extensions)
    |> List.sort String.compare |> List.map (Filename.concat directory)

let os_label = function
  | Darwin -> "darwin"
  | Linux -> "linux"
  | Ios -> "ios"
  | Ios_sim -> "ios-sim"
  | Android -> "android"
  | Windows -> "windows"

let compute_toolchain_key ~compiler ~qbe ~(target : Target.t) ~mode ~debug_info
    ~single_thread ~nostdlib ~nopervasives ~stdlib =
  let stdlib_files =
    match Stdlib_build.interface_dir stdlib with
    | Some dir -> matching_files dir [".cmi"; ".a.opt"; ".exports"]
    | None -> []
  in
  let* digests = Build_cache.fingerprints (compiler :: qbe :: stdlib_files) in
  let fields =
    [ "schema", "1";
      "target", target.name;
      "qbe-target", target.qbe_target;
      "os", os_label target.os;
      "arch", target.arch;
      "mode", Build_mode.to_string mode;
      "debug-info", string_of_bool debug_info;
      "rc", string_of_bool single_thread;
      "nostdlib", string_of_bool nostdlib;
      "nopervasives", string_of_bool nopervasives ]
    @ digests
  in
  Ok (Sha256.to_hex (Build_cache.key fields))

let parse_make_deps raw =
  let normalized = String.concat "" (String.split_on_char '\\' raw) in
  let body =
    match String.index_opt normalized ':' with
    | Some idx -> String.sub normalized (idx + 1) (String.length normalized - idx - 1)
    | None -> normalized
  in
  String.split_on_char ' ' body
  |> List.concat_map (String.split_on_char '\n')
  |> List.concat_map (String.split_on_char '\r')
  |> List.concat_map (String.split_on_char '\t')
  |> List.filter (fun tok -> tok <> "")

let compile_asm_list ~cache_dir ~verbose toolchain flags ~work_dir inputs =
  match cache_dir with
  | None -> Linker.compile_many ~verbose ~work_dir toolchain flags inputs
  | Some cache ->
      let store = Filename.concat cache "occ-obj" in
      let base_fields =
        [ "schema", "1"; "kind", "asm"; "cc", toolchain.Target.Toolchain.cc_prog ]
        @ List.map (fun f -> "cc-base", f) toolchain.cc_base_args
        @ List.map (fun f -> "flag", f) flags
      in
      let rec go acc = function
        | [] -> Ok (List.rev acc)
        | src :: rest ->
            let* digest = Sha256.file src in
            let key = Build_cache.key (("asm", Sha256.to_hex digest) :: base_fields) in
            let* entry =
              Build_cache.ensure ~store ~key (fun dir ->
                Linker.compile_source ~verbose toolchain flags src
                  (Filename.concat dir "unit.o"))
            in
            go (Filename.concat entry.directory "unit.o" :: acc) rest
      in
      go [] inputs

let compile_c_list ~cache_dir ~verbose toolchain flags ~work_dir inputs =
  match cache_dir with
  | None -> Linker.compile_many ~verbose ~work_dir toolchain flags inputs
  | Some cache ->
      let store = Filename.concat cache "occ-c" in
      let base_fields =
        [ "schema", "1"; "kind", "c"; "cc", toolchain.Target.Toolchain.cc_prog ]
        @ List.map (fun f -> "cc-base", f) toolchain.cc_base_args
        @ List.map (fun f -> "flag", f) flags
      in
      let rec go acc index = function
        | [] -> Ok (List.rev acc)
        | src :: rest ->
            let deps_opt =
              match capture_cmd toolchain.cc_prog
                      (toolchain.cc_base_args @ flags @ ["-MM"; src]) with
              | Ok raw ->
                  let deps = parse_make_deps raw |> List.sort_uniq String.compare in
                  if deps <> [] && List.for_all Sys.file_exists deps then Some deps
                  else None
              | Error _ -> None
            in
            match deps_opt with
            | Some deps ->
                let* digests = Build_cache.fingerprints deps in
                let key = Build_cache.key (base_fields @ digests) in
                let* entry =
                  Build_cache.ensure ~store ~key (fun dir ->
                    Linker.compile_source ~verbose toolchain flags src
                      (Filename.concat dir "unit.o"))
                in
                go (Filename.concat entry.directory "unit.o" :: acc) (index + 1) rest
            | None ->
                let base = Filename.chop_extension (Filename.basename src) in
                let obj = Filename.concat work_dir (Printf.sprintf "u_c%d_%s.o" index base) in
                let* () = Linker.compile_source ~verbose toolchain flags src obj in
                go (obj :: acc) (index + 1) rest
      in
      go [] 0 inputs

let compile_object cfg ~target ~output (units : Build_units.compiled) =
  let* toolchain = resolve_toolchain cfg target in
  let flags = Build_mode.cflags ~debug_info:cfg.debug_info cfg.mode @ cfg.extra_cflags in
  match units.assemblies with
  | [asm] ->
      let* () = Linker.compile_source ~verbose:cfg.verbose toolchain flags asm output in
      (try
         Option.iter (fun (unit_name, cmi, exports) ->
           Export_summary.publish_object ~unit_name ~cmi ~obj:output exports)
           units.object_interface;
         Ok output
       with Sys_error msg -> Error msg)
  | _ -> Error "-c requires a single .ml compilation unit"

let build_single cfg ~(target : target_spec) ~kind ~work_dir =
  let verbose = cfg.verbose in
  let* qbe = Target.qbe cfg.qbe_path in
  mkdir_p work_dir;
  let ocaml_inputs, c_inputs, obj_inputs = input_groups cfg.inputs in
  let* steps = plan_build_order ocaml_inputs in
  let prefer_prebuilt = is_host_default_toolchain cfg target in
  let prefer_archive = match kind with Kind_exe | Kind_obj | Kind_asm -> true | _ -> false in
  let cache_dir =
    if cfg.no_cache then None
    else Result.to_option (Target.cache_dir ?override:cfg.cache_dir ())
  in
  let compiler = compiler_binary () in
  let* toolchain_opt =
    match kind with
    | Kind_asm -> Ok None
    | Kind_obj | Kind_exe | Kind_shared | Kind_static ->
        let+ tc = resolve_toolchain cfg target in
        Some tc
    | Kind_xcframework -> assert false
  in
  let mode_cflags = Build_mode.cflags ~debug_info:cfg.debug_info cfg.mode in
  let* stdlib =
    Stdlib_build.prepare_cached
      ~mode:cfg.mode ~debug_info:cfg.debug_info ~cflags:cfg.extra_cflags
      ?cache_dir ~compiler ~qbe ~target ?toolchain:toolchain_opt ~verbose
      ~disabled:cfg.nostdlib ~prefer_prebuilt ~prefer_archive
      ~sources:cfg.stdlib_src_dir ~prebuilt:cfg.prebuilt_stdlib_dir ~work_dir ()
  in
  let stdlib_dir = Stdlib_build.interface_dir stdlib in
  let include_dirs =
    Filename.concat work_dir "cmi" :: (Option.to_list stdlib_dir @ cfg.include_dirs)
  in
  let nostdlib = cfg.nostdlib || Option.is_some stdlib_dir in
  let single_thread = cfg.inline_single_thread_rc in
  let include_main = kind = Kind_exe && not cfg.no_main in
  let* toolchain_key =
    match cache_dir with
    | None -> Ok ""
    | Some _ ->
        compute_toolchain_key ~compiler ~qbe ~target ~mode:cfg.mode
          ~debug_info:cfg.debug_info ~single_thread ~nostdlib
          ~nopervasives:cfg.nopervasives ~stdlib
  in
  let* units =
    Build_units.compile
      { steps; work_dir; include_dirs; stdlib; nostdlib; nopervasives = cfg.nopervasives;
        single_thread; include_main; publish_object = (kind = Kind_obj);
        mode = cfg.mode; debug_info = cfg.debug_info; cache_dir; toolchain_key;
        qbe; target; verbose }
  in
  if verbose then
    Printf.eprintf "occ: %d compiled, %d cached\n%!" units.compiled units.hits;
  let* headers = headers cfg ~include_dirs ~nostdlib ~work_dir steps in
  let output = Option.value ~default:(default_output target kind) cfg.output in
  mkdir_p (Filename.dirname output);
  match kind with
  | Kind_asm ->
      write_file output (String.concat "\n" (List.map read_file units.assemblies));
      Ok output
  | Kind_obj -> compile_object cfg ~target ~output units
  | Kind_exe | Kind_shared | Kind_static ->
      let toolchain = Option.get toolchain_opt in
      let pic = if target.os = Windows then [] else ["-fPIC"] in
      let header_flags =
        Option.to_list (Option.map (fun path -> "-I" ^ Filename.dirname path) cfg.emit_header)
      in
      let* unit_objs =
        compile_asm_list ~cache_dir ~verbose toolchain
          (pic @ mode_cflags @ cfg.extra_cflags) ~work_dir units.assemblies
      in
      let* shim_objs =
        compile_c_list ~cache_dir ~verbose toolchain
          (["-std=c99"] @ mode_cflags @ pic @ header_flags @ cfg.extra_cflags)
          ~work_dir headers.shim_files
      in
      let* c_objs =
        compile_c_list ~cache_dir ~verbose toolchain
          (pic @ mode_cflags @ header_flags @ cfg.extra_cflags)
          ~work_dir c_inputs
      in
      let user_objects = unit_objs @ shim_objs @ c_objs @ obj_inputs in
      let* runtime =
        Runtime_build.link_inputs
          ~mode:cfg.mode ~debug_info:cfg.debug_info ~extra_cflags:cfg.extra_cflags
          ?cache_dir
          { single_thread; prefer_prebuilt; include_main;
            prebuilt_dir = cfg.prebuilt_rt_dir; source_dir = cfg.runtime_dir;
            work_dir = Filename.concat work_dir "rt"; toolchain; verbose }
      in
      let* stdlib_objects =
        Stdlib_build.link_inputs ~mode:cfg.mode ~debug_info:cfg.debug_info
          ~cflags:cfg.extra_cflags ~verbose ~qbe ~target ~toolchain stdlib
      in
      let mode = match kind with
        | Kind_exe -> Linker.Executable
        | Kind_static -> Linker.Static
        | Kind_shared ->
            let exports =
              if cfg.emit_header <> None && c_inputs = [] && obj_inputs = []
                 && headers.symbols <> []
              then Some headers.symbols else None
            in
            Linker.Shared exports
        | _ -> assert false
      in
      Linker.link
        { mode; target; toolchain; work_dir; output; user_objects;
          internal_objects = stdlib_objects @ runtime;
          extra_ldflags = cfg.extra_ldflags; verbose }
  | Kind_xcframework -> assert false

let build_xcframework cfg ~work_dir =
  let output = Option.value ~default:"Out.xcframework" cfg.output in
  let header =
    match cfg.emit_header with
    | Some _ as header -> header
    | None when List.exists (fun path -> Filename.check_suffix path ".mli") cfg.inputs ->
        Some (Filename.concat work_dir "headers/ocamlcc_ffi.h")
    | None -> None
  in
  let slice ~target_name ~directory ~archive =
    let archive = Filename.concat work_dir archive in
    let* target = Target.resolve target_name in
    let cfg = { cfg with output = Some archive; emit_header = header; kind = Some Kind_static } in
    build_single cfg ~target ~kind:Kind_static ~work_dir:(Filename.concat work_dir directory)
  in
  let* device = slice ~target_name:"ios-arm64" ~directory:"dev" ~archive:"ios_arm64.a" in
  let* simulator = slice ~target_name:"ios-sim-arm64" ~directory:"sim" ~archive:"ios_sim_arm64.a" in
  let headers = Option.map (fun source ->
    let directory = Filename.concat work_dir "xcf_headers" in
    mkdir_p directory;
    write_file (Filename.concat directory (Filename.basename source)) (read_file source);
    directory) header in
  let slices = List.map (fun library -> { Linker.Xcframework_slice.library; headers }) [device; simulator] in
  Linker.xcframework ~verbose:cfg.verbose ~output slices

let build cfg =
  let target_name = Option.value ~default:"host" cfg.target in
  let kind = infer_kind cfg in
  let run work_dir =
    if kind = Kind_xcframework || String.lowercase_ascii target_name = "ios-xcframework"
    then build_xcframework cfg ~work_dir
    else
      let* target = resolve_target target_name in
      build_single cfg ~target ~kind ~work_dir
  in
  match cfg.work_dir with
  | Some work_dir -> run work_dir
  | None ->
      let work_dir = Filename.temp_dir "ocamlcc_build_" "" in
      Fun.protect ~finally:(fun () -> rm_rf work_dir) (fun () -> run work_dir)
