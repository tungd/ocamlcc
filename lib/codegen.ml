(* ANF -> QBE IL program compiler. *)

open Codegen_ctx
open Qbe_il

let entry_point modules =
  let call_init name =
    Call_void { fn = Global ("ocamlcc_init_" ^ sanitize name); args = [] }
  in
  { name = "ocamlcc_module_init"; export = true; retty = None; params = [];
    blocks = [{ label = "start"; insts = List.map call_init modules; term = Ret None }] }

let load_pointer b addr =
  let dst = fresh_temp b "capture" in
  emit b (Load (Loadl, Long, dst, addr));
  dst

(* Cache a borrowed closure pointer during initialization. The published
   module remains its owner. The entry invokes the known body with the
   cached environment and the ordinary owned arguments. *)
let export_captured b mod_value path target arity =
  let name =
    "ocamlcc_direct_" ^ b.prefix ^ "_"
    ^ String.concat "_" (List.map string_of_int path)
  in
  let slot = name ^ "_env" in
  b.datas <- { name = slot; export = false; align = Some 8;
               items = [D_long 0L] } :: b.datas;
  let clos =
    List.fold_left (fun owner index ->
      load_pointer b (ptr_offset b owner (8 * index) "slot")) mod_value path
  in
  emit b (Store (Storel, clos, Global slot));
  with_fn_state b ~self:None ~cur_group:None ~entry_label:"start" ~in_init:false
    (fun () ->
      start_block b "start";
      let clos = load_pointer b (Global slot) in
      let params = List.init arity (fun _ -> Long, fresh_name b "arg") in
      let args = (Long, clos) :: List.map (fun (ty, name) -> ty, Temp name) params in
      let res = fresh_temp b "res" in
      emit b (Call (Long, res, { fn = Global target; args }));
      close_ret b (Some res);
      b.funcs <- { name; export = true; retty = Some Long; params;
                   blocks = finish_blocks b } :: b.funcs);
  name

let compile_with_exports ?(emit_entry = true) ?(inline_single_thread_rc = false) ~exported ~effects ~inline_leaf
    (program : Anf.program) =
  let mod_sym = sanitize (Ident.name program.Anf.module_ident) in
  let b = create ~inline_single_thread_rc mod_sym in
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
  let unit_name = Ident.name program.module_ident in
  let exports = List.filter_map (fun (path, id) ->
    match Hashtbl.find_opt b.emitted_funs id with
    | None -> None
    | Some (_, true, _) when b.cur_fn.term <> None -> None
    | Some (target, has_closure, arity) ->
        let symbol =
          if has_closure then export_captured b mod_val path target arity else target
        in
        let yields, returns_immediate = effects id in
        let inline_leaf = inline_leaf id in
        Some (path, { Anf.unit_name; symbol; arity; yields; returns_immediate; inline_leaf }))
    exported
  in
  if b.cur_fn.term = None then begin
    emit b
      (Call_void
         { fn = Global "ocamlcc_init_finish";
           args = [ (Long, Global global_sym); (Long, mod_val) ] });
    close_ret b None
  end;
  let init_body =
    { name = "ocamlcc_init_body_" ^ mod_sym;
      export = false;
      retty = None;
      params = [];
      blocks = finish_blocks b }
  in
  (* A host can call an exported unit initializer directly. All OCaml
     application inside the initializer has an active mutator boundary. *)
  let mutator_enter =
    if inline_single_thread_rc then "ocamlcc_arc_enter_single_thread"
    else "arc_mutator_enter"
  in
  let init_func =
    { name = init_sym; export = true; retty = None; params = [];
      blocks = [{ label = "start";
        insts = [
          Call (Word, Temp "entered", { fn = Global mutator_enter; args = [] });
          Call_void { fn = Global init_body.name; args = [] };
          Call_void { fn = Global "arc_mutator_leave"; args = [ (Word, Temp "entered") ] } ];
        term = Ret None }] }
  in
  let funcs =
    if emit_entry then
      List.rev (entry_point [mod_sym] :: init_func :: init_body :: b.funcs)
    else List.rev (init_func :: init_body :: b.funcs)
  in
  { funcs; datas = List.rev b.datas }, exports

let compile_program ?emit_entry program =
  fst (compile_with_exports ?emit_entry ~exported:[] ~effects:(fun _ -> true, false)
         ~inline_leaf:(fun _ -> None) program)
