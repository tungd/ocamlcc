(* Local borrowed views and reconstruction of ownership continuations. *)

open Arc_analysis

let can_borrow_arguments ~is_immediate ~is_borrowed live flags args =
  let valid borrow a =
    not borrow || is_immediate a
    || match a with
       | Anf.Var id ->
           is_borrowed id || Ident.Set.mem id live
       | MutVar _ | BorrowedField _ -> true
       | _ -> false
  in
  List.compare_lengths flags args = 0 && List.for_all2 valid flags args

(* Fuse a field into borrowed operands while keeping its receiver live.
   A mutable projection has a single consumer and can cross only read-only
   computations, such as the arithmetic and joins used to form an index. *)
let fuse_field_read ~can_borrow ~borrowed_flags ~yielding ~stable id index owner body =
  let open Anf in
  let uses atom = Ident.Set.mem id (atom_vars atom) in
  let live expr = Ident.Set.mem id (Anf.free_vars expr) in
  let rec substitute = function
    | Var v when Ident.same v id -> BorrowedField (index, owner)
    | BorrowedField (i, base) -> BorrowedField (i, substitute base)
    | atom -> atom
  in
  let scalar = function
    | Boxed_scalar a -> Boxed_scalar (substitute a)
    | Raw_scalar _ as v -> v in
  let through_call live flags args rebuild =
    if List.compare_lengths flags args <> 0 then None
    else
      let args = List.map2 (fun borrow arg -> if borrow then substitute arg else arg) flags args in
      if can_borrow live flags args then Some (rebuild args) else None
  in
  let reader next ce =
    (* The callee can run finalizers or mutate through aliases. Across the
       call, only a projection from a stable, directly owned base can lend
       its owner. A nested receiver may itself come from a mutable field. *)
    let stable_receiver = stable && match owner with Var _ -> true | _ -> false in
    match ce with
    | App ((Var fn as callee), args)
      when stable_receiver && not (Ident.Set.mem fn yielding) ->
        Option.bind (borrowed_flags fn) (fun flags ->
          through_call (Anf.free_vars next) flags args (fun args -> App (callee, args)))
    | DirectApp (({ borrowed_entry = Some (_, flags); yields = false; _ } as target), args)
      when stable_receiver ->
        through_call (Anf.free_vars next) flags args (fun args -> DirectApp (target, args))
    | FloatBinop (op, a, b) -> Some (FloatBinop (op, scalar a, scalar b))
    | FloatCompare (op, a, b) -> Some (FloatCompare (op, scalar a, scalar b))
    | Field (i, kind, base) -> Some (Field (i, kind, substitute base))
    | FloatField (i, base) -> Some (FloatField (i, substitute base))
    | Unop (((String_length | Array_length | Isint | Int_of_float) as op), base) ->
        Some (Unop (op, substitute base))
    | Binop ((Cmp _ as op), a, b) ->
        Some (Binop (op, substitute a, substitute b))
    | ArrayGet (safe, kind, arr, i) ->
        Some (ArrayGet (safe, kind, substitute arr, i))
    | ArraySet (safe, kind, arr, i, v) ->
        Some (ArraySet (safe, kind, substitute arr, substitute i, v))
    | StringGet (safe, str, i) -> Some (StringGet (safe, substitute str, i))
    | BytesGetN (safe, width, str, i) ->
        Some (BytesGetN (safe, width, substitute str, i))
    | BytesSet (safe, str, i, v) ->
        Some (BytesSet (safe, substitute str, substitute i, v))
    | BytesSetN (safe, str, i, word) ->
        Some (BytesSetN (safe, substitute str, substitute i, word))
    | _ -> None
  in
  let can_cross = function
    | Atom _ | Field _
    | Binop ((Add | Sub | Mul | And | Or | Xor | Lsl | Lsr | Asr | Cmp _), _, _)
    | Unop ((String_length | Array_length | Isint), _)
    | ArrayGet (false, (Lambda.Pintarray | Lambda.Paddrarray), _, _)
    | StringGet (false, _, _) -> true
    | _ -> false
  in
  let can_delay_snapshot = function
    | Atom (Var _ | Int _ | Char _ | Unit)
    | Unop (Isint, _)
    | Field (_, (Immediate_field | Immutable_field), _)
    | Binop ((Add | Sub | Mul | And | Or | Xor | Lsl | Lsr | Asr | Cmp _), _, _) -> true
    | _ -> false
  in
  let rec index_expression = function
    | Halt _ -> true
    | Let (_, ce, next) -> can_delay_snapshot ce && index_expression next
    | If (_, yes, no) | LetJoin (_, yes, no) ->
        index_expression yes && index_expression no
    | _ -> false
  in
  let use_in ce =
    let borrowed, consumed = atom_operands ce in
    Ident.Set.mem id borrowed || List.exists uses consumed
  in
  let switch_read scrut arms fail =
    uses scrut
    && not (List.exists (fun (_, arm) -> live arm) arms)
    && not (Option.fold ~none:false ~some:live fail)
  in
  let rec fuse = function
    | Let (result, ce, next) when use_in ce -> (
        match reader next ce with
        | Some ce' when not (use_in ce') ->
            let next =
              if not (live next) then Some next
              else if (if stable then can_cross ce else can_delay_snapshot ce) then fuse next
              else None
            in
            Option.map (fun next -> Let (result, ce', next)) next
        | _ -> None)
    | Let (result, ce, next) when (if stable then can_cross ce else can_delay_snapshot ce) ->
        Option.map (fun next -> Let (result, ce, next)) (fuse next)
    | LetJoin (result, rhs, next) when not (live next) ->
        Option.map (fun rhs -> LetJoin (result, rhs, next)) (fuse rhs)
    | LetJoin (result, rhs, next) when not stable && index_expression rhs && not (live rhs) ->
        Option.map (fun next -> LetJoin (result, rhs, next)) (fuse next)
    | If (cond, yes, no) when uses cond && not (live yes || live no) ->
        Some (If (substitute cond, yes, no))
    | If (cond, yes, no) when not stable ->
        (* A constructor test can lead to a payload read on either edge.
           Each path must preserve the field until its last projected use. *)
        let arm expr = if live expr then fuse expr else Some expr in
        (match arm yes, arm no with
         | Some yes, Some no -> Some (If (substitute cond, yes, no))
         | _ -> None)
    | ScalarIf (rep, cond, yes, no) when uses cond && not (live yes || live no) ->
        Some (ScalarIf (rep, substitute cond, yes, no))
    | Switch (scrut, sw)
      when switch_read scrut (sw.consts @ sw.blocks) sw.fail ->
        Some (Switch (substitute scrut, sw))
    | StringSwitch (scrut, arms, fail) when switch_read scrut arms fail ->
        Some (StringSwitch (substitute scrut, arms, fail))
    | _ -> None
  in
  fuse body

(* A view may read or update the object reached through an immutable
   projection. It cannot transfer the pointer or expose it to a closure or
   call with an unknown ownership convention. *)
let field_is_read_only_in_loop id body =
  let open Anf in
  let uses a = Ident.Set.mem id (atom_vars a) in
  let closure_uses lf = Ident.Set.mem id (Anf.free_vars lf.body) in
  let read_in_loop = ref false in
  let note inside used = if inside && used then read_in_loop := true in
  let safe_ce inside ce =
    let read, take = atom_operands ce in
    let reads_view = Ident.Set.mem id read in
    note inside reads_view;
    not (List.exists uses take)
    && match ce with
       | Fun lf -> not (closure_uses lf)
       | App _ | DirectApp _ | Ccall _ | NativeCcall _ -> not reads_view
       | _ -> true
  in
  let rec scan inside = function
    | Halt a | Raise a -> not (uses a)
    | HaltScalar _ | Unwind -> true
    | StaticRaise (_, args) -> not (List.exists uses args)
    | Let (_, ce, body) | MutLet (_, ce, body) -> safe_ce inside ce && scan inside body
    | LetRec (defs, body) ->
        List.for_all (fun (rb : Anf.rec_binding) -> not (closure_uses rb.def)) defs
        && scan inside body
    | LetJoin (_, a, b) | TryWith (a, _, b) | StaticCatch (a, _, _, b, _) ->
        scan inside a && scan inside b
    | If (cond, yes, no) | ScalarIf (_, cond, yes, no) ->
        note inside (uses cond);
        scan inside yes && scan inside no
    | While (cond, body) -> scan true cond && scan true body
    | For (_, lo, hi, _, body) ->
        note inside (uses lo || uses hi);
        scan true body
    | Switch (scrut, sw) ->
        note inside (uses scrut);
        cases inside sw.consts sw.fail && cases inside sw.blocks None
    | StringSwitch (scrut, arms, fail) ->
        note inside (uses scrut);
        cases inside arms fail
    | _ -> false
  and cases : 'a. bool -> ('a * aexpr) list -> aexpr option -> bool =
    fun inside arms fail ->
      List.for_all (fun (_, arm) -> scan inside arm) arms
      && Option.fold ~none:true ~some:(scan inside) fail
  in
  scan false body && !read_in_loop

