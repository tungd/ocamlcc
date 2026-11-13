(* ocamlcc CLI.

   Subcommands:
     ocamlcc compile <file.ml> [-o <out.ssa>]   emit QBE IL
     ocamlcc dump-lambda <file.ml>              print the Lambda IR *)

let usage =
  "usage: ocamlcc compile <file.ml> [-o <out.ssa>]\n\
   \      ocamlcc dump-lambda <file.ml>"

let read_file filename =
  let ic = open_in_bin filename in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      really_input_string ic (in_channel_length ic))

let write_out out ssa =
  match out with
  | Some path ->
      let oc = open_out_bin path in
      Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
          output_string oc ssa)
  | None -> print_string ssa

let compile file out =
  let modname = Pipeline.module_name_of_file file in
  match Pipeline.compile_file ~filename:file ~modname with
  | Ok ssa ->
      write_out out ssa;
      0
  | Error msg ->
      prerr_endline ("ocamlcc: error: " ^ msg);
      2

let dump_lambda file =
  let modname = Pipeline.module_name_of_file file in
  let source = read_file file in
  match Frontend.compile_implementation ~filename:file ~modname source with
  | Error { msg } ->
      prerr_endline ("ocamlcc: error: " ^ msg);
      2
  | Ok program ->
      Printlambda.lambda Format.std_formatter program.Lambda.code;
      Format.pp_print_newline Format.std_formatter ();
      0

let () =
  let code =
    match Sys.argv with
    | [| _; "compile"; file |] -> compile file None
    | [| _; "compile"; file; "-o"; out |] -> compile file (Some out)
    | [| _; "dump-lambda"; file |] -> dump_lambda file
    | _ ->
        prerr_endline usage;
        2
  in
  exit code
