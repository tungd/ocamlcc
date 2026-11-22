let () =
  let dir = Filename.temp_dir "ocamlcc-dep-graph-" "" in
  let old_names = !Depend.free_structure_names in
  Fun.protect
    ~finally:(fun () ->
      Depend.free_structure_names := old_names;
      Sys_util.rm_rf dir)
    (fun () ->
      let consumer = Filename.concat dir "consumer.ml" in
      let provider = Filename.concat dir "provider.ml" in
      Sys_util.write_file consumer "let value = Provider.value\n";
      Sys_util.write_file provider "let value = 42\n";
      let caller_names = Depend.String.Set.singleton "Caller" in
      Depend.free_structure_names := caller_names;
      (match Dep_graph.plan_build_order [consumer; provider] with
       | Ok [{ path = first; _ }; { path = second; _ }] ->
           assert (first = provider && second = consumer)
       | Error msg -> failwith msg
       | Ok _ -> failwith "expected two dependency-ordered steps");
      assert (Depend.String.Set.equal !Depend.free_structure_names caller_names))
