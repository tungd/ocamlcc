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
      assert (Depend.String.Set.equal !Depend.free_structure_names caller_names));
  let dir = Filename.temp_dir "ocamlcc-dep-dag-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf dir) (fun () ->
    let write name contents =
      let path = Filename.concat dir name in
      Sys_util.write_file path contents;
      path
    in
    let a = write "a.ml" "let x = 1\n" in
    let b = write "b.ml" "let y = 2\n" in
    let c = write "c.ml" "let z = A.x + B.y\n" in
    (match Dep_graph.plan_build_dag [c; b; a] with
     | Ok [g1; g2; g3] ->
         assert (List.length g1.steps = 1 && g1.deps = []);
         assert (List.length g2.steps = 1 && g2.deps = []);
         assert (List.length g3.steps = 1 && List.sort Int.compare g3.deps = [0; 1]);
         assert ((List.hd g3.steps).path = c)
     | Ok groups ->
         failwith (Printf.sprintf "expected 3 DAG groups, got %d" (List.length groups))
     | Error msg -> failwith msg);
    let m1_mli = write "m1.mli" "val f : int -> int\n" in
    let m2_mli = write "m2.mli" "val g : int -> int\n" in
    let m1_ml = write "m1.ml" "let f n = if n <= 0 then 0 else M2.g (n - 1)\n" in
    let m2_ml = write "m2.ml" "let g n = if n <= 0 then 1 else M1.f (n - 1)\n" in
    let top = write "top.ml" "let v = M1.f 3\n" in
    match Dep_graph.plan_build_dag [top; m1_ml; m2_ml; m1_mli; m2_mli] with
    | Ok groups ->
        let cycle_groups = List.filter (fun (g : Dep_graph.Plan.group) -> List.length g.steps = 2) groups in
        assert (List.length cycle_groups = 1);
        let paths = List.map (fun (s : Dep_graph.Step.t) -> s.path) (List.hd cycle_groups).steps in
        assert (List.mem m1_ml paths && List.mem m2_ml paths)
    | Error msg -> failwith msg)
