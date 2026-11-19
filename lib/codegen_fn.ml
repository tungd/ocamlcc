(* Codegen function, trampoline group, and closure emission. *)

open Codegen_ctx
open Qbe_il

let insert_header_phis b header_label binder_names start_values =
  if binder_names <> [] then begin
    let sites = List.rev b.cur_fn.tail_sites in
    let phis =
      List.mapi
        (fun i name ->
          let args =
            ("start", List.nth start_values i)
            :: List.filter_map
                 (fun (lbl, vs) ->
                   match List.nth_opt vs i with
                   | Some v -> Some (lbl, v)
                   | None -> None)
                 sites
          in
          Phi (Long, Temp name, args))
        binder_names
    in
    b.cur_fn.blocks <-
      List.map
        (fun blk ->
          if blk.label = header_label then { blk with insts = phis @ blk.insts }
          else blk)
        b.cur_fn.blocks
  end

let rec closure_value_of b id : t =
  let data_sym =
    match Hashtbl.find_opt b.clos_wrappers id with
    | Some sym -> sym
    | None ->
        let info = Hashtbl.find b.funs id in
        let wrapper_name = alloc_global_name b id in
        let clos_p = fresh_name b "clos" in
        let param_names = List.init info.arity (fun _ -> fresh_name b "carg") in
        let param_vals = List.map (fun n -> (Long, Temp n)) param_names in
        let call_res = fresh_name b "wres" in
        let call_inst =
          match info.tag with
          | Some tag ->
              let padded = pad_to info.group_arity (List.map snd param_vals) in
              Call
                ( Long,
                  Temp call_res,
                  { fn = Global info.global;
                    args =
                      (Long, Int tag) :: List.map (fun v -> (Long, v)) padded } )
          | None ->
              Call
                ( Long,
                  Temp call_res,
                  { fn = Global info.global; args = param_vals } )
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
        b.funcs <- func :: b.funcs;
        let sym = Printf.sprintf "clos.%d" b.data_counter in
        b.data_counter <- b.data_counter + 1;
        let items =
          [ D_word (-1l);
            D_half arc_tag_closure;
            D_half 0;
            D_word 16l;
            D_word 0l;
            D_ref (wrapper_name, 0L);
            D_long (Int64.of_int info.arity) ]
        in
        b.datas <-
          { name = sym; export = false; align = Some 16; items } :: b.datas;
        Hashtbl.replace b.clos_wrappers id sym;
        sym
  in
  let dst = fresh_temp b "pclos" in
  emit b (Binop (Add, Long, dst, Global data_sym, Int 16L));
  dst

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
        match Hashtbl.find_opt b.vars ev with
        | Some v -> v
        | None -> (
            match Hashtbl.find_opt b.funs ev with
            | Some info when not info.has_closure -> closure_value_of b ev
            | _ ->
                failwith
                  (Printf.sprintf "codegen: unbound captured variable %s"
                     (sanitize (Ident.name ev))))
      in
      let addr = ptr_offset b obj (16 + (8 * i)) "envp" in
      emit b (Store (Storel, v, addr)))
    env;
  obj

