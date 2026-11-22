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
    Codegen_ctx.open_label b = "outer_start"
    && Codegen_ctx.block_is_open b
    && Codegen_ctx.in_initializer b
  in
  (try
     Codegen_ctx.with_fn_state b ~self:None ~cur_group:(Some "g")
       ~entry_label:"dispatch" ~in_init:false (fun () ->
         Codegen_ctx.emit b (Qbe_il.Copy (Long, Temp "z", Int 3L));
         failwith "boom")
   with Failure _ -> ());
  Codegen_ctx.close_ret b (Some (Qbe_il.Temp "x"));
  let ok_exn =
    Codegen_ctx.current_group b = None
    && Codegen_ctx.in_initializer b
    && Codegen_ctx.finish_blocks b =
       [{ Qbe_il.label = "outer_start";
          insts = [Qbe_il.Copy (Long, Temp "x", Int 1L)];
          term = Ret (Some (Temp "x")) }]
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
