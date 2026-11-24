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

let with_flags ~include_dirs ~emit_cmi ~nopervasives ~nostdlib
    ?(hidden_include_dirs = []) ?(no_alias_deps = false) ?(nolabels = false)
    ?(open_modules = []) f =
  let saved_inc = !Clflags.include_dirs in
  let saved_hidden = !Clflags.hidden_include_dirs in
  let saved_dont = !Clflags.dont_write_files in
  let saved_nop = !Clflags.nopervasives in
  let saved_nostd = !Clflags.no_std_include in
  let saved_noad = !Clflags.no_alias_deps in
  let saved_classic = !Clflags.classic in
  let saved_open = !Clflags.open_modules in
  Fun.protect
    ~finally:(fun () ->
      Clflags.include_dirs := saved_inc;
      Clflags.hidden_include_dirs := saved_hidden;
      Clflags.dont_write_files := saved_dont;
      Clflags.nopervasives := saved_nop;
      Clflags.no_std_include := saved_nostd;
      Clflags.no_alias_deps := saved_noad;
      Clflags.classic := saved_classic;
      Clflags.open_modules := saved_open;
      Compmisc.init_path ())
    (fun () ->
      Clflags.include_dirs := include_dirs;
      Clflags.hidden_include_dirs := hidden_include_dirs;
      Clflags.dont_write_files := not emit_cmi;
      Clflags.nopervasives := nopervasives;
      Clflags.no_std_include := nostdlib;
      Clflags.no_alias_deps := no_alias_deps;
      Clflags.classic := nolabels;
      (* Clflags.open_modules stores modules in reverse CLI order (later -open
         at the head so it shadows earlier ones). *)
      Clflags.open_modules := List.rev open_modules;
      ignore (Warnings.parse_options false "-a");
      Compmisc.init_path ();
      f ())

module Implementation = struct
  type t = {
    lambda : Lambda.program;
    cmis : (string * string) list;
    interface : string option;
    nonsuspending_externals : string list;
  }
end

(* The attribute describes the native symbol's ABI. Read it from typed
   declarations and imported references before Lambda drops attributes. *)
let nonsuspending_externals structure =
  let symbols = ref [] in
  let record (description : Types.value_description) =
    let nosuspend attribute =
      attribute.Parsetree.attr_name.txt = "ocamlcc.nosuspend"
    in
    match description.val_kind with
    | Val_prim primitive when List.exists nosuspend description.val_attributes ->
        symbols := Primitive.native_name primitive :: !symbols
    | _ -> ()
  in
  let default = Tast_iterator.default_iterator in
  let expr iterator (expression : Typedtree.expression) =
    (match expression.exp_desc with
     | Texp_ident (_, _, description) -> record description
     | _ -> ());
    default.expr iterator expression
  in
  let value_description iterator (declaration : Typedtree.value_description) =
    record declaration.val_val;
    default.value_description iterator declaration
  in
  let iterator = { default with expr; value_description } in
  iterator.structure iterator structure;
  List.sort_uniq String.compare !symbols

let compile_unit ?(include_dirs = []) ?hidden_include_dirs ?output_prefix ?(emit_cmi = false)
    ?(nopervasives = false) ?(nostdlib = false) ?(no_alias_deps = false)
    ?(nolabels = false) ?(open_modules = []) ~resolve_imports
    ~filename ~modname source : (Implementation.t, error) result =
  try
    with_flags ~include_dirs ?hidden_include_dirs ~emit_cmi ~nopervasives ~nostdlib ~no_alias_deps
      ~nolabels ~open_modules (fun () ->
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
        let find_cmi name =
          match Load_path.find_normalized (name ^ ".cmi") with
          | path -> Some path
          | exception Not_found -> None
        in
        let interface =
          if Sys.file_exists (Filename.remove_extension filename ^ ".mli") then
            find_cmi modname
          else if emit_cmi then
            let path = Unit_info.Artifact.filename (Unit_info.cmi unit_info) in
            if Sys.file_exists path then Some path else None
          else None
        in
        let cmis =
          if resolve_imports then
            Env.imports ()
            |> List.filter_map (fun (name, _) ->
                   Option.map (fun path -> name, path) (find_cmi name))
          else []
        in
        Ok { Implementation.lambda = program; cmis; interface;
             nonsuspending_externals = nonsuspending_externals impl.structure })
  with exn -> Error { msg = error_msg exn }

let compile_implementation ?include_dirs ?hidden_include_dirs ?output_prefix ?emit_cmi ?nopervasives
    ?nostdlib ?no_alias_deps ?nolabels ?open_modules ~filename ~modname source =
  compile_unit ?include_dirs ?hidden_include_dirs ?output_prefix ?emit_cmi ?nopervasives ?nostdlib
    ?no_alias_deps ?nolabels ?open_modules ~resolve_imports:false
    ~filename ~modname source
  |> Result.map (fun (unit : Implementation.t) -> unit.lambda)

let compile_interface ?(include_dirs = []) ?hidden_include_dirs ?output_prefix
    ?(nopervasives = false) ?(nostdlib = false) ?(no_alias_deps = false)
    ?(nolabels = false) ?(open_modules = []) ~filename ~modname source :
    (string, error) result =
  ignore modname;
  try
    with_flags ~include_dirs ?hidden_include_dirs ~emit_cmi:true ~nopervasives ~nostdlib
      ~no_alias_deps ~nolabels ~open_modules (fun () ->
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

let with_typed_interface ?(include_dirs = []) ?(nopervasives = false)
    ?(nostdlib = false) ~filename source f : ('a, error) result =
  try
    with_flags ~include_dirs ~emit_cmi:false ~nopervasives ~nostdlib (fun () ->
        Location.input_name := filename;
        let lexbuf = Lexing.from_string source in
        lexbuf.Lexing.lex_curr_p <-
          { lexbuf.Lexing.lex_curr_p with pos_fname = filename };
        let parsetree = Parse.interface lexbuf in
        let env = Compmisc.initial_env () in
        let sg = Typemod.type_interface env parsetree in
        Ok (f sg sg.Typedtree.sig_final_env))
  with exn -> Error { msg = error_msg exn }
