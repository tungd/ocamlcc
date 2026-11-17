(* ocamlcc CLI.

   Subcommands:
     ocamlcc compile [flags] <file.ml> [-o <out.ssa>]   emit QBE IL
     ocamlcc compile-mli [flags] <file.mli> [-o <out.cmi>]  emit .cmi
     ocamlcc bindgen [flags] <file.mli> [-o <out.h>] [--shim <out.c>]  emit C header + shim
     ocamlcc dump-lambda [flags] <file.ml>              print the Lambda IR *)

let usage =
  "usage: ocamlcc compile [-I dir] [--nostdlib] [--nopervasives] [--emit-cmi] \
   [--cmi-prefix p] [--mod] <file.ml> [-o <out.ssa>]\n\
   \       ocamlcc compile-mli [-I dir] [--nostdlib] [--nopervasives] \
   <file.mli> [-o <out.cmi>]\n\
   \       ocamlcc bindgen [-I dir] [--nostdlib] [--nopervasives] \
   [--shim <out.c>] <file.mli> [-o <out.h>]\n\
   \       ocamlcc dump-lambda [-I dir] [--nostdlib] [--nopervasives] <file.ml>"

type cli_opts = {
  include_dirs : string list;
  nostdlib : bool;
  nopervasives : bool;
  emit_cmi : bool;
  cmi_prefix : string option;
  is_mod : bool;
  shim_out : string option;
  out : string option;
  input : string option;
}

let default_opts =
  { include_dirs = [];
    nostdlib = false;
    nopervasives = false;
    emit_cmi = false;
    cmi_prefix = None;
    is_mod = false;
    shim_out = None;
    out = None;
    input = None }

let parse_opts args =
  let rec go opts = function
    | [] -> Ok { opts with include_dirs = List.rev opts.include_dirs }
    | "-I" :: dir :: rest ->
        go { opts with include_dirs = dir :: opts.include_dirs } rest
    | "--nostdlib" :: rest -> go { opts with nostdlib = true } rest
    | "--nopervasives" :: rest -> go { opts with nopervasives = true } rest
    | "--emit-cmi" :: rest -> go { opts with emit_cmi = true } rest
    | "--cmi-prefix" :: p :: rest ->
        go { opts with cmi_prefix = Some p; emit_cmi = true } rest
    | "--mod" :: rest -> go { opts with is_mod = true } rest
    | "--shim" :: path :: rest -> go { opts with shim_out = Some path } rest
    | "-o" :: path :: rest -> go { opts with out = Some path } rest
    | arg :: _ when String.length arg > 0 && arg.[0] = '-' ->
        Error (Printf.sprintf "unknown flag: %s" arg)
    | file :: rest -> (
        match opts.input with
        | None -> go { opts with input = Some file } rest
        | Some _ -> Error (Printf.sprintf "unexpected argument: %s" file))
  in
  go default_opts args

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

let compile opts =
  match opts.input with
  | None ->
      prerr_endline usage;
      2
  | Some file -> (
      let modname = Pipeline.module_name_of_file file in
      let output_prefix =
        match opts.cmi_prefix with
        | Some _ as p -> p
        | None when opts.emit_cmi -> Some (Filename.remove_extension file)
        | None -> None
      in
      match
        Pipeline.compile_file ~include_dirs:opts.include_dirs ?output_prefix
          ~emit_cmi:opts.emit_cmi ~nopervasives:opts.nopervasives
          ~nostdlib:opts.nostdlib ~emit_entry:(not opts.is_mod)
          ~filename:file ~modname ()
      with
      | Ok ssa ->
          write_out opts.out ssa;
          0
      | Error msg ->
          prerr_endline ("ocamlcc: error: " ^ msg);
          2)

let compile_mli opts =
  match opts.input with
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
      match
        Pipeline.compile_interface_file ~include_dirs:opts.include_dirs
          ?output_prefix ~nopervasives:opts.nopervasives
          ~nostdlib:opts.nostdlib ~filename:file ~modname ()
      with
      | Ok _ -> 0
      | Error msg ->
          prerr_endline ("ocamlcc: error: " ^ msg);
          2)

let dump_lambda opts =
  match opts.input with
  | None ->
      prerr_endline usage;
      2
  | Some file -> (
      let modname = Pipeline.module_name_of_file file in
      let source = read_file file in
      match
        Frontend.compile_implementation ~include_dirs:opts.include_dirs
          ~nopervasives:opts.nopervasives ~nostdlib:opts.nostdlib
          ~filename:file ~modname source
      with
      | Error { msg } ->
          prerr_endline ("ocamlcc: error: " ^ msg);
          2
      | Ok program ->
          Printlambda.lambda Format.std_formatter program.Lambda.code;
          Format.pp_print_newline Format.std_formatter ();
          0)

let bindgen opts =
  match opts.input with
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
          prerr_endline ("ocamlcc: error: " ^ msg);
          2
      | Ok { header; shim_c } ->
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
          prerr_endline ("ocamlcc: " ^ msg);
          2
      | Ok opts -> (
          match Sys.argv.(1) with
          | "compile" -> compile opts
          | "compile-mli" -> compile_mli opts
          | "bindgen" -> bindgen opts
          | "dump-lambda" -> dump_lambda opts
          | _ ->
              prerr_endline usage;
              2)
  in
  exit code
