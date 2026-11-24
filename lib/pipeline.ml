(* Pipeline: source file -> QBE IL text. *)

let module_name_of_file filename =
  String.capitalize_ascii (Filename.remove_extension (Filename.basename filename))

module Request = struct
  type export_policy = Omit | Collect | Seal

  type t = {
    filename : string;
    modname : string;
    include_dirs : string list;
    hidden_include_dirs : string list;
    stdlib_dir : string option;
    output_prefix : string option;
    emit_cmi : bool;
    nopervasives : bool;
    nostdlib : bool;
    no_alias_deps : bool;
    nolabels : bool;
    open_modules : string list;
    emit_entry : bool;
    inline_single_thread_rc : bool;
    imports : (string * Anf.exports) list;
    summaries : Export_summary.Loader.t option;
    export_policy : export_policy;
  }

  let create ~filename ~modname =
    { filename; modname; include_dirs = []; hidden_include_dirs = []; stdlib_dir = None;
      output_prefix = None; emit_cmi = false; nopervasives = false;
      nostdlib = false; no_alias_deps = false; nolabels = false;
      open_modules = []; emit_entry = true; inline_single_thread_rc = false;
      imports = []; summaries = None; export_policy = Omit }
end

module Output = struct
  type t = {
    ssa : string;
    interface : string option;
    exports : Anf.exports;
  }
end

let compile_source (request : Request.t) source =
  let open Sys_util.Result_syntax in
  let { Request.filename; modname; include_dirs; hidden_include_dirs; stdlib_dir; output_prefix;
        emit_cmi; nopervasives; nostdlib; no_alias_deps; nolabels; open_modules;
        emit_entry; inline_single_thread_rc; imports; summaries; export_policy } =
    request
  in
  let* implementation =
    Frontend.compile_unit ~include_dirs ~hidden_include_dirs ?output_prefix ~emit_cmi ~nopervasives
      ~nostdlib ~no_alias_deps ~nolabels ~open_modules
      ~resolve_imports:(Option.is_some summaries) ~filename ~modname source
    |> Result.map_error (fun { Frontend.msg } -> msg)
  in
  let { Frontend.Implementation.lambda; cmis; interface; nonsuspending_externals } = implementation in
  let load_exports = Option.map (fun loader unit_name ->
      let open Sys_util.Option_syntax in
      let* cmi = List.assoc_opt unit_name cmis in
      Export_summary.Loader.lookup loader ~unit_name ~cmi) summaries
  in
  let* anf, exported =
    Anf.lower ~use_builtins:(not nostdlib) ~include_dirs ?stdlib_dir ~imports
      ?load_exports ~nonsuspending_externals ~collect_exports:(export_policy <> Omit) lambda
    |> Result.map_error (Printf.sprintf "unsupported: %s")
  in
  let inline_leaf =
    match exported with
    | [] -> (fun _ -> None)
    | _ -> Lambda_opt.inline_export_leaves lambda.code anf.code
  in
  let anf, effects, borrowed = Arc_pass.run_with_effects ~exported anf in
  let unicode_validation =
    if modname = "Stdlib__Uchar" && exported <> [] then
      Lambda_opt.unicode_validations lambda.code
    else fun _ -> None
  in
  let il, exports =
    Codegen.compile_with_exports ~emit_entry ~inline_single_thread_rc
      ~unicode_validation ~exported ~effects ~inline_leaf ~borrowed anf
  in
  let ssa, exports =
    match export_policy with
    | Seal -> Export_summary.seal il exports
    | Collect | Omit -> Qbe_il.to_string il, exports
  in
  Ok { Output.ssa; interface; exports }

let read_source filename =
  try Ok (Sys_util.read_file filename) with Sys_error msg -> Error msg

let compile_file (request : Request.t) =
  let open Sys_util.Result_syntax in
  let* source = read_source request.filename in
  compile_source request source

let compile_interface_file (request : Request.t) =
  let open Sys_util.Result_syntax in
  let { Request.filename; modname; include_dirs; hidden_include_dirs; output_prefix; nopervasives;
        nostdlib; no_alias_deps; nolabels; open_modules; _ } = request
  in
  let* source = read_source filename in
  Frontend.compile_interface ~include_dirs ~hidden_include_dirs ?output_prefix ~nopervasives
    ~nostdlib ~no_alias_deps ~nolabels ~open_modules ~filename ~modname source
  |> Result.map_error (fun { Frontend.msg } -> msg)