(* A snapshot can share the slot's owner if every use precedes a possible
   overwrite on its path. A loop may revisit a read after any of its writes. *)
let read_only_slot_snapshot slot id body =
  let open Anf in
  let uses atom = Ident.Set.mem id (atom_vars atom) in
  let no_access = Some (false, false) in
  let merge ~ordered a b =
    match a, b with
    | Some (read_a, write_a), Some (read_b, write_b)
      when not (ordered && write_a && read_b) ->
        Some (read_a || read_b, write_a || write_b)
    | _ -> None
  in
  let sequence = merge ~ordered:true and alternate = merge ~ordered:false in
  let operation ce =
    let borrowed, consumed = atom_operands ce in
    if List.exists uses consumed then None
    else
      match ce with
      | Fun lf when Ident.Set.mem id (Anf.free_vars lf.body) -> None
      | Assign (target, _) | AssignImm (target, _) | AssignScalar (target, _, _) ->
          Some (Ident.Set.mem id borrowed, Ident.same target slot)
      | _ -> Some (Ident.Set.mem id borrowed, false)
  in
  let reads atom = Some (uses atom, false) in
  let repeated = function Some (true, true) -> None | access -> access in
  let rec scan = function
    | Halt a | Raise a -> if uses a then None else no_access
    | StaticRaise (_, args) -> if List.exists uses args then None else no_access
    | HaltScalar _ | Unwind -> no_access
    | Let (_, ce, body) | MutLet (_, ce, body) -> sequence (operation ce) (scan body)
    | LetJoin (_, a, b) | TryWith (a, _, b) | StaticCatch (a, _, _, b, _) ->
        sequence (scan a) (scan b)
    | LetRec (defs, body) ->
        if List.exists (fun (rb : rec_binding) -> Ident.Set.mem id (free_vars rb.def.body)) defs
        then None else scan body
    | If (cond, yes, no) | ScalarIf (_, cond, yes, no) ->
        sequence (reads cond) (alternate (scan yes) (scan no))
    | While (cond, body) -> repeated (sequence (scan cond) (scan body))
    | For (_, lo, hi, _, body) ->
        sequence (Some (uses lo || uses hi, false)) (repeated (scan body))
    | Switch (scrutinee, sw) ->
        sequence (reads scrutinee) (alternate (cases sw.consts sw.fail) (cases sw.blocks None))
    | StringSwitch (scrutinee, arms, fail) ->
        sequence (reads scrutinee) (cases arms fail)
    | _ -> None
  and cases : 'a. ('a * aexpr) list -> aexpr option -> (bool * bool) option =
    fun arms fail ->
      List.fold_left (fun acc (_, arm) -> alternate acc (scan arm))
        (Option.fold ~none:no_access ~some:scan fail) arms
  in
  Option.is_some (scan body)

