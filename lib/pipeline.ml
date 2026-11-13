(* Pipeline: source file -> QBE IL text. *)

let module_name_of_file filename =
  String.capitalize_ascii (Filename.remove_extension (Filename.basename filename))

let read_file filename =
  let ic = open_in_bin filename in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let compile_file ~filename ~modname : (string, string) result =
  match read_file filename with
  | exception Sys_error msg -> Error msg
  | source -> (
      match Frontend.compile_implementation ~filename ~modname source with
      | Error { msg } -> Error msg
      | Ok program -> (
          match Codegen.compile_program program with
          | Error what -> Error (Printf.sprintf "unsupported: %s" what)
          | Ok module_ -> Ok (Qbe_il.to_string module_)))
