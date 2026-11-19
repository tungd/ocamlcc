(* ANF -> QBE IL program compiler. *)

open Codegen_ctx
open Qbe_il

let entry_point modules =
  let call_init name =
    Call_void { fn = Global ("ocamlcc_init_" ^ sanitize name); args = [] }
  in
  { name = "ocamlcc_module_init"; export = true; retty = None; params = [];
    blocks = [{ label = "start"; insts = List.map call_init modules; term = Ret None }] }

let compile_program ?(emit_entry = true) (program : Anf.program) :
    Qbe_il.module_ =
  let mod_sym = sanitize (Ident.name program.Anf.module_ident) in
  let b = create mod_sym in
  let defs = Codegen_analysis.collect_pure_defs program.code in
  List.iter
    (fun ((id, lf) : Ident.t * Anf.lfunction) ->
      Hashtbl.replace b.funs id
        { global = alloc_global_name b id;
          arity = List.length lf.params;
          tag = None;
          group_arity = List.length lf.params;
          group_name = None;
          has_closure = false })
    defs;
  let def_idents = List.map fst defs in
  let callee_edges (id : Ident.t) : Ident.Set.t =
    match List.assoc_opt id defs with
    | None -> Ident.Set.empty
    | Some lf -> Codegen_analysis.tail_callees lf.body
    |> Ident.Set.filter (fun callee ->
           not (Ident.same callee id)
           && List.exists (fun (id', _) -> Ident.same id' callee) defs)
  in
  let sccs =
    Codegen_analysis.strongly_connected_components def_idents callee_edges
  in
  List.iter
    (fun comp ->
      if List.length comp >= 2 then begin
        let gname =
          Printf.sprintf "ocamlcc_%s_group%d" b.prefix b.group_counter
        in
        b.group_counter <- b.group_counter + 1;
        let members =
          List.map
            (fun id ->
              match List.assoc_opt id defs with
              | Some lf -> (id, lf)
              | None -> assert false)
            comp
        in
        Hashtbl.replace b.groups gname members;
        let group_arity =
          List.fold_left
            (fun acc ((_, lf) : Ident.t * Anf.lfunction) ->
              max acc (List.length lf.params))
            0 members
        in
        List.iteri
          (fun i (id, _) ->
            let info = Hashtbl.find b.funs id in
            Hashtbl.replace b.funs id
              { info with
                global = gname;
                tag = Some (Int64.of_int (i + 1));
                group_arity;
                group_name = Some gname })
          members
      end)
    sccs;
  let global_sym = "ocamlcc_global_" ^ mod_sym in
  let init_sym = "ocamlcc_init_" ^ mod_sym in
  let deps = Codegen_analysis.collect_globals mod_sym program.code in
  b.datas <-
    { name = global_sym;
      export = true;
      align = Some 8;
      items = [ D_long 0L ] }
    :: b.datas;
  start_block b "start";
  let should_init = fresh_temp b "doinit" in
  emit b
    (Call
       ( Long,
         should_init,
         { fn = Global "ocamlcc_init_try_enter";
           args = [ (Long, Global global_sym) ] } ));
  let ldone = fresh_label b "already_init" in
  let linit = fresh_label b "do_init" in
  close_block b (Br (should_init, linit, ldone));
  start_block b ldone;
  close_ret b None;
  start_block b linit;
  List.iter
    (fun dep ->
      emit b
        (Call_void { fn = Global ("ocamlcc_init_" ^ dep); args = [] });
      let ex = fresh_temp b "depex" in
      emit b (Call (Long, ex, { fn = Global "ocamlcc_get_exn"; args = [] }));
      let has_ex = fresh_temp b "dephasex" in
      emit b (Cmp (Ne, Long, has_ex, ex, Int 0L));
      let ldep_err = fresh_label b "dep_err" in
      let ldep_ok = fresh_label b "dep_ok" in
      close_block b (Br (has_ex, ldep_err, ldep_ok));
      start_block b ldep_err;
      emit b
        (Call_void
           { fn = Global "ocamlcc_init_finish";
             args = [ (Long, Global global_sym); (Long, Int 0L) ] });
      close_ret b None;
      start_block b ldep_ok)
    deps;
  let mod_val = Codegen_expr.compile_aexpr Codegen_fn.hooks b false program.code in
  if b.cur_fn.term = None then begin
    emit b
      (Call_void
         { fn = Global "ocamlcc_init_finish";
           args = [ (Long, Global global_sym); (Long, mod_val) ] });
    close_ret b None
  end;
  let init_func =
    { name = init_sym;
      export = true;
      retty = None;
      params = [];
      blocks = finish_blocks b }
  in
  let funcs =
    if emit_entry then
      List.rev (entry_point [mod_sym] :: init_func :: b.funcs)
    else List.rev (init_func :: b.funcs)
  in
  { funcs; datas = List.rev b.datas }
