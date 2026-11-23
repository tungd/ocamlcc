(* Codegen function, trampoline group, and closure emission. *)

open Codegen_ctx
open Qbe_il

let emit_group_wrapper b ~wrapper_name ~pass_clos ~target_global ~arity
    ~tag_opt ~group_arity : unit =
  let clos_p = fresh_name b "clos" in
  let param_names = List.init arity (fun _ -> fresh_name b "carg") in
  let param_vals = List.map (fun n -> Temp n) param_names in
  let call_res = fresh_name b "wres" in
  let call_args =
    let clos_prefix = if pass_clos then [ (Long, Temp clos_p) ] else [] in
    match tag_opt with
    | Some tag ->
        let padded = pad_to group_arity param_vals in
        clos_prefix
        @ ((Long, Int tag) :: List.map (fun v -> (Long, v)) padded)
    | None -> clos_prefix @ List.map (fun v -> (Long, v)) param_vals
  in
  let call_inst =
    Call (Long, Temp call_res, { fn = Global target_global; args = call_args })
  in
  let func =
    { name = wrapper_name;
      export = false;
      retty = Some Long;
      params = (Long, clos_p) :: List.map (fun n -> (Long, n)) param_names;
      blocks =
        [ { label = "start";
            insts = [ call_inst ];
            term = Ret (Some (Temp call_res)) } ] }
  in
  add_function b func

let rec closure_value_of b id : t =
  let data_sym =
    closure_wrapper b id (fun () ->
        let info = function_info b id in
        let wrapper_name = alloc_global_name b id in
        emit_group_wrapper b ~wrapper_name ~pass_clos:false
          ~target_global:info.global ~arity:info.arity ~tag_opt:info.tag
          ~group_arity:info.group_arity;
        let sym = next_data_name b "clos" in
        let items =
          [ D_word (-1l);
            D_half arc_tag_closure;
            D_half 0;
            D_word 16l;
            D_word 0l;
            D_ref (wrapper_name, 0L);
            D_long (Int64.of_int info.arity) ]
        in
        add_data b { name = sym; export = false; align = Some 16; items };
        sym)
  in
  let dst = fresh_temp b "pclos" in
  emit b (Binop (Add, Long, dst, Global data_sym, Int 16L));
  mark_heap b dst

and alloc_closure b code_sym arity (env : Ident.t list) : t =
  let n_env = List.length env in
  let byte_size = 16 + (8 * n_env) in
  let obj = fresh_temp b "clos" in
  emit b
    (Call
       ( Long,
         obj,
         { fn = Global "arc_alloc";
           args =
             [ (Long, Int (Int64.of_int arc_tag_closure));
               (Long, Int (Int64.of_int n_env));
               (Long, Int (Int64.of_int byte_size)) ] } ));
  emit b (Store (Storel, Global code_sym, obj));
  let arity_addr = ptr_offset b obj 8 "arityp" in
  emit b (Store (Storel, Int (Int64.of_int arity), arity_addr));
  List.iteri
    (fun i ev ->
      let v =
        match find_ocaml_value b ev with
        | Some v -> v
        | None -> (
            match function_info_opt b ev with
            | Some info when not info.has_closure -> closure_value_of b ev
            | _ ->
                failwith
                  (Printf.sprintf "codegen: unbound captured variable %s"
                     (sanitize (Ident.name ev))))
      in
      let addr = ptr_offset b obj (16 + (8 * i)) "envp" in
      emit b (Store (Storel, v, addr)))
    env;
  mark_heap b obj

