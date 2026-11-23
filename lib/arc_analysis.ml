(* Immutable ownership and effect facts shared by ARC transformations. *)

let atom_is_imm ~pure imm (a : Anf.atom) =
  match a with
  | Int _ | Char _ | Unit | String _ | Float _ | Int32 _ | Int64 _
  | Nativeint _ | ConstFloatArray _ | ConstBlock _ ->
      true
  | Var id -> Ident.Set.mem id imm || Ident.Set.mem id pure
  | MutVar id -> Ident.Set.mem id imm
  | ModuleSlot (_, kind) -> kind = Lambda.Pintval
  | BorrowedField _ -> false

let is_imm_binop : Anf.binop -> bool = function
  | Add | Sub | Mul | Div | Mod | And | Or | Xor | Lsl | Lsr | Asr | Cmp _
  | Compare_ints | Isout | Fcmp _ | Compare_floats | Bint_cmp _
  | Compare_bints _ ->
      true
  | Float_arithmetic _ | Bint_arith _ | Bint_shift _ ->
      false

let is_imm_unop : Anf.unop -> bool = function
  | Neg | Not | Offset _ | Isint | String_length | Array_length
  | Int_of_float | Int_of_bint _ ->
      true
  | Float_of_int | Fneg | Fabs | Bint_of_int _ | Bint_cvt _ | Bint_neg _ ->
      false

let cexpr_is_imm ~pure ~imm_funs imm (ce : Anf.cexpr) =
  match ce with
  | Atom a -> atom_is_imm ~pure imm a
  | Binop (op, _, _) -> is_imm_binop op
  | Unop (op, _) -> is_imm_unop op
  | IntSelect _ | Field (_, Immediate_field, _) | ArrayGet (_, Lambda.Pintarray, _, _)
  | SetField _ | FloatField _ | SetFloatField _ | SetBoxedFloatField _ | OffsetRef _ | StringGet _
  | BytesSet _ | BytesSetN _ | Bswap16 _ | ArraySet _ | Builtin _ | Assign _ | AssignImm _
  | ReadScalarSlot _ | AssignScalar _ | StoreModuleSlot _ | ImportDependency _ ->
      true
  | BytesGetN (_, (Uint16 | Raw_word _), _, _) -> true
  | BytesGetN (_, Boxed_word _, _, _) | BswapBint _ -> false
  | IntegerOfInt _ | IntOfInteger _ | IntegerConvert _
  | FloatArrayGet _ | FloatArraySet _ | FloatOfInt _ | IntOfFloat _
  | FloatSign _ | FloatCompare _ | KeepAlive _ -> true
  | MakeBlock (_, _, []) | ScalarLoad _ | ScalarValue _ | FloatBinop _ | IntegerBinop _ | IntegerCompare _ | IntegerNeg _ | IntegerShift _ | ScalarStore _ -> true
  | PollFinalizers | LoopPollDue _ -> true
  | Ccall (name, _) -> Ccalls.returns_imm name
  | NativeCcall (prim, _) ->
      not (Primitive.equal_native_repr prim.prim_native_repr_res Same_as_ocaml_repr)
  | DirectApp (target, _) -> target.returns_immediate
  | App (Var fn, args) -> (
      match Ident.Map.find_opt fn imm_funs with
      | Some arity -> List.length args = arity
      | None -> false)
  | MakeBlock _ | AllocReuse _ | MakeArray _ | Field _ | BoxScalar _
  | BigarrayAccess _ | ArrayGet _ | CreateBytes _ | MakeArrayInit _ | App _
  | GetGlobal _ | Fun _ | Recur _ ->
      false

let imm_params_of (lf : Anf.lfunction) : Ident.Set.t =
  List.fold_left
    (fun s (p, vk) ->
      match vk with Lambda.Pintval -> Ident.Set.add p s | _ -> s)
    (Ident.Set.of_list (List.map fst lf.loop_scalars)) lf.params

let set_imm imm id proven =
  if proven then Ident.Set.add id imm else Ident.Set.remove id imm

(* Static catches consume local exits in their body. Track each argument
   independently, intersecting the facts supplied by all incoming exits. *)
