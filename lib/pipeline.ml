(* Pipeline: source file -> QBE IL text. *)

let module_name_of_file filename =
  String.capitalize_ascii (Filename.remove_extension (Filename.basename filename))

let read_file filename =
  let ic = open_in_bin filename in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let compile_source ?(include_dirs = []) ?stdlib_dir ?output_prefix ?(emit_cmi = false)
    ?(nopervasives = false) ?(nostdlib = false) ?(no_alias_deps = false)
    ?(nolabels = false) ?(open_modules = []) ?(emit_entry = true) ?(inline_single_thread_rc = false) ~filename
    ~modname ?imports ?load_exports ?on_interface ?on_exports ?(seal_exports = false)
    source : (string, string) result =
  let cmis = ref [] in
  let on_cmis =
    if Option.is_some load_exports || Option.is_some on_interface
    then Some (fun paths -> cmis := paths)
    else None
  in
  match
    Frontend.compile_implementation ~include_dirs ?output_prefix ~emit_cmi
      ~nopervasives ~nostdlib ~no_alias_deps ~nolabels ~open_modules ?on_cmis ~filename
      ~modname source
  with
  | Error { msg } -> Error msg
  | Ok program -> (
      let lookup = Option.map (fun load unit_name ->
        Option.bind (List.assoc_opt unit_name !cmis) (fun cmi -> load ~unit_name ~cmi))
        load_exports in
      let exported = ref [] in
      let on_export_ids = Option.map (fun _ ids -> exported := ids) on_exports in
      match Anf.of_lambda ~use_builtins:(not nostdlib) ~include_dirs ?stdlib_dir
              ?imports ?load_exports:lookup ?on_export_ids program with
      | Error what -> Error (Printf.sprintf "unsupported: %s" what)
      | Ok anf ->
          let prefix = Option.value ~default:(Filename.remove_extension filename) output_prefix in
          let cmi = prefix ^ ".cmi" in
          Option.iter (fun save ->
            let path =
              if Sys.file_exists (Filename.remove_extension filename ^ ".mli")
              then List.assoc_opt modname !cmis
              else if Sys.file_exists cmi then Some cmi else None
            in
            Option.iter save path) on_interface;
          let inline_leaf =
            match !exported with
            | [] -> (fun _ -> None)
            | _ -> Anf.inline_export_leaves program.code anf.code
          in
          let anf, effects = Arc_pass.run_with_effects anf in
          let il, exports = Codegen.compile_with_exports ~emit_entry ~inline_single_thread_rc
              ~exported:!exported ~effects ~inline_leaf anf in
          let ssa, exports =
            if seal_exports then Export_summary.seal il exports
            else Qbe_il.to_string il, exports in
          Option.iter (fun save -> save exports) on_exports;
          Ok ssa)

let compile_file ?(include_dirs = []) ?stdlib_dir ?output_prefix ?(emit_cmi = false)
    ?(nopervasives = false) ?(nostdlib = false) ?(no_alias_deps = false)
    ?(nolabels = false) ?(open_modules = []) ?(emit_entry = true) ?(inline_single_thread_rc = false) ~filename
    ~modname ?imports ?load_exports ?on_interface ?on_exports ?seal_exports () : (string, string) result =
  match read_file filename with
  | exception Sys_error msg -> Error msg
  | source ->
      compile_source ~include_dirs ?stdlib_dir ?output_prefix ~emit_cmi ~nopervasives
        ~nostdlib ~no_alias_deps ~nolabels ~open_modules ~emit_entry ~inline_single_thread_rc ~filename
        ~modname ?imports ?load_exports ?on_interface ?on_exports ?seal_exports source

let compile_interface_file ?(include_dirs = []) ?output_prefix
    ?(nopervasives = false) ?(nostdlib = false) ?(no_alias_deps = false)
    ?(nolabels = false) ?(open_modules = []) ~filename ~modname () :
    (string, string) result =
  match read_file filename with
  | exception Sys_error msg -> Error msg
  | source -> (
      match
        Frontend.compile_interface ~include_dirs ?output_prefix ~nopervasives
          ~nostdlib ~no_alias_deps ~nolabels ~open_modules ~filename ~modname
          source
      with
      | Error { msg } -> Error msg
      | Ok cmi_path -> Ok cmi_path)