let compile_function compile_aexpr b id (lf : Anf.lfunction) ~has_closure
    ~(env : Ident.t list) : string =
  let g = (Hashtbl.find b.funs id).global in
  let param_binders =
    List.map
      (fun (pid, _) -> (pid, fresh_name b (sanitize (Ident.name pid))))
      lf.params
  in
  let shadowed_ids =
    (if has_closure then [ id ] else [])
    @ List.map fst param_binders
    @ env
  in
  let clos_param = fresh_name b "clos" in
  let loop_binders = List.map (fun _ -> fresh_name b "loop") lf.params in
  with_fn_state b ~self:(Some id) ~cur_group:None ~entry_label:"loop"
    ~in_init:false (fun () ->
      with_shadowed_vars b shadowed_ids (fun () ->
          let ps = List.map (fun (_, n) -> (Long, n)) param_binders in
          b.cur_fn.fn_params <-
            if has_closure then (Long, clos_param) :: ps else ps;
          if has_closure then begin
            Hashtbl.replace b.vars id (Temp clos_param);
            List.iteri
              (fun i ev ->
                let addr =
                  ptr_offset b (Temp clos_param) (16 + (8 * i)) "envp"
                in
                let dst = fresh_temp b "env" in
                emit b (Load (Loadl, Long, dst, addr));
                Hashtbl.replace b.vars ev dst)
              env
          end;
          close_block b (Jmp "loop");
          start_block b "loop";
          List.iter2
            (fun (pid, _) loop_name ->
              Hashtbl.replace b.vars pid (Temp loop_name))
            param_binders loop_binders;
          let result = compile_aexpr b true lf.body in
          close_ret b (Some result);
          insert_header_phis b "loop" loop_binders
            (List.map (fun (_, formal) -> Temp formal) param_binders);
          let func =
            { name = g;
              export = not has_closure;
              retty = Some Long;
              params = b.cur_fn.fn_params;
              blocks = finish_blocks b }
          in
          b.funcs <- func :: b.funcs));
  g

let compile_group compile_aexpr b gname (members : (Ident.t * Anf.lfunction) list)
    : unit =
  let max_arity =
    List.fold_left
      (fun acc ((_, lf) : Ident.t * Anf.lfunction) ->
        max acc (List.length lf.params))
      0 members
  in
  let formal_sel = fresh_name b "grpfn" in
  let formal_slots = List.init max_arity (fun _ -> fresh_name b "grpslot") in
  let phi_sel = fresh_name b "dspsel" in
  let phi_slots = List.init max_arity (fun _ -> fresh_name b "dspslot") in
  with_fn_state b ~self:None ~cur_group:(Some gname) ~entry_label:"dispatch"
    ~in_init:false (fun () ->
      b.cur_fn.fn_params <-
        (Long, formal_sel) :: List.map (fun n -> (Long, n)) formal_slots;
      close_block b (Jmp "dispatch");
      start_block b "dispatch";
      let member_entries =
        List.mapi
          (fun i (id, _) ->
            ( Int64.of_int (i + 1),
              Printf.sprintf "%s_entry" (sanitize (Ident.name id)) ))
          members
      in
      let rec dispatch_chain = function
        | [] -> close_block b Hlt
        | [ (_, entry) ] -> close_block b (Jmp entry)
        | (tag, entry) :: rest ->
            let c = fresh_temp b "dspsel" in
            emit b (Cmp (Eq, Long, c, Temp phi_sel, Int tag));
            let lnext = fresh_label b "dspnext" in
            close_block b (Br (c, entry, lnext));
            start_block b lnext;
            dispatch_chain rest
      in
      dispatch_chain member_entries;
      let ret_preds = ref [] in
      List.iter2
        (fun (_, entry) ((_, lf) : Ident.t * Anf.lfunction) ->
          start_block b entry;
          List.iteri
            (fun j (pid, _) ->
              Hashtbl.replace b.vars pid (Temp (List.nth phi_slots j)))
            lf.params;
          let result = compile_aexpr b true lf.body in
          if b.cur_fn.term = None then begin
            ret_preds := (b.cur_fn.open_label, result) :: !ret_preds;
            close_block b (Jmp "ret")
          end;
          List.iter (fun (pid, _) -> Hashtbl.remove b.vars pid) lf.params)
        member_entries members;
      (match !ret_preds with
      | [] ->
          start_block b "ret";
          close_block b Hlt
      | _ ->
          start_block b "ret";
          let res = fresh_temp b "grpres" in
          emit b (Phi (Long, res, List.rev !ret_preds));
          close_block b (Ret (Some res)));
      insert_header_phis b "dispatch" (phi_sel :: phi_slots)
        (Temp formal_sel :: List.map (fun n -> Temp n) formal_slots);
      let func =
        { name = gname;
          export = true;
          retty = Some Long;
          params = b.cur_fn.fn_params;
          blocks = finish_blocks b }
      in
      b.funcs <- func :: b.funcs)

