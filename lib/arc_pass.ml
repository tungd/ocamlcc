(* Perceus ARC dup / drop / reuse + zero-leak exception middle-end pass.

   Ownership contract:
   - Every [Let]-bound variable and function parameter starts as OWNED (+1 rc).
   - Pure global functions ([has_closure = false]), tagged immediates
     ([int], [char], [unit]), and static string/const blocks never require
     retain or release.
   - Closure captured variables ([env]), closure self-references, and
     variables borrowed across [LetJoin] / [While] / [For] use BORROWED reads
     with 0 refcount overhead, retaining only on escape/transfer.
     [frame_borrowed] distinguishes same-frame borrows ([LetJoin]/[While]/[For])
     so exceptional unwinding drops them while never dropping caller captures.
   - Field/array loads retain in codegen; overwrites release old slots.
   - [TryWith] / [Raise] / [CheckExn] / [Unwind] ensure every local owned
     value, [MutLet] slot, and open reuse token unwinds with zero leaks.
   - A [MutLet] slot is released exactly once, where it leaves scope: the
     function-exit [Halt], a [Raise] path, or a [StaticRaise] to a narrower
     handler. [Halt]s that flow into a [LetJoin] rhs / [While] / [For]
     continuation are not scope exits; [env.no_release_muts] defers those
     slots to the continuation that still owns them. *)

module IntSet = Set.Make (Int)

type state = {
  owned : Ident.Set.t;
  borrowed : Ident.Set.t;
  frame_borrowed : Ident.Set.t;
  imm : Ident.Set.t;
  pure : Ident.Set.t;
  known_funs : Ident.Set.t;
  yielding_funs : Ident.Set.t;
  muts : Ident.Set.t;
  (* Mutable slots that stay in scope after the current join point or loop
     exit ([LetJoin] rhs, [While]/[For] condition and body). Their single
     [ReleaseMut] is emitted by the continuation that still uses them, so
     [Halt] must skip them: [ReleaseMut env.muts - env.no_release_muts]. *)
  no_release_muts : Ident.Set.t;
  handlers : (int, Ident.Set.t * Ident.Set.t) Hashtbl.t;
  try_owned : Ident.Set.t;
  try_muts : Ident.Set.t;
  try_depth : int;
}

let is_borrowed (env : state) (id : Ident.t) : bool =
  Ident.Set.mem id env.borrowed || Ident.Set.mem id env.frame_borrowed

let is_imm_atom (env : state) (a : Anf.atom) : bool =
  match a with
  | Int _ | Char _ | Unit | String _ | Float _ | Int32 _ | Int64 _
  | Nativeint _ | ConstFloatArray _ | ConstBlock _ ->
      true
  | Var id -> Ident.Set.mem id env.imm || Ident.Set.mem id env.pure
  | MutVar _ -> false

let is_imm_binop : Anf.binop -> bool = function
  | Add | Sub | Mul | Div | Mod | And | Or | Xor | Lsl | Lsr | Asr | Cmp _
  | Compare_ints | Isout | Fcmp _ | Compare_floats | Bint_cmp _
  | Compare_bints _ ->
      true
  | Float_arithmetic _ | Bint_add _ | Bint_sub _ | Bint_mul _
  | Bint_div _ | Bint_mod _ | Bint_and _ | Bint_or _ | Bint_xor _
  | Bint_lsl _ | Bint_lsr _ | Bint_asr _ ->
      false

let is_imm_unop : Anf.unop -> bool = function
  | Neg | Not | Offset _ | Isint | String_length | Array_length
  | Int_of_float | Int_of_bint _ ->
      true
  | Float_of_int | Fneg | Fabs | Bint_of_int _ | Bint_cvt _ | Bint_neg _ ->
      false

let is_imm_cexpr (env : state) (ce : Anf.cexpr) : bool =
  match ce with
  | Atom a -> is_imm_atom env a
  | Binop (op, _, _) -> is_imm_binop op
  | Unop (op, _) -> is_imm_unop op
  | SetField _ | SetFloatField _ | OffsetRef _ | StringGet _
  | BytesSet _ | ArraySet _ | Builtin _ | Assign _ ->
      true
  | MakeBlock (_, []) | Float64Load _ | FloatValue _ | FloatBinop _ | Float64Store _ -> true
  | MakeBlock _ | AllocReuse _ | MakeArray _ | Field _ | FloatField _
  | BigarrayAccess _ | ArrayGet _ | CreateBytes _ | MakeArrayInit _ | App _ | Ccall _
  | GetGlobal _ | Fun _ ->
      false

let atom_vars (a : Anf.atom) : Ident.Set.t =
  match a with
  | Var id | MutVar id -> Ident.Set.singleton id
  | Int _ | Char _ | String _ | Float _ | Int32 _ | Int64 _ | Nativeint _
  | ConstFloatArray _ | ConstBlock _ | Unit ->
      Ident.Set.empty

let atoms_vars (xs : Anf.atom list) : Ident.Set.t =
  List.fold_left (fun s a -> Ident.Set.union s (atom_vars a)) Ident.Set.empty xs

