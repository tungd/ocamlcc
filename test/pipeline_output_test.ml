let get = function Ok result -> result | Error msg -> failwith msg

let () =
  let dir = Filename.temp_dir "ocamlcc-pipeline-output-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf dir) (fun () ->
      let prefix = Filename.concat dir "provider" in
      let filename = prefix ^ ".ml" in
      let open Pipeline in
      let request =
        { (Request.create ~filename ~modname:"Provider") with
          include_dirs = [dir]; output_prefix = Some prefix;
          emit_entry = false; export_policy = Seal }
      in
      let intf = prefix ^ ".mli" in
      Sys_util.write_file intf "val answer : int -> int\n";
      let interface_request = { request with filename = intf } in
      let cmi = get (compile_interface_file interface_request) in
      let output = get (compile_source request "let answer n = n + 1") in
      assert (output.interface = Some cmi);
      match output.exports with
      | [([0], fn)] ->
          assert (fn.arity = 1);
          assert (String.starts_with ~prefix:"ocamlcc_Provider_answer__" fn.symbol)
      | _ -> failwith "expected one sealed export for Provider.answer")
