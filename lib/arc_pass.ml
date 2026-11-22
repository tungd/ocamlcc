(* Perceus ARC dup / drop / reuse + zero-leak exception middle-end pass.

   Ownership contract:
   - Every [Let]-bound variable and ordinary function parameter starts owned.
     A private borrowed entry leaves ownership of its read-only arguments
     with the caller.
   - Pure global functions ([has_closure = false]), tagged immediates
     ([int], [char], [unit]), and static string/const blocks never require
     retain or release.
   - Closure captured variables ([env]), closure self-references, and
     variables borrowed across [LetJoin] / [While] / [For] use BORROWED reads
     with 0 refcount overhead, retaining only on escape/transfer.
     [frame_borrowed] distinguishes same-frame borrows ([LetJoin]/[While]/[For])
     so exceptional unwinding drops them while never dropping caller captures.
   - Pointer-capable field/array loads retain in codegen unless an immutable
     projection is fused into a non-escaping read; overwrites release old slots.
   - [TryWith] / [Raise] / [CheckExn] / [Unwind] ensure every local owned
     value, [MutLet] slot, and open reuse token unwinds with zero leaks.
   - A [MutLet] slot is released exactly once, where it leaves scope: the
     function-exit [Halt], a [Raise] path, or a [StaticRaise] to a narrower
     handler. [Halt]s that flow into a [LetJoin] rhs / [While] / [For]
     continuation are not scope exits; [Scope.no_release_muts] defers those
     slots to the continuation that still owns them. *)

open Arc_analysis

module IntSet = Set.Make (Int)

type borrowed_entry = {
  worker : Ident.t;
  borrow : bool list;
}

module Scope = struct
  type t = {
    owned : Ident.Set.t;
    borrowed : Ident.Set.t;
    frame_borrowed : Ident.Set.t;
    view_owners : Ident.Set.t Ident.Map.t;
    slot_snapshots : Ident.t Ident.Map.t;
    imm : Ident.Set.t;
    muts : Ident.Set.t;
    (* These slots are still owned by the continuation after a join or loop. *)
    no_release_muts : Ident.Set.t;
  }

  let empty =
    { owned = Ident.Set.empty; borrowed = Ident.Set.empty;
      frame_borrowed = Ident.Set.empty; view_owners = Ident.Map.empty;
      slot_snapshots = Ident.Map.empty; imm = Ident.Set.empty;
      muts = Ident.Set.empty; no_release_muts = Ident.Set.empty }
end

module Exn_frame = struct
  module Labels = Map.Make (Int)

  module Handler = struct
    type t = {
      owned : Ident.Set.t;
      live : Ident.Set.t;
      muts : Ident.Set.t;
    }
  end

  type t = {
    handlers : Handler.t Labels.t;
    try_owned : Ident.Set.t;
    try_muts : Ident.Set.t;
    try_depth : int;
    (* [Halt] at a join or loop exit still needs checks for its continuation. *)
    in_tail : bool;
  }

  let root =
    { handlers = Labels.empty; try_owned = Ident.Set.empty;
      try_muts = Ident.Set.empty; try_depth = 0; in_tail = true }

  let handler label frame = Labels.find_opt label frame.handlers

  let with_handler label target frame =
    { frame with handlers = Labels.add label target frame.handlers }

  let non_tail frame = { frame with in_tail = false }

  let protect ~owned ~muts frame =
    { frame with try_owned = owned; try_muts = muts;
                 try_depth = frame.try_depth + 1; in_tail = false }
end

type state = {
  facts : Program_facts.t;
  scope : Scope.t;
  exn : Exn_frame.t;
  borrowed_entries : borrowed_entry Ident.Map.t;
  exported_workers : (Ident.t, borrowed_entry) Hashtbl.t;
}

let is_borrowed (env : state) (id : Ident.t) : bool =
  Ident.Set.mem id env.scope.borrowed || Ident.Set.mem id env.scope.frame_borrowed
  || Ident.Map.mem id env.scope.view_owners

(* The false edge of ANF's conditional tests for the tagged zero, even
   when the scrutinee may be a constructor block on the other edge. *)
let false_edge env = function
  | Anf.Var id -> { env with scope = { env.scope with imm = Ident.Set.add id env.scope.imm } }
  | _ -> env

let is_imm_atom env = atom_is_imm ~pure:env.facts.pure env.scope.imm

let is_imm_cexpr env = cexpr_is_imm ~pure:env.facts.pure ~imm_funs:env.facts.imm_funs env.scope.imm

let handler_immediates env =
  Arc_analysis.handler_immediates ~typed_imm:env.facts.typed_imm ~pure:env.facts.pure
    ~imm_funs:env.facts.imm_funs env.scope.imm

let mutlet_is_imm env =
  Arc_analysis.mutlet_is_imm ~typed_imm:env.facts.typed_imm ~pure:env.facts.pure
    ~imm_funs:env.facts.imm_funs env.scope.imm

let specialize_ownership env = function
  | Anf.MakeBlock (tag, Scan_if_managed, args) when List.for_all (is_imm_atom env) args ->
      Anf.MakeBlock (tag, Scan_none, args)
  | Anf.Assign (slot, rhs) when Ident.Set.mem slot env.scope.imm -> Anf.AssignImm (slot, rhs)
  | ce -> ce

let borrowed_flags env id =
  Option.map (fun entry -> entry.borrow) (Ident.Map.find_opt id env.borrowed_entries)