let observe_exit imm_args args =
  let incoming = List.map imm_args args in
  function
  | None -> Some incoming
  | Some previous when List.length previous = List.length incoming ->
      Some (List.map2 ( && ) previous incoming)
  | Some _ -> Some []

let binders_imm typed_imm binders observed =
  let typed = Ident.Set.inter typed_imm (Ident.Set.of_list binders) in
  match observed with
  | Some kinds when List.length kinds = List.length binders ->
      List.fold_left2
        (fun imm id inferred -> if inferred then Ident.Set.add id imm else imm)
        typed binders kinds
  | _ -> typed

(* A mutable slot can use the immediate convention for its whole scope
   only if every write is immediate and the slot is local to this frame. *)
let scan_immediates ~typed_imm ~pure ~imm_funs ?(exits = []) ?mutable_slot imm e =
  let ce_imm = cexpr_is_imm ~pure ~imm_funs in
  let bind imm id inferred = set_imm imm id (inferred || Ident.Set.mem id typed_imm) in
  let check_closure (lf : Anf.lfunction) =
    Option.iter
      (fun (slot, valid) ->
        if Ident.Set.mem slot (Anf.free_vars lf.body) then valid := false)
      mutable_slot
  in
  let observe_binding imm = function
    | Anf.Assign (slot, rhs) | AssignImm (slot, rhs) ->
        Option.iter
          (fun (watched, valid) ->
            if Ident.same slot watched && not (atom_is_imm ~pure imm rhs)
            then valid := false)
          mutable_slot
    | Fun lf -> check_closure lf
    | _ -> ()
  in
  let rec scan exits imm = function
    | Anf.Halt a -> atom_is_imm ~pure imm a
    | HaltScalar _ | Raise _ | Unwind -> true
    | StaticRaise (hid, args) ->
        Option.iter
          (fun observed -> observed := observe_exit (atom_is_imm ~pure imm) args !observed)
          (List.assoc_opt hid exits);
        true
    | Let (id, ce, body) ->
        observe_binding imm ce;
        scan exits (bind imm id (ce_imm imm ce)) body
    | MutLet (id, ce, body) ->
        observe_binding imm ce;
        scan exits (bind imm id false) body
    | LetJoin (id, rhs, body) ->
        let immediate = scan exits imm rhs in
        scan exits (bind imm id immediate) body
    | If (_, a, b) | ScalarIf (_, _, a, b) | CheckExn (_, a, b) ->
        let immediate = scan exits imm a in
        scan exits imm b && immediate
    | TryWith (a, exn, b) ->
        let immediate = scan exits imm a in
        scan exits (Ident.Set.remove exn imm) b && immediate
    | StaticCatch (body, hid, binders, handler, _) ->
        let observed = ref None in
        let immediate = scan ((hid, observed) :: exits) imm body in
        let handler_imm =
          Ident.Set.union
            (Ident.Set.diff imm (Ident.Set.of_list binders))
            (binders_imm typed_imm binders !observed)
        in
        scan exits handler_imm handler && immediate
    | Switch (_, sw) -> scan_arms exits imm (sw.consts @ sw.blocks) sw.fail
    | StringSwitch (_, cases, fail) -> scan_arms exits imm cases fail
    | While (cond, body) ->
        ignore (scan exits imm cond);
        ignore (scan exits imm body);
        true
    | For (idx, _, _, _, body) ->
        ignore (scan exits (Ident.Set.add idx imm) body);
        true
    | LetRec (bindings, body) ->
        List.iter (fun (rb : Anf.rec_binding) -> check_closure rb.def) bindings;
        scan exits imm body
    | Retain (_, body) | Release (_, body) | ReleaseMut (_, body)
    | DropReuse (_, _, body) | FreeReuse (_, body)
    | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
        scan exits imm body
  and scan_arms : 'a. _ -> _ -> ('a * Anf.aexpr) list -> _ -> bool =
    fun exits imm arms fail ->
      let immediate =
        List.fold_left (fun acc (_, arm) -> scan exits imm arm && acc) true arms
      in
      Option.fold ~none:true ~some:(scan exits imm) fail && immediate
  in
  scan exits imm e

