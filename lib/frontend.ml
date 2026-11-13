(* Frontend: OCaml source -> typed, pattern-match-compiled Lambda IR.

   Links against the official compiler-libs: Parse (syntax), Typemod
   (typechecking), Translmod (Lambda lowering). Frontend fidelity is free —
   modules, functors, GADTs and polymorphic variants all reach us already
   desugared; rejecting constructs happens downstream in [Codegen]. *)

type error = { msg : string }

let error_msg exn =
  match exn with
  | Location.Error err ->
      let buf = Buffer.create 256 in
      let ppf = Format.formatter_of_buffer buf in
      Format.fprintf ppf "%a@." Location.print_report err;
      Format.pp_print_flush ppf ();
      String.trim (Buffer.contents buf)
  | exn -> Printexc.to_string exn

(* Initialises the standard library path and silences warnings; the middle-end
   is strict about the constructs it accepts, so warnings add no signal yet. *)
let init () =
  Compmisc.init_path ();
  ignore (Warnings.parse_options false "-a");
  (* Never emit .cmi/.cmx artifacts, e.g. for the builtin probe modules. *)
  Clflags.dont_write_files := true

let compile_implementation ~filename ~modname source :
    (Lambda.program, error) result =
  try
    init ();
    Location.input_name := filename;
    let lexbuf = Lexing.from_string source in
    lexbuf.Lexing.lex_curr_p <-
      { lexbuf.Lexing.lex_curr_p with pos_fname = filename };
    let parsetree = Parse.implementation lexbuf in
    let env = Compmisc.initial_env () in
    let unit_info =
      Unit_info.make ~source_file:filename Impl
        (Filename.remove_extension filename)
    in
    let impl = Typemod.type_implementation unit_info env parsetree in
    let program =
      Translmod.transl_implementation modname
        (impl.Typedtree.structure, impl.Typedtree.coercion)
    in
    Ok program
  with exn -> Error { msg = error_msg exn }