let atom_operands (ce : Anf.cexpr) : Ident.Set.t * Anf.atom list =
  match ce with
  | Atom a -> (Ident.Set.empty, [ a ])
  | Binop (_, a, b) ->
      (Ident.Set.union (atom_vars a) (atom_vars b), [])
  | Unop (_, a) -> (atom_vars a, [])
  | MakeBlock (_, args) | AllocReuse (_, _, args) | MakeArray (_, args) ->
      (Ident.Set.empty, args)
  | Field (_, a) | FloatField (_, a) | OffsetRef (_, a) | CreateBytes a ->
      (atom_vars a, [])
  | SetField (_, a, rhs) -> (atom_vars a, [ rhs ])
  | SetFloatField (_, a, rhs) ->
      (Ident.Set.union (atom_vars a) (atom_vars rhs), [])
  | StringGet (_, a, b) | ArrayGet (_, _, a, b) ->
      (Ident.Set.union (atom_vars a) (atom_vars b), [])
  | BytesSet (_, a, b, c) ->
      ( Ident.Set.union (atom_vars a) (Ident.Set.union (atom_vars b) (atom_vars c)),
        [] )
  | ArraySet (_, _, arr, idx, v) ->
      (Ident.Set.union (atom_vars arr) (atom_vars idx), [ v ])
  | MakeArrayInit (len, init) -> (atom_vars len, [ init ])
  | App (fn, args) -> (atom_vars fn, args)
  | Builtin (_, _, a) -> (atom_vars a, [])
  | FloatValue a -> (Anf.float_operand_vars Ident.Set.empty a, [])
  | Float64Load (_, a, i) -> (atoms_vars [a; i], [])
  | Float64Store (_, a, i, v) -> (Anf.float_operand_vars (atoms_vars [a; i]) v, [])
  | FloatBinop (_, a, b) -> (Anf.float_operand_vars (Anf.float_operand_vars Ident.Set.empty a) b, [])
  | BigarrayAccess (_, args) | Ccall (_, args) -> (atoms_vars args, [])
  | GetGlobal _ -> (Ident.Set.empty, [])
  | Assign (_, rhs) -> (Ident.Set.empty, [ rhs ])
  | Fun _ -> (Ident.Set.empty, [])

let is_yielding_ccall name = (Ccalls.find name).Ccalls.yields

let ce_may_raise_fn = function
  | Anf.App _ -> true
  | Binop ((Div | Mod | Bint_div _ | Bint_mod _), _, _) -> true
  | StringGet (true, _, _)
  | BytesSet (true, _, _, _)
  | ArrayGet (true, _, _, _)
  | ArraySet (true, _, _, _, _)
  | CreateBytes _ | MakeArrayInit _ ->
      true
  (* The current Bigarray helpers check bounds even for unsafe accesses. *)
  | BigarrayAccess _ | Float64Load _ | Float64Store _ -> true
  | Ccall (name, _) -> (Ccalls.find name).Ccalls.raises
  | _ -> false

let is_yielding_ce (env : state) = function
  | Anf.Ccall (name, _) -> is_yielding_ccall name
  | App (Var fn, _) ->
      (not (Ident.Set.mem fn env.known_funs))
      || Ident.Set.mem fn env.yielding_funs
  | App _ -> true
  | _ -> false

let compute_yield_info (e : Anf.aexpr) : Ident.Set.t * Ident.Set.t =
  let funs : (Ident.t * Anf.lfunction) list ref = ref [] in
  let rec collect = function
    | Anf.Let (id, Fun lf, body) ->
        funs := (id, lf) :: !funs;
        collect lf.body;
        collect body
    | Let (_, _, body) | MutLet (_, _, body) | For (_, _, _, _, body)
    | Retain (_, body) | Release (_, body) | ReleaseMut (_, body)
    | DropReuse (_, _, body) | FreeReuse (_, body)
    | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
        collect body
    | LetRec (bindings, body) ->
        List.iter
          (fun (rb : Anf.rec_binding) ->
            funs := (rb.id, rb.def) :: !funs;
            collect rb.def.body)
          bindings;
        collect body
    | LetJoin (_, a, b) | If (_, a, b) | FloatIf (_, a, b) | CheckExn (a, b) | While (a, b)
    | StaticCatch (a, _, _, b) | TryWith (a, _, b) ->
        collect a;
        collect b
    | Switch (_, sw) ->
        List.iter (fun (_, arm) -> collect arm) sw.consts;
        List.iter (fun (_, arm) -> collect arm) sw.blocks;
        Option.iter collect sw.fail
    | StringSwitch (_, cases, fail) ->
        List.iter (fun (_, arm) -> collect arm) cases;
        Option.iter collect fail
    | Halt _ | HaltFloat _ | StaticRaise _ | Raise _ | Unwind -> ()
  in
  collect e;
  let known =
    List.fold_left (fun s (id, _) -> Ident.Set.add id s) Ident.Set.empty !funs
  in
  let ce_yields yielding = function
    | Anf.Ccall (name, _) -> is_yielding_ccall name
    | App (Var fn, _) ->
        (not (Ident.Set.mem fn known)) || Ident.Set.mem fn yielding
    | App _ -> true
    | _ -> false
  in
  let rec body_yields yielding = function
    | Anf.Let (_, ce, body) | MutLet (_, ce, body) ->
        ce_yields yielding ce || body_yields yielding body
    | LetRec (_, body) | For (_, _, _, _, body)
    | Retain (_, body) | Release (_, body) | ReleaseMut (_, body)
    | DropReuse (_, _, body) | FreeReuse (_, body)
    | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
        body_yields yielding body
    | LetJoin (_, a, b) | If (_, a, b) | FloatIf (_, a, b) | CheckExn (a, b) | While (a, b)
    | StaticCatch (a, _, _, b) | TryWith (a, _, b) ->
        body_yields yielding a || body_yields yielding b
    | Switch (_, sw) ->
        List.exists (fun (_, arm) -> body_yields yielding arm) sw.consts
        || List.exists (fun (_, arm) -> body_yields yielding arm) sw.blocks
        || Option.fold ~none:false ~some:(body_yields yielding) sw.fail
    | StringSwitch (_, cases, fail) ->
        List.exists (fun (_, arm) -> body_yields yielding arm) cases
        || Option.fold ~none:false ~some:(body_yields yielding) fail
    | Halt _ | HaltFloat _ | StaticRaise _ | Raise _ | Unwind -> false
  in
  let rec fix yielding =
    let next, changed =
      List.fold_left
        (fun (acc, ch) (id, (lf : Anf.lfunction)) ->
          if Ident.Set.mem id acc then (acc, ch)
          else if body_yields acc lf.body then (Ident.Set.add id acc, true)
          else (acc, ch))
        (yielding, false) !funs
    in
    if changed then fix next else next
  in
  (known, fix Ident.Set.empty)