let aexpr_returns_imm ~typed_imm ~pure ~imm_funs imm e =
  scan_immediates ~typed_imm ~pure ~imm_funs imm e

let handler_immediates ~typed_imm ~pure ~imm_funs imm hid binders body =
  match binders with
  | [] -> Ident.Set.empty
  | _ ->
      let observed = ref None in
      ignore (scan_immediates ~typed_imm ~pure ~imm_funs
                ~exits:[hid, observed] imm body);
      binders_imm typed_imm binders !observed

let mutlet_is_imm ~typed_imm ~pure ~imm_funs imm slot init body =
  if Ident.Set.mem slot typed_imm then true
  else if not (cexpr_is_imm ~pure ~imm_funs imm init) then false
  else
    let valid = ref true in
    ignore (scan_immediates ~typed_imm ~pure ~imm_funs
              ~mutable_slot:(slot, valid) (Ident.Set.add slot imm) body);
    !valid

let compute_imm_funs ~typed_imm ~pure (e : Anf.aexpr) : int Ident.Map.t =
  let funs = ref [] in
  let rec collect = function
    | Anf.Let (id, Fun lf, body) ->
        funs := (id, lf) :: !funs;
        collect lf.body;
        collect body
    | Let (_, _, body) | MutLet (_, _, body) -> collect body
    | LetRec (rbs, body) ->
        List.iter
          (fun (rb : Anf.rec_binding) ->
            funs := (rb.id, rb.def) :: !funs;
            collect rb.def.body)
          rbs;
        collect body
    | LetJoin (_, a, b) | If (_, a, b) | ScalarIf (_, _, a, b)
    | CheckExn (_, a, b) | While (a, b) | StaticCatch (a, _, _, b, _)
    | TryWith (a, _, b) ->
        collect a;
        collect b
    | For (_, _, _, _, body) | Retain (_, body) | Release (_, body)
    | ReleaseMut (_, body) | DropReuse (_, _, body) | FreeReuse (_, body)
    | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
        collect body
    | Switch (_, sw) ->
        List.iter (fun (_, arm) -> collect arm) sw.consts;
        List.iter (fun (_, arm) -> collect arm) sw.blocks;
        Option.iter collect sw.fail
    | StringSwitch (_, cases, fail) ->
        List.iter (fun (_, arm) -> collect arm) cases;
        Option.iter collect fail
    | Halt _ | HaltScalar _ | StaticRaise _ | Raise _ | Unwind -> ()
  in
  collect e;
  let rec fix imm_funs =
    let next, changed =
      List.fold_left
        (fun (acc, ch) (id, (lf : Anf.lfunction)) ->
          if Ident.Map.mem id acc then (acc, ch)
          else if lf.return = Lambda.Pintval
                  || aexpr_returns_imm ~typed_imm ~pure ~imm_funs (imm_params_of lf) lf.body
          then (Ident.Map.add id (List.length lf.params) acc, true)
          else (acc, ch))
        (imm_funs, false) !funs
    in
    if changed then fix next else next
  in
  fix Ident.Map.empty

let rec atom_vars (a : Anf.atom) : Ident.Set.t =
  match a with
  | Var id | MutVar id -> Ident.Set.singleton id
  | BorrowedField (_, owner) -> atom_vars owner
  | Int _ | Char _ | String _ | Float _ | Int32 _ | Int64 _ | Nativeint _
  | ConstFloatArray _ | ConstBlock _ | Unit | ModuleSlot _ ->
      Ident.Set.empty

let atoms_vars (xs : Anf.atom list) : Ident.Set.t =
  List.fold_left (fun s a -> Ident.Set.union s (atom_vars a)) Ident.Set.empty xs

let split_borrowed flags args =
  List.combine flags args
  |> List.partition_map (function true, a -> Either.Left a | false, a -> Either.Right a)

