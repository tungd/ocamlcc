(* Frontend: OCaml source -> typed, pattern-match-compiled Lambda IR.

   Links against the official compiler-libs: Parse (syntax), Typemod
   (typechecking), Translmod (Lambda lowering). Frontend fidelity is free —
   modules, functors, GADTs and polymorphic variants all reach us already
   desugared; rejecting constructs happens downstream in [Codegen]. *)

type error = { msg : string }

let error_msg exn =
  let format_report err =
    let buf = Buffer.create 256 in
    let ppf = Format.formatter_of_buffer buf in
    Format.fprintf ppf "%a@." Location.print_report err;
    Format.pp_print_flush ppf ();
    String.trim (Buffer.contents buf)
  in
  match Location.error_of_exn exn with
  | Some (`Ok err) -> format_report err
  | Some `Already_displayed | None -> (
      match exn with
      | Location.Error err -> format_report err
      | exn -> Printexc.to_string exn)

let with_flags ~include_dirs ~emit_cmi ~nopervasives ~nostdlib f =
  let saved_inc = !Clflags.include_dirs in
  let saved_dont = !Clflags.dont_write_files in
  let saved_nop = !Clflags.nopervasives in
  let saved_nostd = !Clflags.no_std_include in
  Fun.protect
    ~finally:(fun () ->
      Clflags.include_dirs := saved_inc;
      Clflags.dont_write_files := saved_dont;
      Clflags.nopervasives := saved_nop;
      Clflags.no_std_include := saved_nostd;
      Compmisc.init_path ())
    (fun () ->
      Clflags.include_dirs := include_dirs;
      Clflags.dont_write_files := not emit_cmi;
      Clflags.nopervasives := nopervasives;
      Clflags.no_std_include := nostdlib;
      ignore (Warnings.parse_options false "-a");
      Compmisc.init_path ();
      f ())

let compile_implementation ?(include_dirs = []) ?output_prefix ?(emit_cmi = false)
    ?(nopervasives = false) ?(nostdlib = false) ~filename ~modname source :
    (Lambda.program, error) result =
  try
    with_flags ~include_dirs ~emit_cmi ~nopervasives ~nostdlib (fun () ->
        Location.input_name := filename;
        let lexbuf = Lexing.from_string source in
        lexbuf.Lexing.lex_curr_p <-
          { lexbuf.Lexing.lex_curr_p with pos_fname = filename };
        let parsetree = Parse.implementation lexbuf in
        let env = Compmisc.initial_env () in
        let prefix =
          Option.value ~default:(Filename.remove_extension filename)
            output_prefix
        in
        let unit_info = Unit_info.make ~source_file:filename Impl prefix in
        let impl = Typemod.type_implementation unit_info env parsetree in
        let program =
          Translmod.transl_implementation modname
            (impl.Typedtree.structure, impl.Typedtree.coercion)
        in
        Ok program)
  with exn -> Error { msg = error_msg exn }

let compile_interface ?(include_dirs = []) ?output_prefix
    ?(nopervasives = false) ?(nostdlib = false) ~filename ~modname source :
    (string, error) result =
  ignore modname;
  try
    with_flags ~include_dirs ~emit_cmi:true ~nopervasives ~nostdlib (fun () ->
        Location.input_name := filename;
        let lexbuf = Lexing.from_string source in
        lexbuf.Lexing.lex_curr_p <-
          { lexbuf.Lexing.lex_curr_p with pos_fname = filename };
        let parsetree = Parse.interface lexbuf in
        let env = Compmisc.initial_env () in
        let prefix =
          Option.value ~default:(Filename.remove_extension filename)
            output_prefix
        in
        let unit_info = Unit_info.make ~source_file:filename Intf prefix in
        let sg = Typemod.type_interface env parsetree in
        let cmi_art = Unit_info.cmi unit_info in
        let cmi =
          Env.save_signature ~alerts:Misc.Stdlib.String.Map.empty
            sg.Typedtree.sig_type cmi_art
        in
        Typemod.save_signature unit_info sg env cmi;
        Ok (Unit_info.Artifact.filename cmi_art))
  with exn -> Error { msg = error_msg exn }