let rec can_raise (e : Anf.aexpr) : bool =
  match e with
  | Halt _ | HaltFloat _ | Unwind | StaticRaise _ -> false
  | Raise _ -> true
  | Let (_, ce, body) | MutLet (_, ce, body) ->
      ce_may_raise_fn ce || can_raise body
  | LetRec (_, body)
  | Retain (_, body)
  | Release (_, body)
  | ReleaseMut (_, body)
  | DropReuse (_, _, body)
  | FreeReuse (_, body)
  | ShadowPush (_, _, _, body)
  | ShadowPop (_, _, body) ->
      can_raise body
  | LetJoin (_, a, b) | If (_, a, b) | FloatIf (_, a, b) | CheckExn (a, b) | While (a, b) ->
      can_raise a || can_raise b
  | For (_, _, _, _, body) -> can_raise body
  | Switch (_, sw) ->
      List.exists (fun (_, arm) -> can_raise arm) sw.consts
      || List.exists (fun (_, arm) -> can_raise arm) sw.blocks
      || Option.fold ~none:false ~some:can_raise sw.fail
  | StringSwitch (_, cases, fail) ->
      List.exists (fun (_, arm) -> can_raise arm) cases
      || Option.fold ~none:false ~some:can_raise fail
  | StaticCatch (body, _, _, handler) ->
      can_raise body || can_raise handler
  | TryWith (_, _, handler) -> can_raise handler

let rec reachable_raises (e : Anf.aexpr) : IntSet.t =
  match e with
  | Halt _ | HaltFloat _ | Unwind | Raise _ -> IntSet.empty
  | StaticRaise (id, _) -> IntSet.singleton id
  | While (a, b) -> IntSet.union (reachable_raises a) (reachable_raises b)
  | For (_, _, _, _, body) -> reachable_raises body
  | Let (_, _, body) | MutLet (_, _, body) | LetRec (_, body)
  | Retain (_, body) | Release (_, body) | ReleaseMut (_, body)
  | DropReuse (_, _, body) | FreeReuse (_, body)
  | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
      reachable_raises body
  | LetJoin (_, rhs, body) | CheckExn (rhs, body) | TryWith (rhs, _, body) ->
      IntSet.union (reachable_raises rhs) (reachable_raises body)
  | If (_, th, el) | FloatIf (_, th, el) ->
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
  | StaticCatch (body, id, _, handler) ->
      let rb = IntSet.remove id (reachable_raises body) in
      IntSet.union rb (reachable_raises handler)

let handler_live_vars (env : state) (e : Anf.aexpr) : Ident.Set.t =
  let ids = reachable_raises e in
  IntSet.fold
    (fun id acc ->
      match Hashtbl.find_opt env.handlers id with
      | Some (ho, _) -> Ident.Set.union acc ho
      | None -> acc)
    ids Ident.Set.empty

let live_with_handlers (env : state) (e : Anf.aexpr) : Ident.Set.t =
  Ident.Set.union (Anf.free_vars e) (handler_live_vars env e)