(* Every branch must leave the result owned by the same slot. A lazy option
   can also establish ownership of the result through its immutable payload. *)
let mutable_slot_result snapshots body =
  let open Anf in
  let read_slot snapshots = function
    | MutVar slot -> Some slot
    | Var value -> Ident.Map.find_opt value snapshots
    | _ -> None in
  let keep construct = Option.map (fun (slot, field, body) -> slot, field, construct body) in
  let rec scan snapshots = function
    | Halt value -> Option.map (fun slot -> slot, None, Halt Unit) (read_slot snapshots value)
    | Let (id, (Assign (slot, Var value) as assign), Halt (Var result))
      when Ident.same value result ->
        Some (slot, None, Let (id, assign, Halt Unit))
    | Let (box, (MakeBlock (0, _, [Var value]) as make),
        Let (id, (Assign (slot, Var stored) as assign), Halt (Var result)))
      when Ident.same box stored && Ident.same value result ->
        Some (slot, Some 0, Let (box, make, Let (id, assign, Halt Unit)))
    | Let (id, Field (0, Immutable_field, owner), Halt (Var result))
      when Ident.same id result ->
        Option.map (fun slot -> slot, Some 0, Halt Unit) (read_slot snapshots owner)
    | Let (id, ce, body) ->
        let snapshots =
          match ce with
          | Atom value -> Option.fold ~none:snapshots
              ~some:(fun slot -> Ident.Map.add id slot snapshots) (read_slot snapshots value)
          | Assign (slot, _) | AssignImm (slot, _) | AssignScalar (slot, _, _) ->
              Ident.Map.filter (fun _ owner -> not (Ident.same owner slot)) snapshots
          | _ -> snapshots in
        keep (fun body -> Let (id, ce, body)) (scan snapshots body)
    | LetJoin (id, rhs, body) ->
        keep (fun body -> LetJoin (id, rhs, body)) (scan Ident.Map.empty body)
    | If (cond, yes, no) ->
        (match scan snapshots yes, scan snapshots no with
         | Some (slot, field, yes), Some (other, other_field, no)
           when Ident.same slot other && field = other_field ->
             Some (slot, field, If (cond, yes, no))
         | _ -> None)
    | _ -> None
  in
  scan snapshots body

(* Each live reuse token is shadowed until the protected call returns.
   Already-inserted token cleanups may wrap the same error-side pop. *)