let atom_operands (ce : Anf.cexpr) : Ident.Set.t * Anf.atom list =
  match ce with
  | Atom a -> (Ident.Set.empty, [ a ])
  | Binop (_, a, b) | IntSelect (_, a, b) | LoopPollDue (a, b) ->
      (Ident.Set.union (atom_vars a) (atom_vars b), [])
  | Unop (_, a) -> (atom_vars a, [])
  | MakeBlock (_, _, args) | AllocReuse (_, _, _, args) | MakeArray (_, args) ->
      (Ident.Set.empty, args)
  | Field (_, _, a) | FloatField (_, a) | OffsetRef (_, a) | CreateBytes a
  | Bswap16 a | BswapBint (_, a) ->
      (atom_vars a, [])
  | SetField (_, Lambda.Pointer, a, rhs) -> (atom_vars a, [ rhs ])
  | SetField (_, Immediate, a, rhs) -> (Ident.Set.union (atom_vars a) (atom_vars rhs), [])
  | SetFloatField (_, owner, v) | SetBoxedFloatField (_, owner, v) ->
      (Anf.scalar_operand_vars (atom_vars owner) v, [])
  | StringGet (_, a, b) | BytesGetN (_, _, a, b) | ArrayGet (_, _, a, b) ->
      (Ident.Set.union (atom_vars a) (atom_vars b), [])
  | BytesSet (_, a, b, c) ->
      ( Ident.Set.union (atom_vars a) (Ident.Set.union (atom_vars b) (atom_vars c)),
        [] )
  | BytesSetN (_, bytes, index, word) ->
      (Anf.byte_store_vars (Ident.Set.union (atom_vars bytes) (atom_vars index)) word, [])
  | ArraySet (_, _, arr, idx, v) ->
      (Ident.Set.union (atom_vars arr) (atom_vars idx), [ v ])
  | MakeArrayInit (len, init) -> (atom_vars len, [ init ])
  | App (fn, args) -> (atom_vars fn, args)
  | DirectApp ({ borrowed_entry = Some (_, flags); _ }, args) ->
      let borrowed, consumed = split_borrowed flags args in
      (atoms_vars borrowed, consumed)
  | DirectApp (_, args) | Recur args -> (Ident.Set.empty, args)
  | KeepAlive args -> (atoms_vars args, [])
  | Builtin (_, _, a) -> (atom_vars a, [])
  | ScalarValue (_, a) | BoxScalar (_, a) | IntOfFloat a | FloatSign (_, a) ->
      (Anf.scalar_operand_vars Ident.Set.empty a, [])
  | FloatOfInt a -> (atom_vars a, [])
  | IntegerOfInt (_, value) -> (atom_vars value, [])
  | IntOfInteger (_, value) | IntegerConvert (_, _, value)
  | IntegerNeg (_, value) -> (Anf.scalar_operand_vars Ident.Set.empty value, [])
  | IntegerShift (_, _, value, count) ->
      (Anf.scalar_operand_vars (atom_vars count) value, [])
  | FloatArrayGet (_, a, i) | ScalarLoad (_, a, i) -> (atoms_vars [a; i], [])
  | FloatArraySet (_, a, i, v) | ScalarStore (_, a, i, v) -> (Anf.scalar_operand_vars (atoms_vars [a; i]) v, [])
  | FloatBinop (_, a, b) | FloatCompare (_, a, b) | IntegerBinop (_, _, a, b) | IntegerCompare (_, _, a, b) -> (Anf.scalar_operand_vars (Anf.scalar_operand_vars Ident.Set.empty a) b, [])
  | BigarrayAccess (_, args) | Ccall (_, args) | NativeCcall (_, args) -> (atoms_vars args, [])
  | GetGlobal _ | ImportDependency _ | PollFinalizers -> (Ident.Set.empty, [])
  | StoreModuleSlot (_, a) -> (Ident.Set.empty, [ a ])
  | Assign (_, rhs) | AssignImm (_, rhs) -> (Ident.Set.empty, [ rhs ])
  | ReadScalarSlot (_, slot) -> (Ident.Set.singleton slot, [])
  | AssignScalar (slot, _, value) ->
      (Anf.scalar_operand_vars (Ident.Set.singleton slot) value, [])
  | Fun _ -> (Ident.Set.empty, [])

let pointer_parameters (lf : Anf.lfunction) =
  if lf.loop_scalars <> [] then Ident.Set.empty else
  List.fold_left
    (fun set (id, kind) ->
      if kind = Lambda.Pintval then set else Ident.Set.add id set)
    Ident.Set.empty lf.params