let rec has_static_raise = function
  | Anf.StaticRaise _ | Unwind | Raise _ -> true
  | Halt _ | HaltFloat _ | While _ | For _ -> false
  | Let (_, _, b) | MutLet (_, _, b) | LetRec (_, b)
  | Retain (_, b) | Release (_, b) | ReleaseMut (_, b)
  | DropReuse (_, _, b) | FreeReuse (_, b)
  | ShadowPush (_, _, _, b) | ShadowPop (_, _, b) ->
      has_static_raise b
  | LetJoin (_, a, b) | If (_, a, b) | FloatIf (_, a, b) | CheckExn (a, b) | TryWith (a, _, b) ->
      has_static_raise a || has_static_raise b
  | Switch (_, sw) ->
      List.exists (fun (_, a) -> has_static_raise a) sw.consts
      || List.exists (fun (_, a) -> has_static_raise a) sw.blocks
      || Option.fold ~none:false ~some:has_static_raise sw.fail
  | StringSwitch (_, cs, fail) ->
      List.exists (fun (_, a) -> has_static_raise a) cs
      || Option.fold ~none:false ~some:has_static_raise fail
  | StaticCatch (b, _, _, h) -> has_static_raise b || has_static_raise h

let rec inject_reuse ?(in_shadow = false) (tok : Ident.t) (e : Anf.aexpr) :
    Anf.aexpr option =
  match e with
  | Let (res, MakeBlock (tag, (_ :: _ as args)), next) ->
      Some (Let (res, AllocReuse (tok, tag, args), next))
  | Let (x, ((Atom _ | Binop _ | Unop _ | Field _ | SetField _
             | FloatField _ | SetFloatField _ | OffsetRef _
             | StringGet _ | BytesSet _ | ArrayGet _ | ArraySet _
             | CreateBytes _ | MakeArrayInit _ | MakeArray _ | App _
             | Float64Load _ | Float64Store _ | FloatValue _ | FloatBinop _
             | Builtin _ | BigarrayAccess _ | Ccall _ | GetGlobal _ | Assign _ | MakeBlock (_, [])) as ce), body) -> (
      match inject_reuse ~in_shadow tok body with
      | Some body' -> Some (Let (x, ce, body'))
      | None -> None)
  | CheckExn (on_err, on_ok) -> (
      match inject_reuse ~in_shadow tok on_ok with
      | Some on_ok' ->
          let on_err' =
            match on_err with
            | Anf.ShadowPop (nv, nr, u) when in_shadow ->
                Anf.ShadowPop (nv, nr + 1, u)
            | _ -> on_err
          in
          Some (CheckExn (FreeReuse (tok, on_err'), on_ok'))
      | None -> None)
  | Retain (x, body) -> (
      match inject_reuse ~in_shadow tok body with
      | Some body' -> Some (Retain (x, body'))
      | None -> None)
  | Release (x, body) -> (
      match inject_reuse ~in_shadow tok body with
      | Some body' -> Some (Release (x, body'))
      | None -> None)
  | ReleaseMut (x, body) -> (
      match inject_reuse ~in_shadow tok body with
      | Some body' -> Some (ReleaseMut (x, body'))
      | None -> None)
  | ShadowPush (vs, ms, rtoks, body) -> (
      match inject_reuse ~in_shadow:true tok body with
      | Some body' -> Some (ShadowPush (vs, ms, tok :: rtoks, body'))
      | None -> None)
  | ShadowPop (nv, nr, body) -> (
      match inject_reuse ~in_shadow:false tok body with
      | Some body' ->
          let nr' = if in_shadow then nr + 1 else nr in
          Some (ShadowPop (nv, nr', body'))
      | None -> None)
  | If (c, th, el) when not (has_static_raise th || has_static_raise el) -> (
      match
        (inject_reuse ~in_shadow tok th, inject_reuse ~in_shadow tok el)
      with
      | Some th', Some el' -> Some (If (c, th', el'))
      | Some th', None -> Some (If (c, th', FreeReuse (tok, el)))
      | None, Some el' -> Some (If (c, FreeReuse (tok, th), el'))
      | None, None -> None)
  | _ -> None

