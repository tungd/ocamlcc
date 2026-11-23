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
        assert (with_version "4" Fun.id = Some [[0], fn]);
        assert (with_version "7" Fun.id = None);
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
        assert (with_version "1" remove_effects = Some [[0], { fn with raises = May_raise }])
      in
      check (prefix ^ ".exports") ~header:"ocamlcc-exports-v" ();
      check (archive ^ ".opt") ~header:"ocamlcc-opt-v" ~archive ())
