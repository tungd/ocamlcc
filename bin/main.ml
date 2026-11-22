(* occ CLI.

   Subcommands:
     occ build [flags] <files...> -o <out>             full driver build
     occ compile [flags] <file.ml> [-o <out.ssa>]      emit QBE IL
     occ compile-mli [flags] <file.mli> [-o <out.cmi>] emit .cmi
     occ bindgen [flags] <file.mli> [-o <out.h>] [--shim <out.c>]  emit C header + shim
     occ dump-lambda [flags] <file.ml>                 print the Lambda IR *)

let usage =
  "usage: occ build [--target t] [--shared|--static|--exe|-c|-S] \
   [--emit-header h] [-I dir] [--nostdlib] [--nopervasives] [--no-main] \
   [--qbe path] [--cc path] [--sysroot path] [--single-thread-rc] \
   [-v] <files...> -o <out>\n\
   \       occ compile [-I dir] [--nostdlib] [--nopervasives] [--emit-cmi] \
   [--cmi-prefix p] [--mod] [--emit-opt] [--stdlib-dir dir] [--inline-single-thread-rc] <file.ml> [-o <out.ssa>]\n\
   \       occ compile-mli [-I dir] [--nostdlib] [--nopervasives] \
   <file.mli> [-o <out.cmi>]\n\
   \       occ bindgen [-I dir] [--nostdlib] [--nopervasives] \
   [--shim <out.c>] <file.mli> [-o <out.h>]\n\
   \       occ archive-opt <archive.a> <unit.opt>...\n\
   \       occ object-opt <unit.opt>\n\
   \       occ dump-lambda [-I dir] [--nostdlib] [--nopervasives] <file.ml>"

type cli_opts = {
  include_dirs : string list;
  open_modules : string list;
  nostdlib : bool;
  nopervasives : bool;
  no_alias_deps : bool;
  nolabels : bool;
  emit_cmi : bool;
  emit_opt : bool;
  cmi_prefix : string option;
  is_mod : bool;
  shim_out : string option;
  out : string option;
  inputs : string list;
  target : string option;
  kind : Driver.output_kind option;
  no_main : bool;
  emit_header : string option;
  qbe_path : string option;
  cc_path : string option;
  ar_path : string option;
  sysroot : string option;
  runtime_dir : string option;
  runtime_objects_dir : string option;
  inline_single_thread_rc : bool;
  stdlib_dir : string option;
  work_dir : string option;
  extra_cflags : string list;
  extra_ldflags : string list;
  verbose : bool;
}

let default_opts =
  { include_dirs = [];
    open_modules = [];
    nostdlib = false;
    nopervasives = false;
    no_alias_deps = false;
    nolabels = false;
    emit_cmi = false;
    emit_opt = false;
    cmi_prefix = None;
    is_mod = false;
    shim_out = None;
    out = None;
    inputs = [];
    target = None;
    kind = None;
    no_main = false;
    emit_header = None;
    qbe_path = None;
    cc_path = None;
    ar_path = None;
    sysroot = None;
    runtime_dir = None;
    runtime_objects_dir = None;
    inline_single_thread_rc = false;
    stdlib_dir = None;
    work_dir = None;
    extra_cflags = [];
    extra_ldflags = [];
    verbose = false }

