open Sys_util

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

let rec build_single cfg ~(target : target_spec) ~(kind : output_kind)
    ~work_dir : (string, string) result =
  let verbose = cfg.verbose in
  match Target.qbe cfg.qbe_path with
  | Error _ as e -> e
  | Ok qbe -> (
      mkdir_p work_dir;
          let ocaml_inputs, c_inputs, obj_inputs =
            List.fold_left
              (fun (oc, cc, ob) f ->
                if
                  Filename.check_suffix f ".ml"
                  || Filename.check_suffix f ".mli"
                then (f :: oc, cc, ob)
                else if Filename.check_suffix f ".c" then (oc, f :: cc, ob)
                else if
                  Filename.check_suffix f ".o"
                  || Filename.check_suffix f ".a"
                then (oc, cc, f :: ob)
                else (f :: oc, cc, ob))
              ([], [], []) cfg.inputs
          in
          let ocaml_inputs = List.rev ocaml_inputs in
          let c_inputs = List.rev c_inputs in
          let obj_inputs = List.rev obj_inputs in
          match plan_build_order ocaml_inputs with
          | Error _ as e -> e
          | Ok steps ->
              let ml_steps =
                List.filter (fun (s : build_step) -> s.kind = `Ml) steps
              in
              let mli_steps =
                List.filter (fun (s : build_step) -> s.kind = `Mli) steps
              in
              let cmi_dir = Filename.concat work_dir "cmi" in
              mkdir_p cmi_dir;
              let stdlib_prep_res =
                Stdlib_build.prepare ~disabled:cfg.nostdlib
                  ~prefer_prebuilt:(is_host_default_toolchain cfg target)
                  ~prefer_archive:(match kind with Kind_exe | Kind_obj | Kind_asm -> true | _ -> false)
                  ~sources:cfg.stdlib_src_dir ~prebuilt:cfg.prebuilt_stdlib_dir ~work_dir
              in
              match stdlib_prep_res with
              | Error _ as e -> e
              | Ok stdlib_plan ->
              let stdlib_dir = Stdlib_build.interface_dir stdlib_plan in
              let inc_dirs = cmi_dir :: (Option.to_list stdlib_dir @ cfg.include_dirs) in
              let eff_nostdlib = cfg.nostdlib || Option.is_some stdlib_dir in
              let is_lib_kind =
                match kind with
                | Kind_shared | Kind_static | Kind_obj | Kind_asm
                | Kind_xcframework ->
                    true
                | Kind_exe -> false
              in
              let include_main = (not is_lib_kind) && not cfg.no_main in
              let last_ml_path =
                match List.rev ml_steps with
                | s :: _ -> Some s.path
                | [] -> None
              in
              let archive = Stdlib_build.archive stdlib_plan in
              let local_units =
                List.map (fun (step : build_step) -> step.modname) ml_steps in
              let summaries =
                Some (Export_summary.Loader.create ?archive ~exclude_units:local_units ())
              in
              let shim_c_files = ref [] in
              let shim_exported_syms = ref [] in
              let has_mli modname =
                List.exists (fun (s : build_step) -> s.modname = modname) mli_steps
              in
              let rec compile_steps ~imports ~assemblies ~object_interface = function
                | [] -> Ok (List.rev assemblies, object_interface)
                | (step : build_step) :: rest ->
                    let open Result_syntax in
                    let lower = String.uncapitalize_ascii step.modname in
                    let prefix = Filename.concat cmi_dir lower in
                    let request =
                      { (Pipeline.Request.create ~filename:step.path ~modname:step.modname) with
                        include_dirs = inc_dirs; output_prefix = Some prefix;
                        nopervasives = cfg.nopervasives; nostdlib = eff_nostdlib }
                    in
                    match step.kind with
                    | `Mli ->
                        let* _ = Pipeline.compile_interface_file request in
                        Gc.full_major ();
                        compile_steps ~imports ~assemblies ~object_interface rest
                    | `Ml ->
                        let request =
                          { request with stdlib_dir; summaries; imports;
                            emit_cmi = not (has_mli step.modname); emit_entry = false;
                            export_policy = (if kind = Kind_obj then Seal else Collect);
                            inline_single_thread_rc = cfg.inline_single_thread_rc }
                        in
                        let* output = Pipeline.compile_file request in
                        let ssa = Filename.concat work_dir (lower ^ ".ssa") in
                        let asm = Filename.concat work_dir (lower ^ ".s") in
                        let startup =
                          if include_main && last_ml_path = Some step.path then
                            Qbe_il.to_string { funcs = [Codegen.entry_point local_units]; datas = [] }
                          else ""
                        in
                        write_file ssa (output.ssa ^ startup);
                        let* () =
                          run_cmd ~verbose ~stdout_file:asm qbe
                            [ "-t"; target.qbe_target; ssa ]
                        in
                        let object_interface =
                          match kind, output.interface with
                          | Kind_obj, Some cmi -> Some (step.modname, cmi, output.exports)
                          | _ -> object_interface
                        in
                        Gc.full_major ();
                        compile_steps ~imports:((step.modname, output.exports) :: imports)
                          ~assemblies:(asm :: assemblies) ~object_interface rest
              in
              match compile_steps ~imports:(Stdlib_build.imports stdlib_plan) ~assemblies:[] ~object_interface:None steps with
              | Error _ as e -> e
              | Ok (asm_files, object_interface) -> (
                  (* Optional .mli -> .h + _shim.c generation *)
                  let bindgen_res =
                    match cfg.emit_header with
                    | None -> Ok ()
                    | Some hdr_path -> (
                        match mli_steps with
                        | [] ->
                            Error
                              "--emit-header requires at least one .mli input"
                        | _ ->
                            let hdr_dir = Filename.dirname hdr_path in
                            mkdir_p hdr_dir;
                            let multi = List.length mli_steps > 1 in
                            let hdr_base = Filename.basename hdr_path in
                            let hdr_stem = Filename.remove_extension hdr_base in
                            let hdr_ext =
                              let e = Filename.extension hdr_base in
                              if e = "" then ".h" else e
                            in
                            let sub_headers = ref [] in
                            let res =
                              List.fold_left
                                (fun acc (s : build_step) ->
                                  match acc with
                                  | Error _ as e -> e
                                  | Ok () -> (
                                      let out_h =
                                        if multi then
                                          let name =
                                            Printf.sprintf "%s_%s%s" hdr_stem
                                              (String.uncapitalize_ascii
                                                 s.modname)
                                              hdr_ext
                                          in
                                          sub_headers := name :: !sub_headers;
                                          Filename.concat hdr_dir name
                                        else hdr_path
                                      in
                                      let out_c =
                                        Filename.concat work_dir
                                          (String.uncapitalize_ascii s.modname
                                         ^ "_shim.c")
                                      in
                                      match
                                        C_bindgen.generate_file
                                          ~include_dirs:inc_dirs
                                          ~nopervasives:cfg.nopervasives
                                          ~nostdlib:eff_nostdlib
                                          ~header_include:
                                            (Filename.basename out_h)
                                          ~filename:s.path ~modname:s.modname ()
                                      with
                                      | Error msg -> Error msg
                                      | Ok { header; shim_c; exported_symbols } ->
                                          write_file out_h header;
                                          write_file out_c shim_c;
                                          shim_c_files := out_c :: !shim_c_files;
                                          shim_exported_syms :=
                                            List.rev_append exported_symbols
                                              !shim_exported_syms;
                                          Ok ()))
                                (Ok ()) mli_steps
                            in
                            (match res with
                            | Ok () when multi ->
                                let sanitize_guard s =
                                  String.map
                                    (fun c ->
                                      if
                                        (c >= 'A' && c <= 'Z')
                                        || (c >= '0' && c <= '9')
                                      then c
                                      else if c >= 'a' && c <= 'z' then
                                        Char.uppercase_ascii c
                                      else '_')
                                    s
                                in
                                let guard =
                                  "OCAMLCC_UMBRELLA_"
                                  ^ sanitize_guard hdr_base
                                in
                                let includes =
                                  List.rev !sub_headers
                                  |> List.map (Printf.sprintf "#include \"%s\"")
                                  |> String.concat "\n"
                                in
                                let umbrella =
                                  Printf.sprintf
                                    "#ifndef %s\n#define %s\n\n%s\n\n#endif /* %s */\n"
                                    guard guard includes guard
                                in
                                write_file hdr_path umbrella
                            | _ -> ());
                            res)
                  in
                  match bindgen_res with
                  | Error _ as e -> e
                  | Ok () -> (
                      let shim_c_files = List.rev !shim_c_files in
                      let shim_exported_syms = List.rev !shim_exported_syms in
                      let out_path =
                        match cfg.output with
                        | Some o -> o
                        | None -> (
                            match kind with
                            | Kind_exe -> "a.out"
                            | Kind_shared ->
                                if target.os = Darwin then "libout.dylib"
                                else "libout.so"
                            | Kind_static -> "libout.a"
                            | Kind_obj -> "out.o"
                            | Kind_asm -> "out.s"
                            | Kind_xcframework -> "Out.xcframework")
                      in
                      mkdir_p (Filename.dirname out_path);
                      match kind with
                      | Kind_asm ->
                          let combined =
                            String.concat "\n" (List.map read_file asm_files)
                          in
                          write_file out_path combined;
                          Ok out_path
                      | Kind_obj -> (
                          match resolve_toolchain cfg target with
                          | Error _ as e -> e
                          | Ok tc -> (
                              match asm_files with
                              | [ asm ] -> (
                                  match
                                    Linker.compile_source ~verbose tc cfg.extra_cflags
                                      asm out_path
                                  with
                                  | Error _ as e -> e
                                  | Ok () ->
                                      (try
                                         Option.iter (fun (unit_name, cmi, exports) ->
                                           Export_summary.publish_object ~unit_name ~cmi ~obj:out_path exports)
                                           object_interface;
                                         Ok out_path
                                       with Sys_error msg -> Error msg))
                              | _ ->
                                  Error
                                    "-c requires a single .ml compilation unit"))
                      | Kind_exe | Kind_shared | Kind_static -> (
                          match resolve_toolchain cfg target with
                          | Error _ as e -> e
                          | Ok tc -> (
                          let compile_many srcs flags =
                            let rec go acc idx = function
                              | [] -> Ok (List.rev acc)
                              | s :: rest -> (
                                  let obj =
                                    Filename.concat work_dir
                                      (Printf.sprintf "u_%d_%s.o" idx
                                         (Filename.chop_extension
                                            (Filename.basename s)))
                                  in
                                  match Linker.compile_source ~verbose tc flags s obj with
                                  | Error _ as e -> e
                                  | Ok () -> go (obj :: acc) (idx + 1) rest)
                            in
                            go [] 0 srcs
                          in
                          let pic_flags =
                            if target.os = Windows then [] else [ "-fPIC" ]
                          in
                          let hdr_inc_flags =
                            match cfg.emit_header with
                            | Some h -> [ "-I" ^ Filename.dirname h ]
                            | None -> []
                          in
                          match
                            compile_many asm_files (pic_flags @ cfg.extra_cflags)
                          with
                          | Error _ as e -> e
                          | Ok unit_objs -> (
                              match
                                compile_many shim_c_files
                                  ([ "-std=c99"; "-O2" ] @ pic_flags
                                 @ hdr_inc_flags @ cfg.extra_cflags)
                              with
                              | Error _ as e -> e
                              | Ok shim_objs -> (
                                  match
                                    compile_many c_inputs
                                      (pic_flags @ hdr_inc_flags
                                     @ cfg.extra_cflags)
                                  with
                                  | Error _ as e -> e
                                  | Ok c_objs -> (
                                      let user_objs =
                                        unit_objs @ shim_objs @ c_objs @ obj_inputs
                                      in
                                      let rt_objs_res =
                                        let single_thread = cfg.inline_single_thread_rc in
                                        let prefer_prebuilt = is_host_default_toolchain cfg target in
                                        Runtime_build.link_inputs
                                          { single_thread; prefer_prebuilt; include_main;
                                            prebuilt_dir = cfg.prebuilt_rt_dir;
                                            source_dir = cfg.runtime_dir;
                                            work_dir = Filename.concat work_dir "rt";
                                            toolchain = tc; verbose }
                                      in
                                      match rt_objs_res with
                                      | Error _ as e -> e
                                      | Ok rt_objs -> (
                                          let stdlib_objs_res =
                                            Stdlib_build.link_inputs ~verbose ~qbe
                                              ~target ~toolchain:tc stdlib_plan
                                          in
                                          match stdlib_objs_res with
                                          | Error _ as e -> e
                                          | Ok stdlib_objs -> (
                                              let mode =
                                                match kind with
                                                | Kind_static -> Linker.Static
                                                | Kind_exe -> Linker.Executable
                                                | Kind_shared ->
                                                    let exports =
                                                      if cfg.emit_header <> None && c_inputs = []
                                                         && obj_inputs = [] && shim_exported_syms <> []
                                                      then Some shim_exported_syms else None
                                                    in
                                                    Linker.Shared exports
                                                | Kind_obj | Kind_asm | Kind_xcframework -> assert false
                                              in
                                              Linker.link
                                                { mode; target; toolchain = tc; work_dir;
                                                  output = out_path; user_objects = user_objs;
                                                  internal_objects = stdlib_objs @ rt_objs;
                                                  extra_ldflags = cfg.extra_ldflags; verbose })))))))
                      | Kind_xcframework -> assert false)))