let compile_function compile_aexpr b id (lf : Anf.lfunction) ~has_closure
    ~(env : Ident.t list) : string =
  let g = (function_info b id).global in
  record_function b id (g, has_closure, List.length lf.params);
  let param_binders =
    List.map
      (fun (pid, _) -> (pid, fresh_name b (sanitize (Ident.name pid))))
      lf.params
  in
  let shadowed_ids =
    (if has_closure then [ id ] else [])
    @ Anf.bound_parameters lf
    @ env
  in
  let clos_param = fresh_name b "clos" in
  let loop_binders =
    List.map (fun (pid, _) ->
      let ty =
        match List.assoc_opt pid lf.loop_scalars with
        | None -> Long
        | Some (rep, _) -> Codegen_scalar.scalar_type rep
      in
      ty, fresh_name b "loop") lf.params
    @ List.map (fun _ -> Long, fresh_name b "loop_box") lf.loop_scalars
  in
  with_fn_state b ~self:(Some id) ~entry_label:"loop"
    ~in_init:false (fun () ->
      with_shadowed_vars b shadowed_ids (fun () ->
          let ps = List.map (fun (_, n) -> (Long, n)) param_binders in
          let params = if has_closure then (Long, clos_param) :: ps else ps in
          if has_closure then begin
            bind_value b id (Temp clos_param);
            List.iteri
              (fun i ev ->
                let addr =
                  ptr_offset b (Temp clos_param) (16 + (8 * i)) "envp"
                in
                let dst = fresh_temp b "env" in
                emit b (Load (Loadl, Long, dst, addr));
                bind_value b ev dst)
              env
          end;
          let start_values =
            List.map (fun (id, formal) ->
              let boxed = Temp formal in
              match List.assoc_opt id lf.loop_scalars with
              | None -> boxed
              | Some (Anf.Double_scalar, _) -> Codegen_scalar.load_double b boxed
              | Some (Integer_scalar kind, _) -> Codegen_scalar.unbox_bint b kind boxed)
              param_binders
            @ List.map (fun (id, _) -> Temp (List.assoc id param_binders)) lf.loop_scalars
          in
          let tick =
            if lf.periodic_poll then Some (fresh_name b "poll_tick") else None
          in
          set_poll_tick b (Option.map (fun name -> Temp name) tick);
          close_block b (Jmp "loop");
          start_block b "loop";
          List.iter2
            (fun pid (_, loop_name) -> bind_value b pid (Temp loop_name))
            (Anf.bound_parameters lf) loop_binders;
          let result = compile_aexpr b true lf.body in
          close_ret b (Some result);
          (match tick with
          | None -> insert_header_phis b loop_binders start_values
          | Some name ->
              insert_header_phis b (loop_binders @ [Word, name])
                (start_values @ [Int 0L]));
          let func =
            { name = g;
              export = not has_closure && not lf.private_entry;
              retty = Some Long;
              params;
              blocks = finish_blocks b }
          in
          add_function b func));
  g

type group_member = {
  id : Ident.t;
  def : Anf.lfunction;
  captures : Ident.t list;
  tag : int64;
  entry : tail_entry;
  closure_phi : string option;
  argument_phis : string list;
}