let rec emit_drops_list (vars : Ident.t list) (cont : Anf.aexpr) : Anf.aexpr =
  match vars with
  | [] -> cont
  | v :: rest -> (
      let tok = Ident.create_local "reuse" in
      match inject_reuse tok cont with
      | Some cont' ->
          emit_drops_list rest (Anf.DropReuse (v, tok, cont'))
      | None -> Anf.Release (v, emit_drops_list rest cont))

let emit_drops (env : state) (vars : Ident.Set.t) (cont : Anf.aexpr) : Anf.aexpr =
  let to_drop =
    Ident.Set.filter
      (fun v -> not (Ident.Set.mem v env.imm || Ident.Set.mem v env.pure))
      vars
    |> Ident.Set.elements
  in
  emit_drops_list to_drop cont

let emit_plain_drops (env : state) (vars : Ident.Set.t) (cont : Anf.aexpr) :
    Anf.aexpr =
  Ident.Set.fold
    (fun v acc ->
      if Ident.Set.mem v env.imm || Ident.Set.mem v env.pure then acc
      else Anf.Release (v, acc))
    vars cont

let emit_mut_releases (muts : Ident.Set.t) (cont : Anf.aexpr) : Anf.aexpr =
  Ident.Set.fold (fun m acc -> Anf.ReleaseMut (m, acc)) muts cont

let prepare_consumed (env : state) ~(borrowed_also : Ident.Set.t)
    ~(live_after : Ident.Set.t) (atoms : Anf.atom list)
    (k : Ident.Set.t -> Anf.atom list -> Anf.aexpr) : Anf.aexpr =
  let counts : (Ident.t, int) Hashtbl.t = Hashtbl.create 8 in
  let mat_binds : (Ident.t * Ident.t) list ref = ref [] in
  let atoms' =
    List.map
      (fun (a : Anf.atom) ->
        match a with
        | MutVar m ->
            let tmp = Ident.create_local "mval" in
            mat_binds := (tmp, m) :: !mat_binds;
            Anf.Var tmp
        | Var id ->
            if not (Ident.Set.mem id env.imm || Ident.Set.mem id env.pure) then
              Hashtbl.replace counts id
                (1 + Option.value ~default:0 (Hashtbl.find_opt counts id));
            a
        | _ -> a)
      atoms
  in
  let retains = ref [] in
  let next_owned = ref env.owned in
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
    (fun acc (tmp, m) ->
      Anf.Let (tmp, Atom (MutVar m), Retain (tmp, acc)))
    body !mat_binds

let unwind_cleanup (env : state) (live_vars : Ident.Set.t)
    (live_muts : Ident.Set.t) : Anf.aexpr =
  let all_vars = Ident.Set.union live_vars env.frame_borrowed in
  let drop_vars = Ident.Set.diff all_vars env.try_owned in
  let drop_muts = Ident.Set.diff live_muts env.try_muts in
  emit_plain_drops env drop_vars (emit_mut_releases drop_muts Anf.Unwind)

let emit_shadowed_call (env : state) ~(ce : Anf.cexpr) ~(ce_may_raise : bool)
    ~(is_pure_tail : bool) ~(rem_after_before : Ident.Set.t)
    ~(body_cont : Anf.aexpr) (make_let : Anf.aexpr -> Anf.aexpr) : Anf.aexpr =
  let can_suspend = is_yielding_ce env ce && not is_pure_tail in
  let svars, smuts =
    if can_suspend then
      let vs =
        Ident.Set.union rem_after_before env.frame_borrowed
        |> Ident.Set.filter (fun v ->
               not (Ident.Set.mem v env.imm || Ident.Set.mem v env.pure))
        |> Ident.Set.elements
      in
      (vs, Ident.Set.elements env.muts)
    else ([], [])
  in
  let n_shadow = List.length svars + List.length smuts in
  let wrap_pop k =
    if can_suspend then Anf.ShadowPop (n_shadow, 0, k) else k
  in
  let after_ce =
    if ce_may_raise && not is_pure_tail then
      let on_err = unwind_cleanup env rem_after_before env.muts in
      Anf.CheckExn (wrap_pop on_err, wrap_pop body_cont)
    else wrap_pop body_cont
  in
  let inner = make_let after_ce in
  if can_suspend then Anf.ShadowPush (svars, smuts, [], inner) else inner

let rec transform_aexpr (env : state) (e : Anf.aexpr) : Anf.aexpr =
  match e with
  | Halt a ->
      prepare_consumed env ~borrowed_also:Ident.Set.empty
        ~live_after:Ident.Set.empty [ a ] (fun remaining_owned atoms' ->
          let a' = match atoms' with [ x ] -> x | _ -> assert false in
          let cont = Anf.Halt a' in
          (* A [Halt] may flow into a join point or loop exit instead of
             leaving the function; only release mutables that really leave
             scope here (muts introduced inside this region). *)
          let cont =
            emit_mut_releases
              (Ident.Set.diff env.muts env.no_release_muts)
              cont
          in
          emit_drops env remaining_owned cont)
  | HaltFloat _ ->
      let cont = emit_mut_releases (Ident.Set.diff env.muts env.no_release_muts) e in
      emit_drops env env.owned cont
  | Raise a ->
      prepare_consumed env ~borrowed_also:Ident.Set.empty
        ~live_after:env.try_owned [ a ] (fun remaining_owned atoms' ->
          let a' = match atoms' with [ x ] -> x | _ -> assert false in
          let drop_vars =
            Ident.Set.diff
              (Ident.Set.union remaining_owned env.frame_borrowed)
              env.try_owned
          in
          let drop_muts = Ident.Set.diff env.muts env.try_muts in
          emit_plain_drops env drop_vars
            (emit_mut_releases drop_muts (Anf.Raise a')))
  | Unwind | CheckExn _ | Retain _ | Release _ | ReleaseMut _
  | DropReuse _ | FreeReuse _ | ShadowPush _ | ShadowPop _ ->
      e
  | Let (id, Fun lf, body) ->
      if Ident.Set.mem id env.pure then
        let lf' = transform_fun env ~self_id:None ~has_closure:false lf in
        let body' = transform_aexpr env body in
        Let (id, Fun lf', body')
      else
        let cap =
          Anf.free_vars lf.body
          |> Ident.Set.filter (fun v ->
                 not (List.exists (fun (p, _) -> Ident.same p v) lf.params)
                 && not (Ident.Set.mem v env.pure))
        in
        let cap_atoms = List.map (fun v -> Anf.Var v) (Ident.Set.elements cap) in
        let lf' = transform_fun env ~self_id:None ~has_closure:true lf in
        let base_live = Ident.Set.remove id (live_with_handlers env body) in
        let live_after =
          if can_raise body then Ident.Set.union base_live env.try_owned
          else base_live
        in
        prepare_consumed env ~borrowed_also:Ident.Set.empty ~live_after
          cap_atoms (fun remaining_owned _ ->
            let dead_before = Ident.Set.diff remaining_owned live_after in
            let owned_body =
              Ident.Set.add id (Ident.Set.diff remaining_owned dead_before)
            in
            let body' =
              transform_aexpr { env with owned = owned_body } body
            in
            emit_drops env dead_before (Let (id, Fun lf', body')))
  | Let (id, ce, body) ->
      let ce_may_raise = ce_may_raise_fn ce in
      let borrowed_in_ce, consumed_in_ce = atom_operands ce in
      let base_live_body = Ident.Set.remove id (live_with_handlers env body) in
      let live_before_ce =
        Ident.Set.union base_live_body
          (if ce_may_raise || can_raise body then env.try_owned
           else Ident.Set.empty)
      in
      let live_after = Ident.Set.union live_before_ce borrowed_in_ce in
      prepare_consumed env ~borrowed_also:borrowed_in_ce ~live_after
        consumed_in_ce (fun remaining_owned atoms' ->
          let ce' = rebuild_cexpr ce atoms' in
          let used_before =
            Ident.Set.union borrowed_in_ce live_before_ce
          in
          let dead_before = Ident.Set.diff remaining_owned used_before in
          let rem_after_before = Ident.Set.diff remaining_owned dead_before in
          let live_for_after_ce =
            Ident.Set.union base_live_body
              (if can_raise body then env.try_owned else Ident.Set.empty)
          in
          let dead_after = Ident.Set.diff rem_after_before live_for_after_ce in
          let live_for_body = Ident.Set.diff rem_after_before dead_after in
          let is_imm = is_imm_cexpr env ce' in
          let env_body =
            { env with
              owned = Ident.Set.add id live_for_body;
              imm =
                (if is_imm then Ident.Set.add id env.imm
                 else Ident.Set.remove id env.imm) }
          in
          let body' = transform_aexpr env_body body in
          let body_with_dead_after = emit_drops env dead_after body' in
          let is_pure_tail =
            match body with
            | Halt (Var v) when Ident.same id v ->
                env.try_depth = 0
                && Ident.Set.is_empty
                     (Ident.Set.diff
                        (Ident.Set.union rem_after_before env.frame_borrowed)
                        env.try_owned)
                && Ident.Set.is_empty (Ident.Set.diff env.muts env.try_muts)
                && Ident.Set.is_empty dead_after
            | _ -> false
          in
          let make_let next = Anf.Let (id, ce', next) in
          let node =
            emit_shadowed_call env ~ce:ce' ~ce_may_raise ~is_pure_tail
              ~rem_after_before ~body_cont:body_with_dead_after make_let
          in
          emit_drops env dead_before node)
  | MutLet (id, ce, body) ->
      let ce_may_raise = ce_may_raise_fn ce in
      let borrowed_in_ce, consumed_in_ce = atom_operands ce in
      let base_live_body = Ident.Set.remove id (live_with_handlers env body) in
      let live_before_ce =
        Ident.Set.union base_live_body
          (if ce_may_raise || can_raise body then env.try_owned
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
              (if can_raise body then env.try_owned else Ident.Set.empty)
          in
          let dead_after = Ident.Set.diff rem_after_before live_for_after_ce in
          let live_for_body = Ident.Set.diff rem_after_before dead_after in
          let env_body =
            { env with
              owned = live_for_body;
              muts = Ident.Set.add id env.muts }
          in
          let body' = transform_aexpr env_body body in
          let body_with_dead_after = emit_drops env dead_after body' in
          let make_let next = Anf.MutLet (id, ce', next) in
          let node =
            emit_shadowed_call env ~ce:ce' ~ce_may_raise ~is_pure_tail:false
              ~rem_after_before ~body_cont:body_with_dead_after make_let
          in
          emit_drops env dead_before node)
  | LetJoin (id, rhs, body) ->
      let base_live_body = Ident.Set.remove id (live_with_handlers env body) in
      let live_body_only =
        if can_raise body then Ident.Set.union base_live_body env.try_owned
        else base_live_body
      in
      let live_rhs =
        Ident.Set.union (live_with_handlers env rhs)
          (if can_raise rhs then env.try_owned else Ident.Set.empty)
      in
      let shared = Ident.Set.inter env.owned live_body_only in
      let owned_rhs_only = Ident.Set.diff env.owned live_body_only in
      let dead_before = Ident.Set.diff owned_rhs_only live_rhs in
      let owned_for_rhs = Ident.Set.diff owned_rhs_only dead_before in
      let env_rhs =
        { env with
          owned = owned_for_rhs;
          frame_borrowed = Ident.Set.union env.frame_borrowed shared;
          no_release_muts = env.muts }
      in
      let rhs' = transform_aexpr env_rhs rhs in
      let imm =
        if Anf.returns_raw_float rhs then Ident.Set.add id env.imm else env.imm
      in
      let env_body = { env with owned = Ident.Set.add id shared; imm } in
      let body' = transform_aexpr env_body body in
      emit_drops env dead_before (LetJoin (id, rhs', body'))
  | LetRec (bindings, body) ->
      let rec_ids =
        List.fold_left
          (fun s (rb : Anf.rec_binding) -> Ident.Set.add rb.id s)
          Ident.Set.empty bindings
      in
      let all_pure =
        List.for_all
          (fun (rb : Anf.rec_binding) -> Ident.Set.mem rb.id env.pure)
          bindings
      in
      if all_pure then
        let bindings' =
          List.map
            (fun (rb : Anf.rec_binding) ->
              { rb with
                def =
                  transform_fun env ~self_id:(Some rb.id) ~has_closure:false
                    rb.def })
            bindings
        in
        let body' = transform_aexpr env body in
        LetRec (bindings', body')
      else
        let cap_list_per_rb =
          List.map
            (fun (rb : Anf.rec_binding) ->
              Anf.free_vars rb.def.body
              |> Ident.Set.filter (fun v ->
                     not (List.exists (fun (p, _) -> Ident.same p v) rb.def.params)
                     && not (Ident.Set.mem v rec_ids)
                     && not (Ident.Set.mem v env.pure))
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
                  borrowed =
                    Ident.Set.union env.borrowed
                      (Ident.Set.union rec_ids (Ident.Set.of_list cap_outer)) }
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
          if can_raise body then Ident.Set.union base_live env.try_owned
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
              transform_aexpr { env with owned = owned_body } body
            in
            emit_drops env dead_before (LetRec (bindings', body')))
  | If (cond, th, el) ->
      let th' = transform_branch env th in
      let el' = transform_branch env el in
      If (cond, th', el')
  | FloatIf (cond, th, el) ->
      let th' = transform_branch env th in
      let el' = transform_branch env el in
      FloatIf (cond, th', el')
  | Switch (scrut, sw) ->
      let consts' = List.map (fun (k, a) -> (k, transform_branch env a)) sw.consts in
      let blocks' = List.map (fun (k, a) -> (k, transform_branch env a)) sw.blocks in
      let fail' = Option.map (transform_branch env) sw.fail in
      Switch (scrut, { consts = consts'; blocks = blocks'; fail = fail' })
  | StringSwitch (scrut, cases, fail) ->
      let cases' = List.map (fun (s, a) -> (s, transform_branch env a)) cases in
      let fail' = Option.map (transform_branch env) fail in
      StringSwitch (scrut, cases', fail')
  | StaticCatch (body, hid, binders, handler) ->
      let base_fh =
        List.fold_left
          (fun s b -> Ident.Set.remove b s)
          (live_with_handlers env handler)
          binders
      in
      let fv_handler =
        if can_raise handler then Ident.Set.union base_fh env.try_owned
        else base_fh
      in
      let handler_owned = Ident.Set.inter env.owned fv_handler in
      let handler_owned_list =
        List.fold_left
          (fun acc b -> Ident.Set.add b acc)
          handler_owned binders
      in
      Hashtbl.replace env.handlers hid (handler_owned, env.muts);
      let body' = transform_aexpr env body in
      Hashtbl.remove env.handlers hid;
      let dead_at_handler = Ident.Set.diff handler_owned fv_handler in
      let handler' =
        transform_aexpr
          { env with
            owned = Ident.Set.diff handler_owned_list dead_at_handler }
          handler
      in
      StaticCatch (body', hid, binders, emit_drops env dead_at_handler handler')
  | StaticRaise (hid, args) ->
      let target_owned, target_muts =
        match Hashtbl.find_opt env.handlers hid with
        | Some pair -> pair
        | None -> (Ident.Set.empty, env.muts)
      in
      prepare_consumed env ~borrowed_also:Ident.Set.empty
        ~live_after:target_owned args (fun remaining_owned args' ->
          let dead_vars = Ident.Set.diff remaining_owned target_owned in
          let dead_muts = Ident.Set.diff env.muts target_muts in
          emit_drops env dead_vars
            (emit_mut_releases dead_muts (StaticRaise (hid, args'))))
  | TryWith (body, exn_id, handler) ->
      let outer_needed =
        if can_raise handler then env.try_owned else Ident.Set.empty
      in
      let fv_handler =
        Ident.Set.remove exn_id
          (Ident.Set.union (live_with_handlers env handler) outer_needed)
      in
      let catch_owned = Ident.Set.inter env.owned fv_handler in
      let body_env =
        { env with
          try_owned = Ident.Set.union catch_owned env.frame_borrowed;
          try_muts = env.muts;
          try_depth = env.try_depth + 1 }
      in
      let body' = transform_aexpr body_env body in
      let handler_env =
        { env with owned = Ident.Set.add exn_id catch_owned }
      in
      let handler' = transform_aexpr handler_env handler in
      TryWith (body', exn_id, handler')
  | While (cond, body) ->
      let loop_env =
        { env with
          owned = Ident.Set.empty;
          frame_borrowed = Ident.Set.union env.frame_borrowed env.owned;
          no_release_muts = env.muts }
      in
      let cond' = transform_aexpr loop_env cond in
      let body' = transform_aexpr loop_env body in
      if Ident.Set.is_empty env.owned && Ident.Set.is_empty env.muts then
        While (cond', body')
      else
        let u = Ident.create_local "wend" in
        (* Muts in scope outlive the loop (they are released by the join
           continuation's own scope exit); only dead owned values drop here. *)
        let cont = emit_drops env env.owned (Halt (Var u)) in
        LetJoin (u, While (cond', body'), cont)
  | For (idx, s, e, dir, body) ->
      let loop_env =
        { env with
          owned = Ident.Set.empty;
          frame_borrowed = Ident.Set.union env.frame_borrowed env.owned;
          imm = Ident.Set.add idx env.imm;
          no_release_muts = env.muts }
      in
      let body' = transform_aexpr loop_env body in
      if Ident.Set.is_empty env.owned && Ident.Set.is_empty env.muts then
        For (idx, s, e, dir, body')
      else
        let u = Ident.create_local "fend" in
        let cont = emit_drops env env.owned (Halt (Var u)) in
        LetJoin (u, For (idx, s, e, dir, body'), cont)

and transform_branch (env : state) (arm : Anf.aexpr) : Anf.aexpr =
  let base_live = live_with_handlers env arm in
  let live =
    if can_raise arm then Ident.Set.union base_live env.try_owned
    else base_live
  in
  let dead = Ident.Set.diff env.owned live in
  let arm' = transform_aexpr { env with owned = Ident.Set.diff env.owned dead } arm in
  emit_drops env dead arm'

and transform_fun (env : state) ~self_id ~has_closure (lf : Anf.lfunction) :
    Anf.lfunction =
  let params_set =
    List.fold_left
      (fun s (p, _) -> Ident.Set.add p s)
      Ident.Set.empty lf.params
  in
  let free = Anf.free_vars lf.body in
  let borrowed =
    if not has_closure then env.borrowed
    else
      let captured =
        Ident.Set.filter
          (fun v ->
            not (Ident.Set.mem v params_set) && not (Ident.Set.mem v env.pure))
          free
      in
      let captured =
        match self_id with
        | Some s -> Ident.Set.add s captured
        | None -> captured
      in
      Ident.Set.union env.borrowed captured
  in
  let fn_env =
    { env with
      owned = params_set;
      borrowed;
      frame_borrowed = Ident.Set.empty;
      muts = Ident.Set.empty;
      no_release_muts = Ident.Set.empty;
      handlers = Hashtbl.create 8;
      imm = Ident.Set.diff env.imm params_set;
      try_owned = Ident.Set.empty;
      try_muts = Ident.Set.empty;
      try_depth = 0 }
  in
  let live_body = Anf.free_vars lf.body in
  let dead_params = Ident.Set.diff params_set live_body in
  let body' =
    transform_aexpr
      { fn_env with owned = Ident.Set.diff params_set dead_params }
      lf.body
  in
  { lf with body = emit_drops fn_env dead_params body' }

and rebuild_cexpr (ce : Anf.cexpr) (atoms' : Anf.atom list) : Anf.cexpr =
  match (ce, atoms') with
  | Atom _, [ a ] -> Atom a
  | MakeBlock (tag, _), args -> MakeBlock (tag, args)
  | AllocReuse (tok, tag, _), args -> AllocReuse (tok, tag, args)
  | MakeArray (kind, _), args -> MakeArray (kind, args)
  | SetField (i, arg, _), [ rhs ] -> SetField (i, arg, rhs)
  | ArraySet (s, k, arr, idx, _), [ v ] -> ArraySet (s, k, arr, idx, v)
  | MakeArrayInit (len, _), [ init ] -> MakeArrayInit (len, init)
  | App (fn, _), args -> App (fn, args)
  | Assign (id, _), [ rhs ] -> Assign (id, rhs)
  | _ -> ce

let run (prog : Anf.program) : Anf.program =
  let pure =
    Anf.pure_defs prog.code |> List.map fst |> Ident.Set.of_list
  in
  let known_funs, yielding_funs = compute_yield_info prog.code in
  let init_env =
    { owned = Ident.Set.empty;
      borrowed = Ident.Set.empty;
      frame_borrowed = Ident.Set.empty;
      imm = Ident.Set.empty;
      pure;
      known_funs;
      yielding_funs;
      muts = Ident.Set.empty;
      no_release_muts = Ident.Set.empty;
      handlers = Hashtbl.create 8;
      try_owned = Ident.Set.empty;
      try_muts = Ident.Set.empty;
      try_depth = 0 }
  in
  { prog with code = transform_aexpr init_env prog.code }