let borrow_flags (lf : Anf.lfunction) read_only =
  List.map (fun (param, _) -> Ident.Set.mem param read_only) lf.params

(* A private entry may borrow parameters read locally or forwarded to other
   borrowed arguments. Capturing a parameter makes the closure an owner. *)
let read_only_parameters ~borrowed (lf : Anf.lfunction) =
  let remove_uses params args = Ident.Set.diff params (atoms_vars args) in
  let cexpr params = function
    | Anf.App (Var fn, args) ->
        let params = Ident.Set.remove fn params in
        (match borrowed fn with
         | Some flags when List.length flags = List.length args ->
             List.fold_left2
               (fun params borrows arg ->
                 if borrows then params else Ident.Set.diff params (atom_vars arg))
               params flags args
         | _ -> remove_uses params args)
    | App (fn, args) -> remove_uses params (fn :: args)
    | Ccall _ | NativeCcall _ -> params
    | Fun lf -> Ident.Set.diff params (Anf.free_vars lf.body)
    | (SetField (_, Lambda.Pointer, target, _)
      | SetBoxedFloatField (_, target, _)
      | ArraySet (_, (Lambda.Paddrarray | Lambda.Pgenarray), target, _, _)) as ce ->
        let remaining = remove_uses params (snd (atom_operands ce)) in
        (* The caller keeps a sole borrowed parameter alive. With multiple
           borrowed parameters, an overwrite may retire a sibling's owner. *)
        if Ident.Set.cardinal remaining <= 1 then remaining
        else Ident.Set.inter remaining (atom_vars target)
    | ce -> remove_uses params (snd (atom_operands ce))
  in
  let rec scan params expr =
    if Ident.Set.is_empty params then params
    else
      match expr with
      | Anf.Let (_, ce, body) | MutLet (_, ce, body) -> scan (cexpr params ce) body
      | LetRec (defs, body) ->
          let uncaptured = List.fold_left (fun params (rb : Anf.rec_binding) ->
            Ident.Set.diff params (Anf.free_vars rb.def.body)) params defs in
          scan uncaptured body
      | LetJoin (_, a, b) | If (_, a, b) | ScalarIf (_, _, a, b)
      | While (a, b) | TryWith (a, _, b) | StaticCatch (a, _, _, b, _) ->
          scan (scan params a) b
      | For (_, _, _, _, body) -> scan params body
      | Switch (_, sw) -> cases params (sw.consts @ sw.blocks) sw.fail
      | StringSwitch (_, arms, fallback) -> cases params arms fallback
      | Halt a | Raise a -> remove_uses params [ a ]
      | StaticRaise (_, args) -> remove_uses params args
      | HaltScalar _ | Unwind -> params
      | _ -> Ident.Set.empty
  and cases : 'a. Ident.Set.t -> ('a * Anf.aexpr) list -> Anf.aexpr option -> Ident.Set.t =
    fun params arms fallback ->
      let params = List.fold_left (fun left (_, arm) -> scan left arm) params arms in
      Option.fold ~none:params ~some:(scan params) fallback
  in
  scan (pointer_parameters lf) lf.body

let recursive_borrows ~yielding ~borrowed (bindings : Anf.rec_binding list) =
  let infer f =
    List.fold_left
      (fun map (rb : Anf.rec_binding) ->
        let flags =
          if Ident.Set.mem rb.id yielding then
            borrow_flags rb.def Ident.Set.empty
          else f rb.def
        in
        Ident.Map.add rb.id flags map)
      Ident.Map.empty bindings
  in
  let rec solve assumptions =
    let known_borrow id =
      match Ident.Map.find_opt id assumptions with
      | Some _ as flags -> flags
      | None -> borrowed id
    in
    let next = infer (fun lf -> borrow_flags lf (read_only_parameters ~borrowed:known_borrow lf)) in
    if Ident.Map.equal ( = ) assumptions next then next else solve next
  in
  solve (infer (fun lf -> borrow_flags lf (pointer_parameters lf)))

let is_yielding_ccall name = (Ccalls.find name).Ccalls.yields