let compile_scc_group compile_aexpr b gname ~export ~with_closure members =
  let members = List.mapi (fun i (id, (def : Anf.lfunction), captures) ->
    let entry = tail_entry (fresh_label b (sanitize (Ident.name id) ^ "_entry")) in
    let closure_phi = if with_closure then Some (fresh_name b "grp_env") else None in
    let argument_phis = List.map (fun _ -> fresh_name b "grp_arg") def.params in
    { id; def; captures; tag = Int64.of_int (i + 1); entry; closure_phi; argument_phis })
    members in
  let group_entries = List.fold_left (fun entries member ->
    Ident.Map.add member.id member.entry entries) Ident.Map.empty members in
  let max_arity = List.fold_left (fun arity member ->
    max arity (List.length member.argument_phis)) 0 members in
  let formal_clos = if with_closure then [fresh_name b "grpclos"] else [] in
  let formal_sel = fresh_name b "grpfn" in
  let formal_slots = List.init max_arity (fun _ -> fresh_name b "grpslot") in
  let long_binders = List.map (fun name -> Long, name) in
  with_fn_state ~group_entries b ~self:None ~entry_label:"start"
    ~in_init:false (fun () ->
      let params = long_binders (formal_clos @ (formal_sel :: formal_slots)) in
      let entry_args member =
        let slots, _ = split_at (List.length member.argument_phis) formal_slots in
        List.map (fun name -> Temp name) (formal_clos @ slots)
      in
      (* The selector runs on external entry. Saturated tail calls into this
         group add arguments directly to the destination member's phis. *)
      let rec dispatch_chain = function
        | [] -> close_block b Hlt
        | [member] -> jump_to_tail_entry b member.entry (entry_args member)
        | member :: rest ->
            let c = fresh_temp b "dspsel" in
            emit b (Cmp (Eq, Long, c, Temp formal_sel, Int member.tag));
            let lnext = fresh_label b "dspnext" in
            add_entry_predecessor b member.entry (entry_args member);
            close_block b (Br (c, tail_entry_label member.entry, lnext));
            start_block b lnext;
            dispatch_chain rest
      in
      dispatch_chain members;
      let ret_preds = ref [] in
      List.iter
        (fun { id; def; captures; entry; closure_phi; argument_phis; _ } ->
          start_block b (tail_entry_label entry);
          let shadowed =
            (if with_closure then id :: captures else []) @ List.map fst def.params
          in
          with_shadowed_vars b shadowed (fun () ->
              (match closure_phi with
              | Some cphi ->
                  bind_value b id (Temp cphi);
                  List.iteri
                    (fun i ev ->
                      let addr =
                        ptr_offset b (Temp cphi) (16 + (8 * i)) "envp"
                      in
                      let dst = fresh_temp b "env" in
                      emit b (Load (Loadl, Long, dst, addr));
                      bind_value b ev dst)
                    captures
              | None -> ());
              List.iter2
                (fun (pid, _) phi -> bind_value b pid (Temp phi))
                def.params argument_phis;
              let result = compile_aexpr b true def.body in
              if block_is_open b then begin
                ret_preds := (open_label b, result) :: !ret_preds;
                close_block b (Jmp "ret")
              end))
        members;
      (match !ret_preds with
      | [] ->
          start_block b "ret";
          close_block b Hlt
      | _ ->
          start_block b "ret";
          let res = fresh_temp b "grpres" in
          emit b (Phi (Long, res, List.rev !ret_preds));
          close_block b (Ret (Some res)));
      List.iter (fun member ->
        let names = Option.to_list member.closure_phi @ member.argument_phis in
        insert_entry_phis b member.entry (long_binders names)) members;
      let func =
        { name = gname;
          export;
          retty = Some Long;
          params;
          blocks = finish_blocks b }
      in
      add_function b func)

let compile_group compile_aexpr b gname (members : (Ident.t * Anf.lfunction) list)
    : unit =
  let members_with_env = List.map (fun (id, lf) -> (id, lf, [])) members in
  let export = List.exists (fun (_, lf) -> not lf.Anf.private_entry) members in
  compile_scc_group compile_aexpr b gname ~export ~with_closure:false
    members_with_env

let define_pure_function compile_aexpr b id (lf : Anf.lfunction)
    (info : fn_info) : unit =
  match info.group_name with
  | Some gname ->
      with_uncompiled_group b gname (compile_group compile_aexpr b gname)
  | None ->
      (* An owning function and its borrowed worker can share a nested
         static binding. Its original identity selects a single symbol. *)
      if Option.is_none (emitted_function b id) then
        ignore (compile_function compile_aexpr b id lf ~has_closure:false ~env:[])

let compile_fun_binding compile_aexpr b tail id (lf : Anf.lfunction) body =
  match function_info_opt b id with
  | Some info when not info.has_closure ->
      define_pure_function compile_aexpr b id lf info;
      compile_aexpr b tail body
  | _ ->
      let env = Codegen_analysis.free_vars_of b lf in
      let g = alloc_global_name b id in
      let has_closure = env <> [] in
      declare_function b id
        { global = g;
          arity = List.length lf.params;
          tag = None;
          group_arity = List.length lf.params;
          group_name = None;
          has_closure };
      ignore (compile_function compile_aexpr b id lf ~has_closure ~env);
      if has_closure then begin
        let clos = alloc_closure b g (List.length lf.params) env in
        bind_value b id clos;
        let res = compile_aexpr b tail body in
        forget_value b id;
        forget_function b id;
        res
      end
      else begin
        let res = compile_aexpr b tail body in
        forget_function b id;
        res
      end

let compile_letrec compile_aexpr b tail (bindings : Anf.rec_binding list) body =
  match bindings with
  | [] -> compile_aexpr b tail body
  | rb :: _
    when
      match function_info_opt b rb.id with
      | Some info -> not info.has_closure
      | None -> false ->
      List.iter
        (fun (rb : Anf.rec_binding) ->
          let info = function_info b rb.id in
          define_pure_function compile_aexpr b rb.id rb.def info)
        bindings;
      compile_aexpr b tail body
  | [ rb ] ->
      let env = Codegen_analysis.free_vars_of b ~self_id:rb.id rb.def in
      let g = alloc_global_name b rb.id in
      let has_closure = env <> [] in
      declare_function b rb.id
        { global = g;
          arity = List.length rb.def.params;
          tag = None;
          group_arity = List.length rb.def.params;
          group_name = None;
          has_closure };
      ignore (compile_function compile_aexpr b rb.id rb.def ~has_closure ~env);
      if has_closure then begin
        let clos = alloc_closure b g (List.length rb.def.params) env in
        bind_value b rb.id clos;
        let res = compile_aexpr b tail body in
        forget_value b rb.id;
        forget_function b rb.id;
        res
      end
      else begin
        let res = compile_aexpr b tail body in
        forget_function b rb.id;
        res
      end
  | _ ->
      let infos =
        List.map
          (fun (rb : Anf.rec_binding) ->
            let g = alloc_global_name b rb.id in
            let arity = List.length rb.def.params in
            declare_function b rb.id
              { global = g;
                arity;
                tag = None;
                group_arity = arity;
                group_name = None;
                has_closure = true };
            let env = Codegen_analysis.free_vars_of b ~self_id:rb.id rb.def in
            let obj = fresh_temp b "clos" in
            let n_env = List.length env in
            emit b
              (Call
                 ( Long,
                   obj,
                   { fn = Global "arc_alloc";
                     args =
                       [ (Long, Int (Int64.of_int arc_tag_closure));
                         (Long, Int (Int64.of_int n_env));
                         (Long, Int (Int64.of_int (16 + (8 * n_env)))) ] } ));
            emit b (Store (Storel, Global g, obj));
            let arity_addr = ptr_offset b obj 8 "arityp" in
            emit b (Store (Storel, Int (Int64.of_int arity), arity_addr));
            bind_value b rb.id (mark_heap b obj);
            (rb, g, env, obj))
          bindings
      in
      let cyclic_ids =
        let ids =
          List.map (fun ((rb : Anf.rec_binding), _, _, _) -> rb.id) infos
        in
        let edges_of id =
          match
            List.find_opt
              (fun ((rb : Anf.rec_binding), _, _, _) -> Ident.same rb.id id)
              infos
          with
          | Some (_, _, env, _) ->
              List.filter (fun ev -> List.exists (Ident.same ev) ids) env
          | None -> []
        in
        let can_reach src dst =
          let rec dfs visited = function
            | [] -> false
            | x :: rest ->
                if Ident.same x dst then true
                else if List.exists (Ident.same x) visited then dfs visited rest
                else dfs (x :: visited) (edges_of x @ rest)
          in
          dfs [] (edges_of src)
        in
        List.filter (fun id -> can_reach id id) ids
      in
      if cyclic_ids <> [] then
        Printf.eprintf
          "ocamlcc: warning: cyclic non-pure mutual let rec closures (%s) form an \
           ARC reference cycle; lift to top-level or call arc_collect ()\n%!"
          (String.concat ", " (List.map Ident.name cyclic_ids));
      List.iter
        (fun (_, _, env, obj) ->
          List.iteri
            (fun i ev ->
              let v = Option.get (find_ocaml_value b ev) in
              if
                List.exists
                  (fun (rb : Anf.rec_binding) -> Ident.same rb.id ev)
                  bindings
              then
                emit b
                  (Call_void
                     { fn = Global "arc_retain_val"; args = [ (Long, v) ] });
              let addr = ptr_offset b obj (16 + (8 * i)) "envp" in
              emit b (Store (Storel, v, addr)))
            env)
        infos;
      let arities =
        List.map
          (fun ((rb : Anf.rec_binding), _, _, _) ->
            (rb.id, List.length rb.def.params))
          infos
      in
      let find_info id =
        match
          List.find_opt
            (fun ((rb : Anf.rec_binding), _, _, _) -> Ident.same rb.id id)
            infos
        with
        | Some x -> x
        | None -> assert false
      in
      let binding_ids =
        List.map (fun ((rb : Anf.rec_binding), _, _, _) -> rb.id) infos
      in
      let callee_edges id =
        let rb, _, _, _ = find_info id in
        Codegen_analysis.tail_callees ~arities rb.def.body
        |> Ident.Set.filter (fun callee ->
               not (Ident.same callee id)
               && List.exists (Ident.same callee) binding_ids)
      in
      let sccs =
        Codegen_analysis.strongly_connected_components binding_ids callee_edges
      in
      let group_comp_info =
        List.filter_map
          (fun comp ->
            if List.length comp < 2 then None
            else
              let gname = fresh_group_name b in
              let comp_infos = List.map find_info comp in
              let group_arity =
                List.fold_left
                  (fun acc ((rb : Anf.rec_binding), _, _, _) ->
                    max acc (List.length rb.def.params))
                  0 comp_infos
              in
              List.iteri
                (fun i ((rb : Anf.rec_binding), wrapper_g, _, _) ->
                  let info = function_info b rb.id in
                  let tag = Int64.of_int (i + 1) in
                  declare_function b rb.id
                    { info with
                      global = gname;
                      tag = Some tag;
                      group_arity;
                      group_name = Some gname };
                  emit_group_wrapper b ~wrapper_name:wrapper_g ~pass_clos:true
                    ~target_global:gname ~arity:info.arity ~tag_opt:(Some tag)
                    ~group_arity)
                comp_infos;
              Some (gname, comp_infos))
          sccs
      in
      List.iter
        (fun comp ->
          match comp with
          | [ id ] ->
              let rb, _, env, _ = find_info id in
              ignore
                (compile_function compile_aexpr b rb.id rb.def ~has_closure:true
                   ~env)
          | _ -> ())
        sccs;
      List.iter
        (fun (gname, comp_infos) ->
          let members =
            List.map
              (fun ((rb : Anf.rec_binding), _, env, _) -> (rb.id, rb.def, env))
              comp_infos
          in
          compile_scc_group compile_aexpr b gname ~export:false
            ~with_closure:true members)
        group_comp_info;
      let res = compile_aexpr b tail body in
      List.iter
        (fun ((rb : Anf.rec_binding), _, _, _) ->
          forget_value b rb.id;
          forget_function b rb.id)
        infos;
      res

let hooks : Codegen_expr.fn_hooks =
  { closure_value = closure_value_of;
    compile_fun_binding;
    compile_letrec }