let rec add_reuse_to_pop = function
  | Anf.ShadowPop (nv, nr, body) -> Some (Anf.ShadowPop (nv, nr + 1, body))
  | FreeReuse (tok, body) ->
      Option.map (fun body -> Anf.FreeReuse (tok, body)) (add_reuse_to_pop body)
  | _ -> None

let rec rewrite_reuse ?(in_shadow = false) (tok : Ident.t) (e : Anf.aexpr) :
    Anf.aexpr option =
  match e with
  | Let (res, MakeBlock (tag, scan, (_ :: _ as args)), next) when not in_shadow ->
      Some (Let (res, AllocReuse ({ primary = tok; fallback = None }, tag, scan, args), next))
  | Let (res, (AllocReuse (reuse, tag, scan, args) as ce), next) -> (
      match rewrite_reuse ~in_shadow tok next with
      | Some next -> Some (Let (res, ce, next))
      | None when not in_shadow && Option.is_none reuse.fallback ->
          Some (Let (res, AllocReuse ({ reuse with fallback = Some tok }, tag, scan, args), next))
      | None -> None)
  | Let (x, ((Atom _ | Binop _ | IntSelect _ | Unop _ | Field _ | SetField _
             | FloatField _ | SetFloatField _ | SetBoxedFloatField _ | OffsetRef _
             | StringGet _ | BytesSet _ | BytesGetN _ | BytesSetN _ | Bswap16 _ | BswapBint _ | ArrayGet _ | ArraySet _
             | CreateBytes _ | MakeArrayInit _ | MakeArray _ | App _ | DirectApp _
             | IntegerOfInt _ | IntOfInteger _ | IntegerConvert _
             | FloatArrayGet _ | FloatArraySet _ | FloatSign _ | FloatCompare _
             | FloatOfInt _ | IntOfFloat _ | BoxScalar _
             | ScalarLoad _ | ScalarStore _ | ScalarValue _ | FloatBinop _ | IntegerBinop _ | IntegerCompare _ | IntegerNeg _ | IntegerShift _
             | Builtin _ | BigarrayAccess _ | Ccall _ | NativeCcall _ | GetGlobal _ | Assign _ | AssignImm _
             | ReadScalarSlot _ | AssignScalar _
             | MakeBlock (_, _, [])) as ce), body) -> (
      match rewrite_reuse ~in_shadow tok body with
      | Some body' -> Some (Let (x, ce, body'))
      | None -> None)
  | CheckExn (exception_kind, on_err, on_ok) ->
      let on_err = if in_shadow then add_reuse_to_pop on_err else Some on_err in
      Option.bind on_err (fun on_err ->
          Option.map
            (fun on_ok -> Anf.CheckExn (exception_kind, FreeReuse (tok, on_err), on_ok))
            (rewrite_reuse ~in_shadow tok on_ok))
  | LetJoin (id, rhs, body) when not in_shadow ->
      Option.map (fun rhs -> Anf.LetJoin (id, rhs, body)) (rewrite_reuse tok rhs)
  | DropReuse (v, prior, body) ->
      Option.map (fun body -> Anf.DropReuse (v, prior, body)) (rewrite_reuse ~in_shadow tok body)
  | FreeReuse (prior, body) ->
      Option.map (fun body -> Anf.FreeReuse (prior, body)) (rewrite_reuse ~in_shadow tok body)
  | Retain (x, body) -> (
      match rewrite_reuse ~in_shadow tok body with
      | Some body' -> Some (Retain (x, body'))
      | None -> None)
  | Release (x, body) -> (
      match rewrite_reuse ~in_shadow tok body with
      | Some body' -> Some (Release (x, body'))
      | None -> None)
  | ReleaseMut (x, body) -> (
      match rewrite_reuse ~in_shadow tok body with
      | Some body' -> Some (ReleaseMut (x, body'))
      | None -> None)
  | ShadowPush (vs, ms, rtoks, body) when not in_shadow -> (
      match rewrite_reuse ~in_shadow:true tok body with
      | Some body' -> Some (ShadowPush (vs, ms, tok :: rtoks, body'))
      | None -> None)
  | ShadowPop (nv, nr, body) -> (
      match rewrite_reuse ~in_shadow:false tok body with
      | Some body' ->
          let nr' = if in_shadow then nr + 1 else nr in
          Some (ShadowPop (nv, nr', body'))
      | None -> None)
  | If (c, th, el) when not in_shadow -> (
      match
        (rewrite_reuse ~in_shadow tok th, rewrite_reuse ~in_shadow tok el)
      with
      | Some th', Some el' -> Some (If (c, th', el'))
      | Some th', None -> Some (If (c, th', FreeReuse (tok, el)))
      | None, Some el' -> Some (If (c, FreeReuse (tok, th), el'))
      | None, None -> None)
  | _ -> None

let inject_reuse token body = rewrite_reuse token body