let parse_opts args =
  let rec go opts = function
    | [] ->
        Ok
          { opts with
            include_dirs = List.rev opts.include_dirs;
            open_modules = List.rev opts.open_modules;
            inputs = List.rev opts.inputs;
            extra_cflags = List.rev opts.extra_cflags;
            extra_ldflags = List.rev opts.extra_ldflags }
    | "-I" :: dir :: rest ->
        go { opts with include_dirs = dir :: opts.include_dirs } rest
    | ("-open" | "--open") :: m :: rest ->
        go { opts with open_modules = m :: opts.open_modules } rest
    | "--nostdlib" :: rest -> go { opts with nostdlib = true } rest
    | "--nopervasives" :: rest -> go { opts with nopervasives = true } rest
    | "--no-alias-deps" :: rest -> go { opts with no_alias_deps = true } rest
    | "--nolabels" :: rest -> go { opts with nolabels = true } rest
    | "--emit-opt" :: rest -> go { opts with emit_opt = true } rest
    | "--emit-cmi" :: rest -> go { opts with emit_cmi = true } rest
    | "--cmi-prefix" :: p :: rest ->
        go { opts with cmi_prefix = Some p; emit_cmi = true } rest
    | "--mod" :: rest -> go { opts with is_mod = true } rest
    | "--shim" :: path :: rest -> go { opts with shim_out = Some path } rest
    | "--target" :: t :: rest -> go { opts with target = Some t } rest
    | "--shared" :: rest ->
        go { opts with kind = Some Driver.Kind_shared } rest
    | "--static" :: rest ->
        go { opts with kind = Some Driver.Kind_static } rest
    | "--exe" :: rest -> go { opts with kind = Some Driver.Kind_exe } rest
    | "-c" :: rest -> go { opts with kind = Some Driver.Kind_obj } rest
    | ("-S" | "--emit-asm") :: rest ->
        go { opts with kind = Some Driver.Kind_asm } rest
    | "--no-main" :: rest -> go { opts with no_main = true } rest
    | "--emit-header" :: p :: rest ->
        go { opts with emit_header = Some p } rest
    | "--qbe" :: p :: rest -> go { opts with qbe_path = Some p } rest
    | "--cc" :: p :: rest -> go { opts with cc_path = Some p } rest
    | "--ar" :: p :: rest -> go { opts with ar_path = Some p } rest
    | "--sysroot" :: p :: rest -> go { opts with sysroot = Some p } rest
    | "--runtime-dir" :: p :: rest ->
        go { opts with runtime_dir = Some p } rest
    | ("--single-thread-rc" | "--inline-single-thread-rc") :: rest ->
        go { opts with inline_single_thread_rc = true } rest
    | "--runtime-objects-dir" :: p :: rest ->
        go { opts with runtime_objects_dir = Some p } rest
    | "--stdlib-dir" :: p :: rest ->
        go { opts with stdlib_dir = Some p } rest
    | "--work-dir" :: p :: rest -> go { opts with work_dir = Some p } rest
    | "--cflags" :: f :: rest ->
        go { opts with extra_cflags = f :: opts.extra_cflags } rest
    | "--ldflags" :: f :: rest ->
        go { opts with extra_ldflags = f :: opts.extra_ldflags } rest
    | ("-v" | "--verbose") :: rest -> go { opts with verbose = true } rest
    | "-o" :: path :: rest -> go { opts with out = Some path } rest
    | arg :: _ when String.length arg > 0 && arg.[0] = '-' ->
        Error (Printf.sprintf "unknown flag: %s" arg)
    | file :: rest -> go { opts with inputs = file :: opts.inputs } rest
  in
  go default_opts args

let write_out out ssa =
  match out with
  | Some path -> Sys_util.write_file path ssa
  | None -> print_string ssa

let single_input opts =
  match opts.inputs with
  | [ f ] -> Some f
  | _ -> None

let compile opts =
  match single_input opts with
  | None ->
      prerr_endline usage;
      2
  | Some file -> (
      let output_prefix =
        match opts.cmi_prefix with
        | Some _ as p -> p
        | None when opts.emit_cmi -> Some (Filename.remove_extension file)
        | None -> None
      in
      let modname =
        match output_prefix with
        | Some p -> Pipeline.module_name_of_file (p ^ ".ml")
        | None -> Pipeline.module_name_of_file file
      in
      let include_dirs =
        match opts.stdlib_dir with
        | Some dir when not (List.mem dir opts.include_dirs) -> opts.include_dirs @ [dir]
        | _ -> opts.include_dirs
      in
      let archive = Option.bind opts.stdlib_dir Export_summary.find_archive in
      let summaries =
        if opts.emit_opt && Option.is_none opts.stdlib_dir then None
        else Some (Export_summary.Loader.create ?archive ()) in
      let request =
        { (Pipeline.Request.create ~filename:file ~modname) with
          include_dirs; output_prefix; stdlib_dir = opts.stdlib_dir; summaries;
          export_policy = (if opts.emit_opt then Seal else Omit);
          emit_cmi = opts.emit_cmi; nopervasives = opts.nopervasives;
          nostdlib = opts.nostdlib; no_alias_deps = opts.no_alias_deps;
          nolabels = opts.nolabels; open_modules = opts.open_modules;
          inline_single_thread_rc = opts.inline_single_thread_rc;
          emit_entry = not opts.is_mod }
      in
      match Pipeline.compile_file request with
      | Ok { ssa; exports; _ } ->
          (try
             if opts.emit_opt then begin
               let prefix = Option.value ~default:(Filename.remove_extension file) output_prefix in
               Export_summary.write_unit ~prefix exports
             end;
             write_out opts.out ssa;
             0
           with Sys_error msg ->
             prerr_endline ("occ: error: " ^ msg);
             2)
      | Error msg ->
          prerr_endline ("occ: error: " ^ msg);
          2)

let archive_opt opts =
  match opts.inputs with
  | archive :: (_ :: _ as units) ->
      (try Export_summary.write_archive ~archive ~units; 0
       with Sys_error msg ->
         prerr_endline ("occ: error: " ^ msg);
         2)
  | _ -> prerr_endline usage; 2

let object_opt opts =
  match opts.inputs with
  | [unit] when Filename.check_suffix unit ".opt" ->
      (try Export_summary.write_unit_object unit; 0
       with Sys_error msg ->
         prerr_endline ("occ: error: " ^ msg);
         2)
  | _ -> prerr_endline usage; 2