let add_borrowed_entry env id borrow =
  let worker = Ident.create_local (Ident.name id ^ "_borrowed") in
  let entry = { worker; borrow } in
  if Ident.Set.mem id env.facts.exported then Hashtbl.replace env.exported_workers id entry;
  let facts = Program_facts.with_worker ~original:id ~worker ~arity:(List.length borrow) env.facts in
  worker,
  { env with facts; borrowed_entries = Ident.Map.add id entry env.borrowed_entries }

let can_borrow_arguments env =
  Arc_views.can_borrow_arguments ~is_immediate:(is_imm_atom env)
    ~is_borrowed:(is_borrowed env)

let borrowed_call env live = function
  | Anf.App (Var fn, args) -> (
      match Ident.Map.find_opt fn env.borrowed_entries with
      | Some entry when can_borrow_arguments env live entry.borrow args ->
          Some (entry.worker, List.combine entry.borrow args)
      | _ -> None)
  | _ -> None

let select_imported_entry env live = function
  | Anf.DirectApp (({ borrowed_entry = Some (_, flags); _ } as target), args)
    when not (can_borrow_arguments env live flags args) ->
      Anf.DirectApp ({ target with borrowed_entry = None }, args)
  | ce -> ce

let rec restore_borrowed pairs consumed =
  match pairs, consumed with
  | [], [] -> []
  | (true, a) :: rest, _ -> a :: restore_borrowed rest consumed
  | (false, _) :: rest, a :: remaining -> a :: restore_borrowed rest remaining
  | _ -> assert false

let is_yielding_ce env = call_can_suspend env.facts.known_funs env.facts.yielding

let ce_may_raise env =
  operation_can_raise ~finalizers:true env.facts.known_funs env.facts.raising

let exception_check env ce =
  (* Dispatch itself already sits behind the due check. The sticky guard
     saves a TLS read at callers of functions whose only exception source
     is an automatic poll, including one that drained the registry. *)
  match ce with
  | Anf.PollFinalizers | Ccall ("ocamlcc_poll_finalizers", []) -> Anf.May_raise
  | _ when operation_can_raise ~finalizers:false env.facts.known_funs env.facts.ordinary_raising ce ->
      May_raise
  | _ -> Finalizer_raise
let can_raise env = can_raise_with (ce_may_raise env)

let rec reachable_raises (e : Anf.aexpr) : IntSet.t =
  match e with
  | Halt _ | HaltScalar _ | Unwind | Raise _ -> IntSet.empty
  | StaticRaise (id, _) -> IntSet.singleton id
  | While (a, b) -> IntSet.union (reachable_raises a) (reachable_raises b)
  | For (_, _, _, _, body) -> reachable_raises body
  | Let (_, _, body) | MutLet (_, _, body) | LetRec (_, body)
  | Retain (_, body) | Release (_, body) | ReleaseMut (_, body)
  | DropReuse (_, _, body) | FreeReuse (_, body)
  | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
      reachable_raises body
  | LetJoin (_, rhs, body) | CheckExn (_, rhs, body) | TryWith (rhs, _, body) ->
      IntSet.union (reachable_raises rhs) (reachable_raises body)
  | If (_, th, el) | ScalarIf (_, _, th, el) ->
      IntSet.union (reachable_raises th) (reachable_raises el)
  | Switch (_, sw) ->
      let acc =
        List.fold_left
          (fun acc (_, arm) -> IntSet.union acc (reachable_raises arm))
          IntSet.empty sw.consts
      in
      let acc =
        List.fold_left
          (fun acc (_, arm) -> IntSet.union acc (reachable_raises arm))
          acc sw.blocks
      in
      (match sw.fail with
      | Some f -> IntSet.union acc (reachable_raises f)
      | None -> acc)
  | StringSwitch (_, cases, fail) ->
      let acc =
        List.fold_left
          (fun acc (_, arm) -> IntSet.union acc (reachable_raises arm))
          IntSet.empty cases
      in
      (match fail with
      | Some f -> IntSet.union acc (reachable_raises f)
      | None -> acc)
  | StaticCatch (body, id, _, handler, _) ->
      let rb = IntSet.remove id (reachable_raises body) in
      IntSet.union rb (reachable_raises handler)

let handler_live_vars (env : state) (e : Anf.aexpr) : Ident.Set.t =
  let ids = reachable_raises e in
  IntSet.fold
    (fun id acc ->
      match Exn_frame.handler id env.exn with
      | Some handler -> Ident.Set.union acc handler.owned
      | None -> acc)
    ids Ident.Set.empty

let keep_view_owners env vars =
  if Ident.Map.is_empty env.scope.view_owners then vars
  else
    Ident.Set.fold (fun id live ->
      match Ident.Map.find_opt id env.scope.view_owners with
      | Some owners -> Ident.Set.union owners live
      | None -> live) vars vars

let live_with_handlers (env : state) (e : Anf.aexpr) : Ident.Set.t =
  keep_view_owners env (Ident.Set.union (Anf.free_vars e) (handler_live_vars env e))