let operation_can_raise ~finalizers known raising = function
  | Anf.App (Var fn, args) ->
      (match Ident.Map.find_opt fn known with
       | Some arity when List.compare_length_with args arity = 0 -> Ident.Set.mem fn raising
       | _ -> true)
  | App _ -> true
  | DirectApp (target, _) ->
      target.raises = May_raise || (finalizers && target.raises = Finalizer_raise)
  | Binop ((Div | Mod), _, Int n) when n <> 0 -> false
  | Binop ((Div | Mod | Bint_arith (_, (Div_int | Rem_int))), _, _)
  | IntegerBinop (_, (Div_int | Rem_int), _, _) -> true
  | StringGet (true, _, _)
  | BytesSet (true, _, _, _)
  | BytesGetN (true, _, _, _)
  | BytesSetN (true, _, _, _)
  | ArrayGet (true, _, _, _)
  | FloatArrayGet (true, _, _) | FloatArraySet (true, _, _, _)
  | ArraySet (true, _, _, _, _)
  | CreateBytes _ | MakeArrayInit _ ->
      true
  (* The current Bigarray helpers check bounds even for unsafe accesses. *)
  | BigarrayAccess _ | ScalarLoad _ | ScalarStore _ -> true
  | PollFinalizers | Ccall ("ocamlcc_poll_finalizers", []) -> finalizers
  | Ccall (name, _) -> (Ccalls.find name).Ccalls.raises
  | NativeCcall (prim, _) -> prim.prim_alloc
  | _ -> false

let call_can_suspend known yielding = function
  | Anf.Ccall (name, _) -> is_yielding_ccall name
  | DirectApp (target, _) -> target.yields
  | App (Var fn, args) ->
      (match Ident.Map.find_opt fn known with
      | Some arity ->
          List.length args > arity || Ident.Set.mem fn yielding
      | None -> true)
  | App _ -> true
  | _ -> false

let can_raise_with operation =
  let rec scan (e : Anf.aexpr) =
    match e with
    | Halt _ | HaltScalar _ | Unwind | StaticRaise _ -> false
    | Raise _ -> true
    | Let (_, ce, body) | MutLet (_, ce, body) ->
        operation ce || scan body
    | LetRec (_, body)
    | Retain (_, body)
    | Release (_, body)
    | ReleaseMut (_, body)
    | DropReuse (_, _, body)
    | FreeReuse (_, body)
    | ShadowPush (_, _, _, body)
    | ShadowPop (_, _, body) ->
        scan body
    | LetJoin (_, a, b) | If (_, a, b) | ScalarIf (_, _, a, b) | CheckExn (_, a, b) | While (a, b) ->
        scan a || scan b
    | For (_, _, _, _, body) -> scan body
    | Switch (_, sw) ->
        List.exists (fun (_, arm) -> scan arm) sw.consts
        || List.exists (fun (_, arm) -> scan arm) sw.blocks
        || Option.fold ~none:false ~some:scan sw.fail
    | StringSwitch (_, cases, fail) ->
        List.exists (fun (_, arm) -> scan arm) cases
        || Option.fold ~none:false ~some:scan fail
    | StaticCatch (body, _, _, handler, _) ->
        scan body || scan handler
    | TryWith (_, _, handler) -> scan handler
  in
  scan