and build (cfg : config) : (string, string) result =
  let tname = Option.value ~default:"host" cfg.target in
  let kind = infer_kind cfg in
  let work_dir, cleanup =
    match cfg.work_dir with
    | Some d -> (d, false)
    | None ->
        let tmp = Filename.temp_dir "ocamlcc_build_" "" in
        (tmp, true)
  in
  Fun.protect
    ~finally:(fun () -> if cleanup then rm_rf work_dir)
    (fun () ->
      if kind = Kind_xcframework || String.lowercase_ascii tname = "ios-xcframework"
      then
        let out_xcf =
          Option.value ~default:"Out.xcframework" cfg.output
        in
        let has_mli_input =
          List.exists (fun f -> Filename.check_suffix f ".mli") cfg.inputs
        in
        let eff_emit_header =
          match cfg.emit_header with
          | Some _ as h -> h
          | None ->
              if has_mli_input then begin
                let hdr_dir = Filename.concat work_dir "headers" in
                mkdir_p hdr_dir;
                Some (Filename.concat hdr_dir "ocamlcc_ffi.h")
              end
              else None
        in
        let dev_a = Filename.concat work_dir "ios_arm64.a" in
        let sim_a = Filename.concat work_dir "ios_sim_arm64.a" in
        let dev_t =
          { name = "ios-arm64";
            qbe_target = "arm64_apple";
            os = Ios;
            arch = "arm64" }
        in
        let sim_t =
          { name = "ios-sim-arm64";
            qbe_target = "arm64_apple";
            os = Ios_sim;
            arch = "arm64" }
        in
        let cfg_dev =
          { cfg with
            output = Some dev_a;
            emit_header = eff_emit_header;
            kind = Some Kind_static }
        in
        let cfg_sim =
          { cfg with
            output = Some sim_a;
            emit_header = eff_emit_header;
            kind = Some Kind_static }
        in
        match
          build_single cfg_dev ~target:dev_t ~kind:Kind_static
            ~work_dir:(Filename.concat work_dir "dev")
        with
        | Error _ as e -> e
        | Ok _ -> (
            match
              build_single cfg_sim ~target:sim_t ~kind:Kind_static
                ~work_dir:(Filename.concat work_dir "sim")
            with
            | Error _ as e -> e
            | Ok _ ->
                Linker.xcframework ~verbose:cfg.verbose ~work_dir ~output:out_xcf
                  ~header:eff_emit_header [dev_a; sim_a])
      else
        match resolve_target tname with
        | Error _ as e -> e
        | Ok target -> build_single cfg ~target ~kind ~work_dir)