let rec emit_drops_list (vars : Ident.t list) (cont : Anf.aexpr) : Anf.aexpr =
  match vars with
  | [] -> cont
  | v :: rest -> (
      let tok = Ident.create_local "reuse" in
      match Arc_views.inject_reuse tok cont with
      | Some cont' ->
          emit_drops_list rest (Anf.DropReuse (v, tok, cont'))
      | None -> Anf.Release (v, emit_drops_list rest cont))

let emit_drops (env : state) (vars : Ident.Set.t) (cont : Anf.aexpr) : Anf.aexpr =
  let to_drop =
    Ident.Set.filter
      (fun v -> not (Ident.Set.mem v env.scope.imm || Ident.Set.mem v env.facts.pure))
      vars
    |> Ident.Set.elements
  in
  emit_drops_list to_drop cont

let emit_plain_drops (env : state) (vars : Ident.Set.t) (cont : Anf.aexpr) :
    Anf.aexpr =
  Ident.Set.fold
    (fun v acc ->
      if Ident.Set.mem v env.scope.imm || Ident.Set.mem v env.facts.pure then acc
      else Anf.Release (v, acc))
    vars cont

let emit_mut_releases (muts : Ident.Set.t) (cont : Anf.aexpr) : Anf.aexpr =
  Ident.Set.fold (fun m acc -> Anf.ReleaseMut (m, acc)) muts cont

let prepare_consumed (env : state) ~(borrowed_also : Ident.Set.t)
    ~(live_after : Ident.Set.t) (atoms : Anf.atom list)
    (k : Ident.Set.t -> Anf.atom list -> Anf.aexpr) : Anf.aexpr =
  let counts : (Ident.t, int) Hashtbl.t = Hashtbl.create 8 in
  let mat_binds = ref [] in
  let atoms' =
    List.map
      (fun (a : Anf.atom) ->
        match a with
        | MutVar _ | BorrowedField _ | ModuleSlot _ ->
            let tmp = Ident.create_local "mval" in
            mat_binds := (tmp, a) :: !mat_binds;
            Anf.Var tmp
        | Var id ->
            if not (Ident.Set.mem id env.scope.imm || Ident.Set.mem id env.facts.pure) then
              Hashtbl.replace counts id
                (1 + Option.value ~default:0 (Hashtbl.find_opt counts id));
            a
        | _ -> a)
      atoms
  in
  let retains = ref [] in
  let next_owned = ref env.scope.owned in
  Hashtbl.iter
    (fun id n ->
      let still_alive =
        is_borrowed env id
        || Ident.Set.mem id live_after
        || Ident.Set.mem id borrowed_also
      in
      let n_retains =
        if still_alive then n
        else begin
          next_owned := Ident.Set.remove id !next_owned;
          n - 1
        end
      in
      for _ = 1 to n_retains do
        retains := id :: !retains
      done)
    counts;
  let body = k !next_owned atoms' in
  let body =
    List.fold_left (fun acc id -> Anf.Retain (id, acc)) body !retains
  in
  List.fold_left
    (fun acc (tmp, source) ->
      let next = if is_imm_atom env source then acc else Anf.Retain (tmp, acc) in
      Anf.Let (tmp, Atom source, next))
    body !mat_binds

let unwind_cleanup (env : state) (live_vars : Ident.Set.t)
    (live_muts : Ident.Set.t) : Anf.aexpr =
  let all_vars = Ident.Set.union live_vars env.scope.frame_borrowed in
  let drop_vars = Ident.Set.diff all_vars env.exn.try_owned in
  let drop_muts = Ident.Set.diff live_muts env.exn.try_muts in
  emit_plain_drops env drop_vars (emit_mut_releases drop_muts Anf.Unwind)

let emit_shadowed_call (env : state) ~(ce : Anf.cexpr) ~(ce_may_raise : bool)
    ~(is_pure_tail : bool) ~(rem_after_before : Ident.Set.t)
    ~(body_cont : Anf.aexpr) (make_let : Anf.aexpr -> Anf.aexpr) : Anf.aexpr =
  let can_suspend = is_yielding_ce env ce && not is_pure_tail in
  let svars, smuts =
    if can_suspend then
      let vs =
        Ident.Set.union rem_after_before env.scope.frame_borrowed
        |> Ident.Set.filter (fun v ->
               not (Ident.Set.mem v env.scope.imm || Ident.Set.mem v env.facts.pure))
        |> Ident.Set.elements
      in
      (vs, Ident.Set.elements env.scope.muts)
    else ([], [])
  in
  let n_shadow = List.length svars + List.length smuts in
  let wrap_pop k =
    if can_suspend then Anf.ShadowPop (n_shadow, 0, k) else k
  in
  let after_ce =
    if ce_may_raise && not is_pure_tail then
      let on_err = unwind_cleanup env rem_after_before env.scope.muts in
      Anf.CheckExn (exception_check env ce, wrap_pop on_err, wrap_pop body_cont)
    else wrap_pop body_cont
  in
  let inner = make_let after_ce in
  if can_suspend then Anf.ShadowPush (svars, smuts, [], inner) else inner

(* Keep the recursive dispatcher's frame small when the compiler builds itself.
   Parser-generated ANF can contain hundreds of nested static catches. *)
let rec transform_aexpr (env : state) (e : Anf.aexpr) : Anf.aexpr =
  match e with
  | Halt a -> transform_halt env a
  | HaltScalar _ ->
      let cont = emit_mut_releases (Ident.Set.diff env.scope.muts env.scope.no_release_muts) e in
      emit_drops env env.scope.owned cont
  | Raise a -> transform_raise env a
  | Unwind | CheckExn _ | Retain _ | Release _ | ReleaseMut _
  | DropReuse _ | FreeReuse _ | ShadowPush _ | ShadowPop _ ->
      e
  | Let (id, Fun lf, body) -> transform_fun_binding env id lf body
  | Let (id, (Field (index, ((Immutable_field | Mutable_field) as kind),
                     ((Var _ | BorrowedField _) as owner)) as ce), body) -> (
      let stable = kind = Immutable_field in
      match Arc_views.fuse_field_read ~can_borrow:(can_borrow_arguments env)
        ~borrowed_flags:(borrowed_flags env) ~yielding:env.facts.yielding ~stable id index owner body with
      | Some fused -> transform_aexpr env fused
      | None when stable && Arc_views.field_is_read_only_in_loop id body ->
          transform_view env id (Anf.BorrowedField (index, owner)) body
      | None -> transform_let env id ce body)
  | Let (id, Atom ((MutVar slot | BorrowedField (_, MutVar slot)) as source), body)
    when Ident.Set.mem slot env.scope.muts && Arc_views.read_only_slot_snapshot slot id body ->
      transform_view env id source body
  | Let (id, ce, body) -> transform_let env id ce body
  | MutLet (id, ce, body) -> transform_mutable_let env id ce body
  | LetJoin (id, rhs, body) -> (
      match Arc_views.mutable_slot_result env.scope.slot_snapshots rhs with
      | Some (slot, field, rhs)
        when Ident.Set.mem slot env.scope.muts && Arc_views.read_only_slot_snapshot slot id body ->
          let ignored = Ident.create_local "slot_join" in
          let source = match field with
            | None -> Anf.MutVar slot
            | Some index -> Anf.BorrowedField (index, MutVar slot) in
          transform_join env ignored rhs (Anf.Let (id, Atom source, body))
      | _ -> transform_join env id rhs body)
  | LetRec (bindings, body) -> transform_recursive_group env bindings body
  | If (cond, th, el) ->
      let th' = transform_branch env th in
      let el' = transform_branch (false_edge env cond) el in
      If (cond, th', el')
  | ScalarIf (rep, cond, th, el) ->
      let th' = transform_branch env th in
      let el' = transform_branch (false_edge env cond) el in
      ScalarIf (rep, cond, th', el')
  | Switch (scrut, sw) ->
      let consts' = List.map (fun (k, a) -> (k, transform_branch env a)) sw.consts in
      let blocks' = List.map (fun (k, a) -> (k, transform_branch env a)) sw.blocks in
      let fail' = Option.map (transform_branch env) sw.fail in
      Switch (scrut, { sw with consts = consts'; blocks = blocks'; fail = fail' })
  | StringSwitch (scrut, cases, fail) ->
      let cases' = List.map (fun (s, a) -> (s, transform_branch env a)) cases in
      let fail' = Option.map (transform_branch env) fail in
      StringSwitch (scrut, cases', fail')
  | StaticCatch (body, hid, binders, handler, result_rep) -> transform_static_catch env body hid binders handler result_rep
  | StaticRaise (hid, args) -> transform_static_raise env hid args
  | TryWith (body, exn_id, handler) -> transform_try_with env body exn_id handler
  | While (cond, body) -> transform_while env cond body
  | For (idx, s, e, dir, body) -> transform_for env idx s e dir body

and[@inline never] transform_halt env a =
  prepare_consumed env ~borrowed_also:Ident.Set.empty
    ~live_after:Ident.Set.empty [ a ] (fun remaining_owned atoms' ->
      let a' = match atoms' with [ x ] -> x | _ -> assert false in
      let cont = Anf.Halt a' in
      (* A [Halt] may flow into a join point or loop exit instead of
         leaving the function; only release mutables that really leave
         scope here (muts introduced inside this region). *)
      let cont =
        emit_mut_releases
          (Ident.Set.diff env.scope.muts env.scope.no_release_muts)
          cont
      in
      emit_drops env remaining_owned cont)

and[@inline never] transform_raise env a =
  prepare_consumed env ~borrowed_also:Ident.Set.empty
    ~live_after:env.exn.try_owned [ a ] (fun remaining_owned atoms' ->
      let a' = match atoms' with [ x ] -> x | _ -> assert false in
      let drop_vars =
        Ident.Set.diff
          (Ident.Set.union remaining_owned env.scope.frame_borrowed)
          env.exn.try_owned
      in
      let drop_muts = Ident.Set.diff env.scope.muts env.exn.try_muts in
      emit_plain_drops env drop_vars
        (emit_mut_releases drop_muts (Anf.Raise a')))

and[@inline never] transform_fun_binding env id lf body =
  if Ident.Set.mem id env.facts.pure then
    let lf' = transform_fun env ~self_id:None ~has_closure:false lf in
    let read_only =
      if Ident.Set.mem id env.facts.yielding then Ident.Set.empty
      else read_only_parameters ~borrowed:(borrowed_flags env) lf
    in
    let body' =
      if Ident.Set.is_empty read_only then transform_aexpr env body
      else
        let worker, env_body = add_borrowed_entry env id (borrow_flags lf read_only) in
        let body' = transform_aexpr env_body body in
        let exported = Ident.Set.mem id env.facts.exported in
        if exported || Ident.Set.mem worker (Anf.free_vars body') then
          let worker_def =
            transform_fun env ~self_id:None ~has_closure:false
              ~borrowed_params:read_only { lf with private_entry = not exported }
          in
          Let (worker, Fun worker_def, body')
        else body'
    in
    Let (id, Fun lf', body')
  else
    let cap =
      Anf.free_vars lf.body
      |> Ident.Set.filter (fun v ->
             not (List.exists (Ident.same v) (Anf.bound_parameters lf))
             && not (Ident.Set.mem v env.facts.pure))
    in
    let cap_atoms = List.map (fun v -> Anf.Var v) (Ident.Set.elements cap) in
    let lf' = transform_fun env ~self_id:None ~has_closure:true lf in
    let base_live = Ident.Set.remove id (live_with_handlers env body) in
    let live_after =
      if can_raise env body then Ident.Set.union base_live env.exn.try_owned
      else base_live
    in
    prepare_consumed env ~borrowed_also:Ident.Set.empty ~live_after
      cap_atoms (fun remaining_owned _ ->
        let dead_before = Ident.Set.diff remaining_owned live_after in
        let owned_body =
          Ident.Set.add id (Ident.Set.diff remaining_owned dead_before)
        in
        let body' =
          transform_aexpr { env with scope = { env.scope with owned = owned_body } } body
        in
        emit_drops env dead_before (Let (id, Fun lf', body')))

and[@inline never] transform_mutable_let env id ce body =
  let immediate = mutlet_is_imm env id ce body in
  let ce = specialize_ownership env ce in
  let ce_may_raise = ce_may_raise env ce in
  let base_live_body = Ident.Set.remove id (live_with_handlers env body) in
  let ce = select_imported_entry env base_live_body ce in
  let borrowed_in_ce, consumed_in_ce = atom_operands ce in
  let borrowed_in_ce = keep_view_owners env borrowed_in_ce in
  let live_before_ce =
    Ident.Set.union base_live_body
      (if ce_may_raise || can_raise env body then env.exn.try_owned
       else Ident.Set.empty)
  in
  let live_after = Ident.Set.union live_before_ce borrowed_in_ce in
  prepare_consumed env ~borrowed_also:borrowed_in_ce ~live_after
    consumed_in_ce (fun remaining_owned atoms' ->
      let ce' = rebuild_cexpr ce atoms' in
      let used_before = Ident.Set.union borrowed_in_ce live_before_ce in
      let dead_before = Ident.Set.diff remaining_owned used_before in
      let rem_after_before = Ident.Set.diff remaining_owned dead_before in
      let live_for_after_ce =
        Ident.Set.union base_live_body
          (if can_raise env body then env.exn.try_owned else Ident.Set.empty)
      in
      let dead_after = Ident.Set.diff rem_after_before live_for_after_ce in
      let live_for_body = Ident.Set.diff rem_after_before dead_after in
      let env_body =
        { env with
          scope = { env.scope with
            owned = live_for_body;
            imm = set_imm env.scope.imm id immediate;
            muts = if immediate then env.scope.muts else Ident.Set.add id env.scope.muts } }
      in
      let body' = transform_aexpr env_body body in
      let body_with_dead_after = emit_drops env dead_after body' in
      let make_let next = Anf.MutLet (id, ce', next) in
      let node =
        emit_shadowed_call env ~ce:ce' ~ce_may_raise ~is_pure_tail:false
          ~rem_after_before ~body_cont:body_with_dead_after make_let
      in
      emit_drops env dead_before node)

and[@inline never] transform_recursive_group env bindings body =
  let rec_ids =
    List.fold_left
      (fun s (rb : Anf.rec_binding) -> Ident.Set.add rb.id s)
      Ident.Set.empty bindings
  in
  let all_pure =
    List.for_all
      (fun (rb : Anf.rec_binding) -> Ident.Set.mem rb.id env.facts.pure)
      bindings
  in
  if all_pure then
    transform_pure_group env bindings body
  else
    let cap_list_per_rb =
      List.map
        (fun (rb : Anf.rec_binding) ->
          Anf.free_vars rb.def.body
          |> Ident.Set.filter (fun v ->
                 not (List.exists (Ident.same v) (Anf.bound_parameters rb.def))
                 && not (Ident.Set.mem v rec_ids)
                 && not (Ident.Set.mem v env.facts.pure))
          |> Ident.Set.elements)
        bindings
    in
    let all_cap_atoms =
      List.concat_map (List.map (fun v -> Anf.Var v)) cap_list_per_rb
    in
    let self_opt =
      match bindings with [ rb ] -> Some rb.id | _ -> None
    in
    let bindings' =
      List.map2
        (fun (rb : Anf.rec_binding) cap_outer ->
          let env_fun =
            { env with
              scope = { env.scope with
                borrowed =
                Ident.Set.union env.scope.borrowed
                  (Ident.Set.union rec_ids (Ident.Set.of_list cap_outer)) } }
          in
          { rb with
            def =
              transform_fun env_fun ~self_id:self_opt ~has_closure:true
                rb.def })
        bindings cap_list_per_rb
    in
    let base_live =
      Ident.Set.diff (live_with_handlers env body) rec_ids
    in
    let live_after =
      if can_raise env body then Ident.Set.union base_live env.exn.try_owned
      else base_live
    in
    prepare_consumed env ~borrowed_also:Ident.Set.empty ~live_after
      all_cap_atoms (fun remaining_owned _ ->
        let dead_before = Ident.Set.diff remaining_owned live_after in
        let owned_body =
          Ident.Set.union rec_ids
            (Ident.Set.diff remaining_owned dead_before)
        in
        let body' =
          transform_aexpr { env with scope = { env.scope with owned = owned_body } } body
        in
        emit_drops env dead_before (LetRec (bindings', body')))

and[@inline never] transform_static_catch env body hid binders handler result_rep =
  let immediate = handler_immediates env hid binders body in
  let base_fh =
    List.fold_left
      (fun s b -> Ident.Set.remove b s)
      (live_with_handlers env handler)
      binders
  in
  let fv_handler =
    if can_raise env handler then Ident.Set.union base_fh env.exn.try_owned
    else base_fh
  in
  let handler_owned = Ident.Set.inter env.scope.owned fv_handler in
  let handler_owned_list =
    List.fold_left
      (fun acc b -> if Ident.Set.mem b immediate then acc else Ident.Set.add b acc)
      handler_owned binders
  in
  let target_live = Ident.Set.union handler_owned env.scope.frame_borrowed in
  let target =
    { Exn_frame.Handler.owned = handler_owned;
      live = target_live; muts = env.scope.muts }
  in
  let exn = Exn_frame.with_handler hid target env.exn in
  let body' = transform_aexpr { env with exn } body in
  let dead_at_handler = Ident.Set.diff handler_owned fv_handler in
  let handler' =
    transform_aexpr
      { env with
        scope = { env.scope with
          owned = Ident.Set.diff handler_owned_list dead_at_handler;
          imm = Ident.Set.union (Ident.Set.diff env.scope.imm (Ident.Set.of_list binders)) immediate } }
      handler
  in
  StaticCatch (body', hid, binders, emit_drops env dead_at_handler handler', result_rep)

and[@inline never] transform_static_raise env hid args =
  let target_owned, target_live, target_muts =
    match Exn_frame.handler hid env.exn with
    | Some { owned; live; muts } -> owned, live, muts
    | None -> (Ident.Set.empty, env.scope.frame_borrowed, env.scope.muts)
  in
  prepare_consumed env ~borrowed_also:Ident.Set.empty
    ~live_after:target_owned args (fun remaining_owned args' ->
      let dead_vars =
        Ident.Set.diff
          (Ident.Set.union remaining_owned env.scope.frame_borrowed)
          target_live
      in
      let dead_muts = Ident.Set.diff env.scope.muts target_muts in
      emit_drops env dead_vars
        (emit_mut_releases dead_muts (StaticRaise (hid, args'))))

and[@inline never] transform_try_with env body exn_id handler =
  let outer_needed =
    if can_raise env handler then env.exn.try_owned else Ident.Set.empty
  in
  let fv_handler =
    Ident.Set.remove exn_id
      (Ident.Set.union (live_with_handlers env handler) outer_needed)
  in
  let catch_owned = Ident.Set.inter env.scope.owned fv_handler in
  let body_env =
    { env with exn = Exn_frame.protect
        ~owned:(Ident.Set.union catch_owned env.scope.frame_borrowed)
        ~muts:env.scope.muts env.exn }
  in
  let body' = transform_aexpr body_env body in
  let handler_env =
    { env with scope = { env.scope with owned = Ident.Set.add exn_id catch_owned } }
  in
  let handler' = transform_aexpr handler_env handler in
  TryWith (body', exn_id, handler')

and[@inline never] transform_while env cond body =
  let loop_env =
    { env with
      scope = { env.scope with
        owned = Ident.Set.empty;
        frame_borrowed = Ident.Set.union env.scope.frame_borrowed env.scope.owned;
        no_release_muts = env.scope.muts };
      exn = Exn_frame.non_tail env.exn }
  in
  let cond' = transform_aexpr loop_env cond in
  let body' = transform_aexpr loop_env body in
  if Ident.Set.is_empty env.scope.owned && Ident.Set.is_empty env.scope.muts then
    While (cond', body')
  else
    let u = Ident.create_local "wend" in
    let dead_muts = Ident.Set.diff env.scope.muts env.scope.no_release_muts in
    let cont =
      emit_drops env env.scope.owned
        (emit_mut_releases dead_muts (Halt (Var u)))
    in
    LetJoin (u, While (cond', body'), cont)

and[@inline never] transform_for env idx s e dir body =
  let loop_env =
    { env with
      scope = { env.scope with
        owned = Ident.Set.empty;
        frame_borrowed = Ident.Set.union env.scope.frame_borrowed env.scope.owned;
        imm = Ident.Set.add idx env.scope.imm;
        no_release_muts = env.scope.muts };
      exn = Exn_frame.non_tail env.exn }
  in
  let body' = transform_aexpr loop_env body in
  if Ident.Set.is_empty env.scope.owned && Ident.Set.is_empty env.scope.muts then
    For (idx, s, e, dir, body')
  else
    let u = Ident.create_local "fend" in
    let dead_muts = Ident.Set.diff env.scope.muts env.scope.no_release_muts in
    let cont =
      emit_drops env env.scope.owned
        (emit_mut_releases dead_muts (Halt (Var u)))
    in
    LetJoin (u, For (idx, s, e, dir, body'), cont)

and transform_view env id source body =
  let owners = keep_view_owners env (atom_vars source) in
  (* Only a direct, checked snapshot represents the complete slot value.
     The view check ensures any use of this alias precedes an overwrite. *)
  let slot_snapshots =
    match source with
    | Anf.MutVar slot -> Ident.Map.add id slot env.scope.slot_snapshots
    | _ -> env.scope.slot_snapshots in
  let env =
    { env with
      scope = { env.scope with
        view_owners = Ident.Map.add id owners env.scope.view_owners;
        slot_snapshots } } in
  let live = Ident.Set.union owners (live_with_handlers env body) in
  let live = if can_raise env body then Ident.Set.union live env.exn.try_owned else live in
  let dead = Ident.Set.diff env.scope.owned live in
  let body = transform_aexpr { env with scope = { env.scope with owned = Ident.Set.diff env.scope.owned dead } } body in
  emit_drops env dead (Let (id, Atom source, body))

and transform_join env id rhs body : Anf.aexpr =
  let base_live_body = Ident.Set.remove id (live_with_handlers env body) in
  let live_body_only =
    if can_raise env body then Ident.Set.union base_live_body env.exn.try_owned
    else base_live_body
  in
  let live_rhs =
    Ident.Set.union (live_with_handlers env rhs)
      (if can_raise env rhs then env.exn.try_owned else Ident.Set.empty)
  in
  let shared = Ident.Set.inter env.scope.owned live_body_only in
  let owned_rhs_only = Ident.Set.diff env.scope.owned live_body_only in
  let dead_before = Ident.Set.diff owned_rhs_only live_rhs in
  let owned_for_rhs = Ident.Set.diff owned_rhs_only dead_before in
  let env_rhs =
    { env with
      scope = { env.scope with
        owned = owned_for_rhs;
        frame_borrowed = Ident.Set.union env.scope.frame_borrowed shared;
        no_release_muts = env.scope.muts };
      exn = Exn_frame.non_tail env.exn }
  in
  let rhs' = transform_aexpr env_rhs rhs in
  let imm =
    if Ident.Set.mem id env.facts.typed_imm || Anf.returns_scalar rhs
       || aexpr_returns_imm ~typed_imm:env.facts.typed_imm ~pure:env.facts.pure ~imm_funs:env.facts.imm_funs env.scope.imm rhs
    then Ident.Set.add id env.scope.imm
    else Ident.Set.remove id env.scope.imm
  in
  let env_body = { env with scope = { env.scope with owned = Ident.Set.add id shared; imm } } in
  let body' = transform_aexpr env_body body in
  emit_drops env dead_before (LetJoin (id, rhs', body'))

and transform_let env id ce body =
  let ce = specialize_ownership env ce in
  let ce_may_raise = ce_may_raise env ce in
  let base_live_body = Ident.Set.remove id (live_with_handlers env body) in
  let ce = select_imported_entry env base_live_body ce in
  let borrowed_in_ce, consumed_in_ce, rebuild =
    match borrowed_call env base_live_body ce with
    | None ->
        let borrowed, consumed = atom_operands ce in
        borrowed, consumed, rebuild_cexpr ce
    | Some (worker, pairs) ->
        let borrowed, consumed = List.partition_map
            (function true, a -> Either.Left a | false, a -> Either.Right a) pairs in
        let rebuild consumed = Anf.App (Var worker, restore_borrowed pairs consumed) in
        atoms_vars borrowed, consumed, rebuild
  in
  let borrowed_in_ce = keep_view_owners env borrowed_in_ce in
  let live_before_ce =
    Ident.Set.union base_live_body
      (if ce_may_raise || can_raise env body then env.exn.try_owned
       else Ident.Set.empty)
  in
  let live_after = Ident.Set.union live_before_ce borrowed_in_ce in
  prepare_consumed env ~borrowed_also:borrowed_in_ce ~live_after
    consumed_in_ce (fun remaining_owned atoms' ->
      let ce' = rebuild atoms' in
      let used_before =
        Ident.Set.union borrowed_in_ce live_before_ce
      in
      let dead_before = Ident.Set.diff remaining_owned used_before in
      let rem_after_before = Ident.Set.diff remaining_owned dead_before in
      let live_for_after_ce =
        Ident.Set.union base_live_body
          (if can_raise env body then env.exn.try_owned else Ident.Set.empty)
      in
      let dead_after = Ident.Set.diff rem_after_before live_for_after_ce in
      let live_for_body = Ident.Set.diff rem_after_before dead_after in
      let is_imm = Ident.Set.mem id env.facts.typed_imm || is_imm_cexpr env ce in
      let env_body =
        { env with
          scope = { env.scope with
            owned = Ident.Set.add id live_for_body;
            imm =
            (if is_imm then Ident.Set.add id env.scope.imm
             else Ident.Set.remove id env.scope.imm) } }
      in
      let body' = transform_aexpr env_body body in
      let body_with_dead_after = emit_drops env dead_after body' in
      let is_pure_tail =
        env.exn.in_tail
        &&
        match body with
        | Halt (Var v) when Ident.same id v ->
            env.exn.try_depth = 0
            && Ident.Set.is_empty
                 (Ident.Set.diff
                    (Ident.Set.union rem_after_before env.scope.frame_borrowed)
                    env.exn.try_owned)
            && Ident.Set.is_empty (Ident.Set.diff env.scope.muts env.exn.try_muts)
            && Ident.Set.is_empty dead_after
        | _ -> false
      in
      let make_let next = Anf.Let (id, ce', next) in
      let node =
        emit_shadowed_call env ~ce:ce' ~ce_may_raise ~is_pure_tail
          ~rem_after_before ~body_cont:body_with_dead_after make_let
      in
      emit_drops env dead_before node)

and transform_branch (env : state) (arm : Anf.aexpr) : Anf.aexpr =
  let base_live = live_with_handlers env arm in
  let live =
    if can_raise env arm then Ident.Set.union base_live env.exn.try_owned
    else base_live
  in
  let dead = Ident.Set.diff env.scope.owned live in
  let arm' = transform_aexpr { env with scope = { env.scope with owned = Ident.Set.diff env.scope.owned dead } } arm in
  emit_drops env dead arm'

and transform_pure_group env (bindings : Anf.rec_binding list) body =
  let plan = recursive_borrows ~yielding:env.facts.yielding ~borrowed:(borrowed_flags env) bindings in
  let env, workers =
    List.fold_left
      (fun (env, workers) (rb : Anf.rec_binding) ->
        let flags = Ident.Map.find rb.id plan in
        if not (List.exists Fun.id flags) then env, workers
        else
          let worker, env = add_borrowed_entry env rb.id flags in
          let params =
            List.fold_left2
              (fun acc (param, _) borrow ->
                if borrow then Ident.Set.add param acc else acc)
              Ident.Set.empty rb.def.params flags
          in
          env, (worker, params, { rb.def with private_entry = not (Ident.Set.mem rb.id env.facts.exported) }) :: workers)
      (env, []) bindings
  in
  let bindings =
    List.map (fun (rb : Anf.rec_binding) ->
      { rb with def = transform_fun env ~self_id:(Some rb.id) ~has_closure:false rb.def })
      bindings
  in
  let body = transform_aexpr env body in
  let workers =
    List.rev_map (fun (id, borrowed_params, def) ->
      let def =
        transform_fun env ~self_id:(Some id) ~has_closure:false
          ~borrowed_params def
      in
      { Anf.id; def }) workers
  in
  let include_body used (rb : Anf.rec_binding) =
    Ident.Set.union used (Anf.free_vars rb.def.body)
  in
  let rec reachable used =
    let next = List.fold_left (fun used (rb : Anf.rec_binding) ->
      if Ident.Set.mem rb.id used then include_body used rb else used) used workers
    in
    if Ident.Set.equal used next then used else reachable next
  in
  let exported_workers = List.fold_left (fun roots (rb : Anf.rec_binding) ->
    if rb.def.private_entry then roots else Ident.Set.add rb.id roots)
    (Anf.free_vars body) workers in
  let used = reachable (List.fold_left include_body exported_workers bindings) in
  LetRec (bindings @ List.filter (fun (rb : Anf.rec_binding) -> Ident.Set.mem rb.id used) workers, body)

and transform_fun (env : state) ~self_id ~has_closure
    ?(borrowed_params = Ident.Set.empty) (lf : Anf.lfunction) :
    Anf.lfunction =
  let params_set =
    Ident.Set.of_list (Anf.bound_parameters lf)
  in
  let free = Anf.free_vars lf.body in
  let borrowed =
    if not has_closure then env.scope.borrowed
    else
      let captured =
        Ident.Set.filter
          (fun v ->
            not (Ident.Set.mem v params_set) && not (Ident.Set.mem v env.facts.pure))
          free
      in
      let captured =
        match self_id with
        | Some s -> Ident.Set.add s captured
        | None -> captured
      in
      Ident.Set.union env.scope.borrowed captured
  in
  let owned_params = Ident.Set.diff params_set borrowed_params in
  let scope =
    { Scope.empty with
      owned = owned_params; borrowed = Ident.Set.union borrowed borrowed_params;
      imm = Ident.Set.union (Ident.Set.diff env.scope.imm params_set) (imm_params_of lf) }
  in
  let fn_env = { env with scope; exn = Exn_frame.root } in
  let live_body = Anf.free_vars lf.body in
  let dead_params = Ident.Set.diff owned_params live_body in
  let body' =
    transform_aexpr
      { fn_env with scope = { fn_env.scope with owned = Ident.Set.diff owned_params dead_params } }
      lf.body
  in
  { lf with body = emit_drops fn_env dead_params body' }

and rebuild_cexpr (ce : Anf.cexpr) (atoms' : Anf.atom list) : Anf.cexpr =
  match (ce, atoms') with
  | Atom _, [ a ] -> Atom a
  | MakeBlock (tag, scan, _), args -> MakeBlock (tag, scan, args)
  | AllocReuse (tok, tag, scan, _), args -> AllocReuse (tok, tag, scan, args)
  | MakeArray (kind, _), args -> MakeArray (kind, args)
  | SetField (i, repr, arg, _), [ rhs ] -> SetField (i, repr, arg, rhs)
  | ArraySet (s, k, arr, idx, _), [ v ] -> ArraySet (s, k, arr, idx, v)
  | MakeArrayInit (len, _), [ init ] -> MakeArrayInit (len, init)
  | App (fn, _), args -> App (fn, args)
  | DirectApp (({ borrowed_entry = Some (_, flags); _ } as target), original), args ->
      DirectApp (target, restore_borrowed (List.combine flags original) args)
  | DirectApp (target, _), args -> DirectApp (target, args)
  | Recur _, args -> Recur args
  | Assign (id, _), [ rhs ] -> Assign (id, rhs)
  | AssignImm (id, _), [ rhs ] -> AssignImm (id, rhs)
  | StoreModuleSlot (id, _), [ value ] -> StoreModuleSlot (id, value)
  | _ -> ce

let run_with_effects ?(exported = []) (prog : Anf.program) =
  let facts = Program_facts.analyze ~exported prog in
  let exported_workers = Hashtbl.create 16 in
  let init_env =
    { facts; scope = Scope.empty; exn = Exn_frame.root;
      borrowed_entries = Ident.Map.empty; exported_workers }
  in
  let code = transform_aexpr init_env prog.code in
  let workers id =
    Option.map (fun entry -> entry.worker, entry.borrow)
      (Hashtbl.find_opt exported_workers id)
  in
  { prog with code }, Program_facts.effects facts, workers

let run prog = let prog, _, _ = run_with_effects prog in prog