let compile_mli opts =
  match single_input opts with
  | None ->
      prerr_endline usage;
      2
  | Some file -> (
      let output_prefix =
        match (opts.cmi_prefix, opts.out) with
        | Some p, _ -> Some p
        | None, Some path -> Some (Filename.remove_extension path)
        | None, None -> Some (Filename.remove_extension file)
      in
      let modname =
        match output_prefix with
        | Some p -> Pipeline.module_name_of_file (p ^ ".mli")
        | None -> Pipeline.module_name_of_file file
      in
      let request =
        { (Pipeline.Request.create ~filename:file ~modname) with
          include_dirs = opts.include_dirs; output_prefix;
          nopervasives = opts.nopervasives; nostdlib = opts.nostdlib;
          no_alias_deps = opts.no_alias_deps; nolabels = opts.nolabels;
          open_modules = opts.open_modules }
      in
      match Pipeline.compile_interface_file request with
      | Ok _ -> 0
      | Error msg ->
          prerr_endline ("occ: error: " ^ msg);
          2)

let dump_lambda opts =
  match single_input opts with
  | None ->
      prerr_endline usage;
      2
  | Some file -> (
      let modname = Pipeline.module_name_of_file file in
      match Sys_util.read_file file with
      | exception Sys_error msg ->
          prerr_endline ("occ: error: " ^ msg);
          2
      | source -> (
          match
            Frontend.compile_implementation ~include_dirs:opts.include_dirs
              ~nopervasives:opts.nopervasives ~nostdlib:opts.nostdlib
              ~open_modules:opts.open_modules ~filename:file ~modname source
          with
          | Error { msg } ->
              prerr_endline ("occ: error: " ^ msg);
              2
          | Ok program ->
              Printlambda.lambda Format.std_formatter program.Lambda.code;
              Format.pp_print_newline Format.std_formatter ();
              0))

let bindgen opts =
  match single_input opts with
  | None ->
      prerr_endline usage;
      2
  | Some file -> (
      let modname = Pipeline.module_name_of_file file in
      let header_include =
        match opts.out with
        | Some h -> Some (Filename.basename h)
        | None -> None
      in
      match
        C_bindgen.generate_file ~include_dirs:opts.include_dirs
          ~nopervasives:opts.nopervasives ~nostdlib:opts.nostdlib
          ?header_include ~filename:file ~modname ()
      with
      | Error msg ->
          prerr_endline ("occ: error: " ^ msg);
          2
      | Ok { header; shim_c; _ } ->
          write_out opts.out header;
          (let shim_path =
             match (opts.shim_out, opts.out) with
             | Some p, _ -> Some p
             | None, Some h ->
                 Some (Filename.remove_extension h ^ "_shim.c")
             | None, None -> None
           in
           match shim_path with
           | Some p -> write_out (Some p) shim_c
           | None -> ());
          0)

let build opts =
  if opts.inputs = [] then begin
    prerr_endline usage;
    2
  end
  else
    let cfg =
      { (Driver.default_config ()) with
        inputs = opts.inputs;
        output = opts.out;
        target = opts.target;
        kind = opts.kind;
        include_dirs = opts.include_dirs;
        nostdlib = opts.nostdlib;
        nopervasives = opts.nopervasives;
        no_main = opts.no_main;
        emit_header = opts.emit_header;
        qbe_path = opts.qbe_path;
        cc_path = opts.cc_path;
        ar_path = opts.ar_path;
        sysroot = opts.sysroot;
        runtime_dir = opts.runtime_dir;
        prebuilt_rt_dir = opts.runtime_objects_dir;
        inline_single_thread_rc = opts.inline_single_thread_rc;
        prebuilt_stdlib_dir = opts.stdlib_dir;
        work_dir = opts.work_dir;
        extra_cflags = opts.extra_cflags;
        extra_ldflags = opts.extra_ldflags;
        verbose = opts.verbose }
    in
    match Driver.build cfg with
    | Ok _ -> 0
    | Error msg ->
        prerr_endline ("occ: error: " ^ msg);
        2

let () =
  let rest =
    if Array.length Sys.argv > 2 then
      List.init (Array.length Sys.argv - 2) (fun i -> Sys.argv.(i + 2))
    else []
  in
  let code =
    if Array.length Sys.argv < 2 then begin
      prerr_endline usage;
      2
    end
    else
      match parse_opts rest with
      | Error msg ->
          prerr_endline ("occ: " ^ msg);
          2
      | Ok opts -> (
          match Sys.argv.(1) with
          | "build" -> build opts
          | "compile" -> compile opts
          | "archive-opt" -> archive_opt opts
          | "object-opt" -> object_opt opts
          | "compile-mli" -> compile_mli opts
          | "bindgen" -> bindgen opts
          | "dump-lambda" -> dump_lambda opts
          | _ ->
              prerr_endline usage;
              2)
  in
  exit code