let define_pure_function compile_aexpr b id (lf : Anf.lfunction)
    (info : fn_info) : unit =
  match info.group_name with
  | Some gname ->
      if not (Hashtbl.mem b.compiled_groups gname) then begin
        Hashtbl.replace b.compiled_groups gname ();
        compile_group compile_aexpr b gname (Hashtbl.find b.groups gname)
      end
  | None -> ignore (compile_function compile_aexpr b id lf ~has_closure:false ~env:[])

let compile_fun_binding compile_aexpr b tail id (lf : Anf.lfunction) body =
  match Hashtbl.find_opt b.funs id with
  | Some info when not info.has_closure ->
      define_pure_function compile_aexpr b id lf info;
      compile_aexpr b tail body
  | _ ->
      let env = Codegen_analysis.free_vars_of b lf in
      let g = alloc_global_name b id in
      let has_closure = env <> [] in
      Hashtbl.replace b.funs id
        { global = g;
          arity = List.length lf.params;
          tag = None;
          group_arity = List.length lf.params;
          group_name = None;
          has_closure };
      ignore (compile_function compile_aexpr b id lf ~has_closure ~env);
      if has_closure then begin
        let clos = alloc_closure b g (List.length lf.params) env in
        Hashtbl.replace b.vars id clos;
        let res = compile_aexpr b tail body in
        Hashtbl.remove b.vars id;
        Hashtbl.remove b.funs id;
        res
      end
      else begin
        let res = compile_aexpr b tail body in
        Hashtbl.remove b.funs id;
        res
      end

let compile_letrec compile_aexpr b tail (bindings : Anf.rec_binding list) body =
  match bindings with
  | [] -> compile_aexpr b tail body
  | rb :: _
    when
      match Hashtbl.find_opt b.funs rb.id with
      | Some info -> not info.has_closure
      | None -> false ->
      List.iter
        (fun (rb : Anf.rec_binding) ->
          let info = Hashtbl.find b.funs rb.id in
          define_pure_function compile_aexpr b rb.id rb.def info)
        bindings;
      compile_aexpr b tail body
  | [ rb ] ->
      let env = Codegen_analysis.free_vars_of b ~self_id:rb.id rb.def in
      let g = alloc_global_name b rb.id in
      let has_closure = env <> [] in
      Hashtbl.replace b.funs rb.id
        { global = g;
          arity = List.length rb.def.params;
          tag = None;
          group_arity = List.length rb.def.params;
          group_name = None;
          has_closure };
      ignore (compile_function compile_aexpr b rb.id rb.def ~has_closure ~env);
      if has_closure then begin
        let clos = alloc_closure b g (List.length rb.def.params) env in
        Hashtbl.replace b.vars rb.id clos;
        let res = compile_aexpr b tail body in
        Hashtbl.remove b.vars rb.id;
        Hashtbl.remove b.funs rb.id;
        res
      end
      else begin
        let res = compile_aexpr b tail body in
        Hashtbl.remove b.funs rb.id;
        res
      end
  | _ ->
      let infos =
        List.map
          (fun (rb : Anf.rec_binding) ->
            let g = alloc_global_name b rb.id in
            let arity = List.length rb.def.params in
            Hashtbl.replace b.funs rb.id
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
            Hashtbl.replace b.vars rb.id obj;
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
              let v = Hashtbl.find b.vars ev in
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
      List.iter
        (fun ((rb : Anf.rec_binding), _, env, _) ->
          ignore
            (compile_function compile_aexpr b rb.id rb.def ~has_closure:true ~env))
        infos;
      let res = compile_aexpr b tail body in
      List.iter
        (fun ((rb : Anf.rec_binding), _, _, _) ->
          Hashtbl.remove b.vars rb.id;
          Hashtbl.remove b.funs rb.id)
        infos;
      res

let hooks : Codegen_expr.fn_hooks =
  { closure_value = closure_value_of;
    compile_fun_binding;
    compile_letrec }
