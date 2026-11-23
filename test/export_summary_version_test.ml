let () =
  let dir = Filename.temp_dir "ocamlcc-summary-versions-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf dir) (fun () ->
      let prefix = Filename.concat dir "provider" in
      let cmi = prefix ^ ".cmi" and obj = prefix ^ ".o" in
      let archive = Filename.concat dir "libprovider.a" in
      let unit_name = "Provider" in
      Sys_util.write_file cmi "interface";
      Sys_util.write_file obj "object";
      Sys_util.write_file archive "archive";
      let fn : Anf.imported_function =
        { unit_name; symbol = "ocamlcc_Provider_step"; arity = 1;
          yields = false; raises = No_raise; returns_immediate = true;
          borrowed_entry = None; inline_leaf = None; inline_lambda = None; inline_init = None;
          unicode_validation = None }
      in
      Export_summary.write_unit ~prefix [[0], fn];
      Export_summary.write_archive ~archive ~units:[prefix ^ ".opt"];
      let check path ~header ?archive () =
        let contents = Sys_util.read_file path in
        let suffix = String.index contents ' ' in
        let with_version version rewrite =
          let body = String.sub contents suffix (String.length contents - suffix) in
          Sys_util.write_file path (header ^ version ^ rewrite body);
          let loader = Export_summary.Loader.create ?archive () in
          Export_summary.Loader.lookup loader ~unit_name ~cmi
        in
        assert (with_version "7" Fun.id = Some [[0], fn]);
        assert (with_version "8" Fun.id = None);
        let old_suspension body =
          Str.global_replace (Str.regexp_string "suspend=no") "false" body
        in
        let conservative = { fn with yields = true } in
        assert (with_version "6" old_suspension = Some [[0], conservative]);
        assert (with_version "7" old_suspension = Some [[0], conservative]);
        let remove_effects body =
          let lines = String.split_on_char '\n' body in
          let without_last_field line =
            match String.rindex_opt line ' ' with
            | Some index -> String.sub line 0 index
            | None -> line
          in
          match archive, lines with
          | None, digest :: object_name :: rows ->
              String.concat "\n" (digest :: object_name :: List.map without_last_field rows)
          | Some _, digest :: rows ->
              String.concat "\n" (digest :: List.map without_last_field rows)
          | _ -> failwith "missing export summary header"
        in
        assert (with_version "1" (fun body -> remove_effects (old_suspension body))
                = Some [[0], { conservative with raises = May_raise }])
      in
      check (prefix ^ ".exports") ~header:"ocamlcc-exports-v" ();
      check (archive ^ ".opt") ~header:"ocamlcc-opt-v" ~archive ())

let compile request source =
  match Pipeline.compile_source request source with
  | Ok output -> output
  | Error error -> failwith error

let () =
  let dir = Filename.temp_dir "ocamlcc-suspension-summary-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf dir) (fun () ->
    let prefix = Filename.concat dir "suspension_provider" in
    let provider = compile
      { (Pipeline.Request.create ~filename:(prefix ^ ".ml") ~modname:"Suspension_provider") with
        output_prefix = Some prefix; emit_cmi = true; export_policy = Seal }
      {|
      external perform : unit -> unit = "ocamlcc_effect_perform"
      external bridge : unit -> unit = "unregistered_bridge"
      external wide : int -> int -> int -> int -> int -> int -> int -> unit
        = "wide_bytecode" "unregistered_wide"
      let[@inline never] safe n = n + 1
      let[@inline never] run_effect n = perform (); safe n
      let[@inline never] foreign n = bridge (); safe n
      let[@inline never] wide_foreign n = wide n n n n n n n; safe n
      let[@inline never] dynamic f = f ()
      |} in
    Sys_util.write_file (prefix ^ ".o") "object";
    Export_summary.write_unit ~prefix provider.exports;
    let unit_summary = prefix ^ ".opt" in
    Export_summary.write_unit_object unit_summary;
    let has_shadow ?summaries call =
      let consumer = compile
        { (Pipeline.Request.create ~filename:"suspension_consumer.ml" ~modname:"Suspension_consumer") with
          include_dirs = [dir]; summaries }
        ("let call keep f n = let r = Suspension_provider." ^ call ^ " in r, keep")
      in
      match Str.search_forward (Str.regexp_string "$arc_fiber_push") consumer.ssa 0 with
      | _ -> true
      | exception Not_found -> false
    in
    let summaries = Export_summary.Loader.create () in
    assert (not (has_shadow ~summaries "safe n"));
    assert (has_shadow "safe n");
    List.iter (fun call ->
      if not (has_shadow ~summaries call) then failwith ("missing suspension roots for " ^ call))
      ["run_effect n"; "foreign n"; "wide_foreign n"; "dynamic f"];
    Sys_util.read_file unit_summary
    |> Str.global_replace (Str.regexp_string "suspend=no") "false"
    |> Str.global_replace (Str.regexp_string "suspend=may") "true"
    |> Sys_util.write_file unit_summary;
    Export_summary.write_unit_object unit_summary;
    assert (has_shadow ~summaries:(Export_summary.Loader.create ()) "safe n"))