let compute_call_info (e : Anf.aexpr) =
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
    | LetJoin (_, a, b) | If (_, a, b) | ScalarIf (_, _, a, b) | CheckExn (_, a, b) | While (a, b)
    | StaticCatch (a, _, _, b, _) | TryWith (a, _, b) ->
        collect a;
        collect b
    | Switch (_, sw) ->
        List.iter (fun (_, arm) -> collect arm) sw.consts;
        List.iter (fun (_, arm) -> collect arm) sw.blocks;
        Option.iter collect sw.fail
    | StringSwitch (_, cases, fail) ->
        List.iter (fun (_, arm) -> collect arm) cases;
        Option.iter collect fail
    | Halt _ | HaltScalar _ | StaticRaise _ | Raise _ | Unwind -> ()
  in
  collect e;
  let known =
    List.fold_left (fun acc (id, (lf : Anf.lfunction)) ->
      Ident.Map.add id (List.length lf.params) acc) Ident.Map.empty !funs
  in
  let ce_yields = call_can_suspend known in
  let rec body_yields yielding = function
    | Anf.Let (_, ce, body) | MutLet (_, ce, body) ->
        ce_yields yielding ce || body_yields yielding body
    | LetRec (_, body) | For (_, _, _, _, body)
    | Retain (_, body) | Release (_, body) | ReleaseMut (_, body)
    | DropReuse (_, _, body) | FreeReuse (_, body)
    | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
        body_yields yielding body
    | LetJoin (_, a, b) | If (_, a, b) | ScalarIf (_, _, a, b) | CheckExn (_, a, b) | While (a, b)
    | StaticCatch (a, _, _, b, _) | TryWith (a, _, b) ->
        body_yields yielding a || body_yields yielding b
    | Switch (_, sw) ->
        List.exists (fun (_, arm) -> body_yields yielding arm) sw.consts
        || List.exists (fun (_, arm) -> body_yields yielding arm) sw.blocks
        || Option.fold ~none:false ~some:(body_yields yielding) sw.fail
    | StringSwitch (_, cases, fail) ->
        List.exists (fun (_, arm) -> body_yields yielding arm) cases
        || Option.fold ~none:false ~some:(body_yields yielding) fail
    | Halt _ | HaltScalar _ | StaticRaise _ | Raise _ | Unwind -> false
  in
  let solve body_has_effect =
    let rec fix effects =
      let next = List.fold_left (fun acc (id, (lf : Anf.lfunction)) ->
        if Ident.Set.mem id acc || not (body_has_effect acc lf.body) then acc
        else Ident.Set.add id acc) effects !funs
      in
      if Ident.Set.equal effects next then next else fix next
    in
    fix Ident.Set.empty
  in
  let body_raises ~finalizers raising =
    can_raise_with (operation_can_raise ~finalizers known raising) in
  known, solve body_yields, solve (body_raises ~finalizers:true),
  solve (body_raises ~finalizers:false)

module Program_facts = struct
  type t = {
    pure : Ident.Set.t;
    known_funs : int Ident.Map.t;
    yielding : Ident.Set.t;
    raising : Ident.Set.t;
    ordinary_raising : Ident.Set.t;
    imm_funs : int Ident.Map.t;
    typed_imm : Ident.Set.t;
    exported : Ident.Set.t;
  }

  let analyze ~exported (prog : Anf.program) =
    let pure = Anf.pure_defs prog.code |> List.map fst |> Ident.Set.of_list in
    let known_funs, yielding, raising, ordinary_raising = compute_call_info prog.code in
    let typed_imm =
      Ident.Map.fold
        (fun id kind acc -> if kind = Lambda.Pintval then Ident.Set.add id acc else acc)
        prog.value_kinds Ident.Set.empty
    in
    let imm_funs = compute_imm_funs ~typed_imm ~pure prog.code in
    let exported =
      List.fold_left (fun ids (_, id) -> Ident.Set.add id ids) Ident.Set.empty exported
    in
    { pure; known_funs; yielding; raising; ordinary_raising; imm_funs; typed_imm; exported }

  let with_worker ~original ~worker ~arity facts =
    let inherit_effect set =
      if Ident.Set.mem original set then Ident.Set.add worker set else set
    in
    let imm_funs =
      match Ident.Map.find_opt original facts.imm_funs with
      | Some arity -> Ident.Map.add worker arity facts.imm_funs
      | None -> facts.imm_funs
    in
    { facts with
      raising = inherit_effect facts.raising;
      ordinary_raising = inherit_effect facts.ordinary_raising;
      known_funs = Ident.Map.add worker arity facts.known_funs;
      pure = Ident.Set.add worker facts.pure;
      imm_funs }

  let effects facts id =
    let raises =
      if Ident.Set.mem id facts.ordinary_raising then Anf.May_raise
      else if Ident.Set.mem id facts.raising then Finalizer_raise
      else No_raise
    in
    Ident.Set.mem id facts.yielding, Ident.Map.mem id facts.imm_funs, raises
end
