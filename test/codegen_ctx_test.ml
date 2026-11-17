(* Unit tests for modular Codegen_ctx (with_fn_state isolation) and
   Codegen_analysis (SCC & tail-callees). *)

let () =
  let b = Codegen_ctx.create "Testmod" in
  Codegen_ctx.start_block b "outer_start";
  Codegen_ctx.emit b (Qbe_il.Copy (Long, Temp "x", Int 1L));
  (* Nested fn_state must isolate insts/blocks/labels/try_stack and restore on
     normal return and on exception. *)
  Codegen_ctx.with_fn_state b ~self:None ~cur_group:None ~entry_label:"loop"
    ~in_init:false (fun () ->
      Codegen_ctx.start_block b "inner_start";
      Codegen_ctx.emit b (Qbe_il.Copy (Long, Temp "y", Int 2L));
      Codegen_ctx.close_ret b (Some (Int 2L)));
  let ok_normal =
    b.cur_fn.open_label = "outer_start"
    && List.length b.cur_fn.insts = 1
    && b.cur_fn.blocks = []
    && b.cur_fn.in_init = true
  in
  (try
     Codegen_ctx.with_fn_state b ~self:None ~cur_group:(Some "g")
       ~entry_label:"dispatch" ~in_init:false (fun () ->
         Codegen_ctx.emit b (Qbe_il.Copy (Long, Temp "z", Int 3L));
         failwith "boom")
   with Failure _ -> ());
  let ok_exn =
    b.cur_fn.open_label = "outer_start"
    && List.length b.cur_fn.insts = 1
    && b.cur_fn.cur_group = None
    && b.cur_fn.entry_label = "start"
    && b.cur_fn.in_init = true
  in
  (* SCC check: mutual cycle [a <-> b] + standalone [c] *)
  let a = Ident.create_local "a" in
  let b_id = Ident.create_local "b" in
  let c = Ident.create_local "c" in
  let edges id =
    if Ident.same id a then Ident.Set.singleton b_id
    else if Ident.same id b_id then Ident.Set.singleton a
    else Ident.Set.empty
  in
  let sccs = Codegen_analysis.strongly_connected_components [ a; b_id; c ] edges in
  let ok_scc =
    List.length sccs = 2
    && List.exists (fun comp -> List.length comp = 2) sccs
    && List.exists (fun comp -> List.length comp = 1) sccs
  in
  Printf.printf "with_fn_state_normal: %s\n"
    (if ok_normal then "PASS" else "FAIL");
  Printf.printf "with_fn_state_exn: %s\n" (if ok_exn then "PASS" else "FAIL");
  Printf.printf "scc_grouping: %s\n" (if ok_scc then "PASS" else "FAIL");
  exit (if ok_normal && ok_exn && ok_scc then 0 else 1)
