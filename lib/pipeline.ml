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
    ~modname ?imports ?on_exports source : (string, string) result =
  match
    Frontend.compile_implementation ~include_dirs ?output_prefix ~emit_cmi
      ~nopervasives ~nostdlib ~no_alias_deps ~nolabels ~open_modules ~filename
      ~modname source
  with
  | Error { msg } -> Error msg
  | Ok program -> (
      let exported = ref [] in
      let on_export_ids = Option.map (fun _ ids -> exported := ids) on_exports in
      match Anf.of_lambda ~use_builtins:(not nostdlib) ~include_dirs ?stdlib_dir
              ?imports ?on_export_ids program with
      | Error what -> Error (Printf.sprintf "unsupported: %s" what)
      | Ok anf ->
          let inline_leaf =
            match !exported with
            | [] -> (fun _ -> None)
            | _ -> Anf.inline_export_leaves program.code anf.code
          in
          let anf, effects = Arc_pass.run_with_effects anf in
          let il, exports = Codegen.compile_with_exports ~emit_entry ~inline_single_thread_rc
              ~exported:!exported ~effects ~inline_leaf anf in
          Option.iter (fun save -> save exports) on_exports;
          Ok (Qbe_il.to_string il))

let compile_file ?(include_dirs = []) ?stdlib_dir ?output_prefix ?(emit_cmi = false)
    ?(nopervasives = false) ?(nostdlib = false) ?(no_alias_deps = false)
    ?(nolabels = false) ?(open_modules = []) ?(emit_entry = true) ?(inline_single_thread_rc = false) ~filename
    ~modname ?imports ?on_exports () : (string, string) result =
  match read_file filename with
  | exception Sys_error msg -> Error msg
  | source ->
      compile_source ~include_dirs ?stdlib_dir ?output_prefix ~emit_cmi ~nopervasives
        ~nostdlib ~no_alias_deps ~nolabels ~open_modules ~emit_entry ~inline_single_thread_rc ~filename
        ~modname ?imports ?on_exports source

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
