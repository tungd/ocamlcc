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
     continuation are not scope exits; [env.no_release_muts] defers those
     slots to the continuation that still owns them. *)

module IntSet = Set.Make (Int)

type borrowed_entry = {
  worker : Ident.t;
  borrow : bool list;
}

type state = {
  owned : Ident.Set.t;
  borrowed : Ident.Set.t;
  frame_borrowed : Ident.Set.t;
  view_owners : Ident.Set.t Ident.Map.t;
  imm : Ident.Set.t;
  typed_imm : Ident.Set.t;
  pure : Ident.Set.t;
  known_funs : int Ident.Map.t;
  yielding_funs : Ident.Set.t;
  raising_funs : Ident.Set.t;
  ordinary_raising_funs : Ident.Set.t;
  imm_funs : int Ident.Map.t;
  borrowed_entries : borrowed_entry Ident.Map.t;
  exported : Ident.Set.t;
  exported_workers : (Ident.t, borrowed_entry) Hashtbl.t;
  muts : Ident.Set.t;
  (* Mutable slots that stay in scope after the current join point or loop
     exit ([LetJoin] rhs, [While]/[For] condition and body). Their single
     [ReleaseMut] is emitted by the continuation that still uses them, so
     [Halt] must skip them: [ReleaseMut env.muts - env.no_release_muts]. *)
  no_release_muts : Ident.Set.t;
  handlers : (int, Ident.Set.t * Ident.Set.t * Ident.Set.t) Hashtbl.t;
  try_owned : Ident.Set.t;
  try_muts : Ident.Set.t;
  try_depth : int;
  (* True only at a function/toplevel tail return position. [Halt]s ending a
     [LetJoin] rhs, [TryWith] body, or loop flow into a join/handler and must
     not elide [CheckExn] or [ShadowPush]/[ShadowPop]. *)
  in_tail : bool;
}

let is_borrowed (env : state) (id : Ident.t) : bool =
  Ident.Set.mem id env.borrowed || Ident.Set.mem id env.frame_borrowed

(* The false edge of ANF's conditional tests for the tagged zero, even
   when the scrutinee may be a constructor block on the other edge. *)
let false_edge env = function
  | Anf.Var id -> { env with imm = Ident.Set.add id env.imm }
  | _ -> env

let atom_is_imm ~pure imm (a : Anf.atom) =
  match a with
  | Int _ | Char _ | Unit | String _ | Float _ | Int32 _ | Int64 _
  | Nativeint _ | ConstFloatArray _ | ConstBlock _ ->
      true
  | Var id -> Ident.Set.mem id imm || Ident.Set.mem id pure
  | MutVar id -> Ident.Set.mem id imm
  | ModuleSlot (_, kind) -> kind = Lambda.Pintval
  | BorrowedField _ -> false

let is_imm_atom env = atom_is_imm ~pure:env.pure env.imm

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

let cexpr_is_imm ~pure ~imm_funs imm (ce : Anf.cexpr) =
  match ce with
  | Atom a -> atom_is_imm ~pure imm a
  | Binop (op, _, _) -> is_imm_binop op
  | Unop (op, _) -> is_imm_unop op
  | IntSelect _ | Field (_, Immediate_field, _) | ArrayGet (_, Lambda.Pintarray, _, _)
  | SetField _ | SetFloatField _ | OffsetRef _ | StringGet _
  | BytesSet _ | BytesSetN _ | Bswap16 _ | ArraySet _ | Builtin _ | Assign _ | AssignImm _
  | ReadScalarSlot _ | AssignScalar _ | StoreModuleSlot _ | ImportDependency _ ->
      true
  | BytesGetN (_, 2, _, _) -> true
  | BytesGetN _ | BswapBint _ -> false
  | IntegerOfInt _ | IntOfInteger _ | IntegerConvert _
  | FloatArrayGet _ | FloatArraySet _ | FloatOfInt _ | IntOfFloat _
  | FloatSign _ | FloatCompare _ | KeepAlive _ -> true
  | MakeBlock (_, []) | ScalarLoad _ | ScalarValue _ | FloatBinop _ | IntegerBinop _ | IntegerCompare _ | IntegerNeg _ | IntegerShift _ | ScalarStore _ -> true
  | Ccall (name, _) -> Ccalls.returns_imm name
  | NativeCcall (prim, _) ->
      not (Primitive.equal_native_repr prim.prim_native_repr_res Same_as_ocaml_repr)
  | DirectApp (target, _) -> target.returns_immediate
  | App (Var fn, args) -> (
      match Ident.Map.find_opt fn imm_funs with
      | Some arity -> List.length args = arity
      | None -> false)
  | MakeBlock _ | AllocReuse _ | MakeArray _ | Field _ | FloatField _ | BoxScalar _
  | BigarrayAccess _ | ArrayGet _ | CreateBytes _ | MakeArrayInit _ | App _
  | GetGlobal _ | Fun _ | Recur _ ->
      false

let is_imm_cexpr env = cexpr_is_imm ~pure:env.pure ~imm_funs:env.imm_funs env.imm

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

let handler_immediates env hid binders body =
  match binders with
  | [] -> Ident.Set.empty
  | _ ->
      let observed = ref None in
      ignore (scan_immediates ~typed_imm:env.typed_imm ~pure:env.pure ~imm_funs:env.imm_funs
                ~exits:[hid, observed] env.imm body);
      binders_imm env.typed_imm binders !observed

let mutlet_is_imm env slot init body =
  if Ident.Set.mem slot env.typed_imm then true
  else if not (is_imm_cexpr env init) then false
  else
    let valid = ref true in
    ignore (scan_immediates ~typed_imm:env.typed_imm ~pure:env.pure ~imm_funs:env.imm_funs
              ~mutable_slot:(slot, valid) (Ident.Set.add slot env.imm) body);
    !valid

let specialize_assignment env = function
  | Anf.Assign (slot, rhs) when Ident.Set.mem slot env.imm -> Anf.AssignImm (slot, rhs)
  | ce -> ce

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
  | Binop (_, a, b) | IntSelect (_, a, b) ->
      (Ident.Set.union (atom_vars a) (atom_vars b), [])
  | Unop (_, a) -> (atom_vars a, [])
  | MakeBlock (_, args) | AllocReuse (_, _, args) | MakeArray (_, args) ->
      (Ident.Set.empty, args)
  | Field (_, _, a) | FloatField (_, a) | OffsetRef (_, a) | CreateBytes a
  | Bswap16 a | BswapBint (_, a) ->
      (atom_vars a, [])
  | SetField (_, Lambda.Pointer, a, rhs) -> (atom_vars a, [ rhs ])
  | SetField (_, Immediate, a, rhs)
  | SetFloatField (_, a, rhs) ->
      (Ident.Set.union (atom_vars a) (atom_vars rhs), [])
  | StringGet (_, a, b) | BytesGetN (_, _, a, b) | ArrayGet (_, _, a, b) ->
      (Ident.Set.union (atom_vars a) (atom_vars b), [])
  | BytesSet (_, a, b, c) | BytesSetN (_, _, a, b, c) ->
      ( Ident.Set.union (atom_vars a) (Ident.Set.union (atom_vars b) (atom_vars c)),
        [] )
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
  | GetGlobal _ | ImportDependency _ -> (Ident.Set.empty, [])
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

let borrowed_flags env id =
  Option.map (fun entry -> entry.borrow) (Ident.Map.find_opt id env.borrowed_entries)

(* A private entry may borrow parameters read locally or forwarded to other
   borrowed arguments. A worker duplicates no nested function identities. *)
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
    | Fun _ -> Ident.Set.empty
    | (SetField (_, Lambda.Pointer, target, _)
      | ArraySet (_, (Lambda.Paddrarray | Lambda.Pgenarray), target, _, _)) as ce ->
        (* A pointer overwrite can retire the old child. Keep the
           receiver eligible while conservatively excluding its siblings. *)
        Ident.Set.inter (remove_uses params (snd (atom_operands ce))) (atom_vars target)
    | ce -> remove_uses params (snd (atom_operands ce))
  in
  let rec scan params expr =
    if Ident.Set.is_empty params then params
    else
      match expr with
      | Anf.Let (_, ce, body) | MutLet (_, ce, body) -> scan (cexpr params ce) body
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

let recursive_borrows env (bindings : Anf.rec_binding list) =
  let infer f =
    List.fold_left
      (fun map (rb : Anf.rec_binding) ->
        let flags =
          if Ident.Set.mem rb.id env.yielding_funs then
            borrow_flags rb.def Ident.Set.empty
          else f rb.def
        in
        Ident.Map.add rb.id flags map)
      Ident.Map.empty bindings
  in
  let rec solve assumptions =
    let borrowed id =
      match Ident.Map.find_opt id assumptions with
      | Some _ as flags -> flags
      | None -> borrowed_flags env id
    in
    let next = infer (fun lf -> borrow_flags lf (read_only_parameters ~borrowed lf)) in
    if Ident.Map.equal ( = ) assumptions next then next else solve next
  in
  solve (infer (fun lf -> borrow_flags lf (pointer_parameters lf)))

let add_borrowed_entry env id borrow =
  let worker = Ident.create_local (Ident.name id ^ "_borrowed") in
  let entry = { worker; borrow } in
  if Ident.Set.mem id env.exported then Hashtbl.replace env.exported_workers id entry;
  let imm_funs =
    match Ident.Map.find_opt id env.imm_funs with
    | Some arity -> Ident.Map.add worker arity env.imm_funs
    | None -> env.imm_funs
  in
  let inherit_effect set =
    if Ident.Set.mem id set then Ident.Set.add worker set else set
  in
  worker,
  { env with
    raising_funs = inherit_effect env.raising_funs;
    ordinary_raising_funs = inherit_effect env.ordinary_raising_funs;
    known_funs = Ident.Map.add worker (List.length borrow) env.known_funs;
    pure = Ident.Set.add worker env.pure;
    imm_funs;
    borrowed_entries = Ident.Map.add id entry env.borrowed_entries }

(* Fuse a field into local borrowed operands, keeping its receiver live.
   A mutable projection only fuses with its immediate, final consumer so
   it cannot be reloaded after an intervening operation. *)
let fuse_field_read ~stable id index owner body =
  let open Anf in
  let uses atom = Ident.Set.mem id (atom_vars atom) in
  let live expr = Ident.Set.mem id (Anf.free_vars expr) in
  let rec substitute = function
    | Var v when Ident.same v id -> BorrowedField (index, owner)
    | BorrowedField (i, base) -> BorrowedField (i, substitute base)
    | atom -> atom
  in
  let reader = function
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
    | BytesSetN (safe, width, str, i, v) ->
        Some (BytesSetN (safe, width, substitute str, substitute i, v))
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
        match reader ce with
        | Some ce' when not (use_in ce') ->
            let next =
              if not (live next) then Some next
              else if stable && can_cross ce then fuse next
              else None
            in
            Option.map (fun next -> Let (result, ce', next)) next
        | _ -> None)
    | Let (result, ce, next) when stable && can_cross ce ->
        Option.map (fun next -> Let (result, ce, next)) (fuse next)
    | LetJoin (result, rhs, next) when not (live next) ->
        Option.map (fun rhs -> LetJoin (result, rhs, next)) (fuse rhs)
    | If (cond, yes, no) when uses cond && not (live yes || live no) ->
        Some (If (substitute cond, yes, no))
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
let mutable_slot_result body =
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
    | Let (box, (MakeBlock (0, [Var value]) as make),
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
  scan Ident.Map.empty body

let borrowed_call env live = function
  | Anf.App (Var fn, args) -> (
      match Ident.Map.find_opt fn env.borrowed_entries with
      | Some entry when List.length args = List.length entry.borrow ->
          let pairs = List.combine entry.borrow args in
          let valid = function
            | false, _ -> true
            | true, Anf.Var id ->
                is_borrowed env id || Ident.Set.mem id live
                || Ident.Map.mem id env.view_owners
            | true, a -> is_imm_atom env a
          in
          if List.for_all valid pairs then Some (entry.worker, pairs) else None
      | _ -> None)
  | _ -> None

let rec restore_borrowed pairs consumed =
  match pairs, consumed with
  | [], [] -> []
  | (true, a) :: rest, _ -> a :: restore_borrowed rest consumed
  | (false, _) :: rest, a :: remaining -> a :: restore_borrowed rest remaining
  | _ -> assert false

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
  | Binop ((Div | Mod | Bint_div _ | Bint_mod _), _, _)
  | IntegerBinop (_, (Div_int | Rem_int), _, _) -> true
  | StringGet (true, _, _)
  | BytesSet (true, _, _, _)
  | BytesGetN (true, _, _, _)
  | BytesSetN (true, _, _, _, _)
  | ArrayGet (true, _, _, _)
  | FloatArrayGet (true, _, _) | FloatArraySet (true, _, _, _)
  | ArraySet (true, _, _, _, _)
  | CreateBytes _ | MakeArrayInit _ ->
      true
  (* The current Bigarray helpers check bounds even for unsafe accesses. *)
  | BigarrayAccess _ | ScalarLoad _ | ScalarStore _ -> true
  | Ccall ("ocamlcc_poll_finalizers", []) -> finalizers
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

let is_yielding_ce env = call_can_suspend env.known_funs env.yielding_funs

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

let ce_may_raise env =
  operation_can_raise ~finalizers:true env.known_funs env.raising_funs

let exception_check env ce =
  (* Dispatch itself already sits behind the due check. The sticky guard
     saves a TLS read at callers of functions whose only exception source
     is an automatic poll, including one that drained the registry. *)
  match ce with
  | Anf.Ccall ("ocamlcc_poll_finalizers", []) -> Anf.May_raise
  | _ when operation_can_raise ~finalizers:false env.known_funs env.ordinary_raising_funs ce ->
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
      match Hashtbl.find_opt env.handlers id with
      | Some (ho, _, _) -> Ident.Set.union acc ho
      | None -> acc)
    ids Ident.Set.empty

let keep_view_owners env vars =
  if Ident.Map.is_empty env.view_owners then vars
  else
    Ident.Set.fold (fun id live ->
      match Ident.Map.find_opt id env.view_owners with
      | Some owners -> Ident.Set.union owners live
      | None -> live) vars vars

let live_with_handlers (env : state) (e : Anf.aexpr) : Ident.Set.t =
  keep_view_owners env (Ident.Set.union (Anf.free_vars e) (handler_live_vars env e))

(* Each live reuse token is shadowed until the protected call returns.
   Already-inserted token cleanups may wrap the same error-side pop. *)
let rec add_reuse_to_pop = function
  | Anf.ShadowPop (nv, nr, body) -> Some (Anf.ShadowPop (nv, nr + 1, body))
  | FreeReuse (tok, body) ->
      Option.map (fun body -> Anf.FreeReuse (tok, body)) (add_reuse_to_pop body)
  | _ -> None

let rec inject_reuse ?(in_shadow = false) (tok : Ident.t) (e : Anf.aexpr) :
    Anf.aexpr option =
  match e with
  | Let (res, MakeBlock (tag, (_ :: _ as args)), next) when not in_shadow ->
      Some (Let (res, AllocReuse ({ primary = tok; fallback = None }, tag, args), next))
  | Let (res, (AllocReuse (reuse, tag, args) as ce), next) -> (
      match inject_reuse ~in_shadow tok next with
      | Some next -> Some (Let (res, ce, next))
      | None when not in_shadow && Option.is_none reuse.fallback ->
          Some (Let (res, AllocReuse ({ reuse with fallback = Some tok }, tag, args), next))
      | None -> None)
  | Let (x, ((Atom _ | Binop _ | IntSelect _ | Unop _ | Field _ | SetField _
             | FloatField _ | SetFloatField _ | OffsetRef _
             | StringGet _ | BytesSet _ | BytesGetN _ | BytesSetN _ | Bswap16 _ | BswapBint _ | ArrayGet _ | ArraySet _
             | CreateBytes _ | MakeArrayInit _ | MakeArray _ | App _ | DirectApp _
             | IntegerOfInt _ | IntOfInteger _ | IntegerConvert _
             | FloatArrayGet _ | FloatArraySet _ | FloatSign _ | FloatCompare _
             | FloatOfInt _ | IntOfFloat _ | BoxScalar _
             | ScalarLoad _ | ScalarStore _ | ScalarValue _ | FloatBinop _ | IntegerBinop _ | IntegerCompare _ | IntegerNeg _ | IntegerShift _
             | Builtin _ | BigarrayAccess _ | Ccall _ | NativeCcall _ | GetGlobal _ | Assign _ | AssignImm _
             | ReadScalarSlot _ | AssignScalar _
             | MakeBlock (_, [])) as ce), body) -> (
      match inject_reuse ~in_shadow tok body with
      | Some body' -> Some (Let (x, ce, body'))
      | None -> None)
  | CheckExn (exception_kind, on_err, on_ok) ->
      let on_err = if in_shadow then add_reuse_to_pop on_err else Some on_err in
      Option.bind on_err (fun on_err ->
          Option.map
            (fun on_ok -> Anf.CheckExn (exception_kind, FreeReuse (tok, on_err), on_ok))
            (inject_reuse ~in_shadow tok on_ok))
  | LetJoin (id, rhs, body) when not in_shadow ->
      Option.map (fun rhs -> Anf.LetJoin (id, rhs, body)) (inject_reuse tok rhs)
  | DropReuse (v, prior, body) ->
      Option.map (fun body -> Anf.DropReuse (v, prior, body)) (inject_reuse ~in_shadow tok body)
  | FreeReuse (prior, body) ->
      Option.map (fun body -> Anf.FreeReuse (prior, body)) (inject_reuse ~in_shadow tok body)
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
  | ShadowPush (vs, ms, rtoks, body) when not in_shadow -> (
      match inject_reuse ~in_shadow:true tok body with
      | Some body' -> Some (ShadowPush (vs, ms, tok :: rtoks, body'))
      | None -> None)
  | ShadowPop (nv, nr, body) -> (
      match inject_reuse ~in_shadow:false tok body with
      | Some body' ->
          let nr' = if in_shadow then nr + 1 else nr in
          Some (ShadowPop (nv, nr', body'))
      | None -> None)
  | If (c, th, el) when not in_shadow -> (
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
  let mat_binds = ref [] in
  let atoms' =
    List.map
      (fun (a : Anf.atom) ->
        match a with
        | MutVar _ | ModuleSlot _ ->
            let tmp = Ident.create_local "mval" in
            mat_binds := (tmp, a) :: !mat_binds;
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
    (fun acc (tmp, source) ->
      let next = if is_imm_atom env source then acc else Anf.Retain (tmp, acc) in
      Anf.Let (tmp, Atom source, next))
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
      Anf.CheckExn (exception_check env ce, wrap_pop on_err, wrap_pop body_cont)
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
  | HaltScalar _ ->
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
        let read_only =
          if Ident.Set.mem id env.yielding_funs then Ident.Set.empty
          else read_only_parameters ~borrowed:(borrowed_flags env) lf
        in
        let body' =
          if Ident.Set.is_empty read_only then transform_aexpr env body
          else
            let worker, env_body = add_borrowed_entry env id (borrow_flags lf read_only) in
            let body' = transform_aexpr env_body body in
            let exported = Ident.Set.mem id env.exported in
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
                 && not (Ident.Set.mem v env.pure))
        in
        let cap_atoms = List.map (fun v -> Anf.Var v) (Ident.Set.elements cap) in
        let lf' = transform_fun env ~self_id:None ~has_closure:true lf in
        let base_live = Ident.Set.remove id (live_with_handlers env body) in
        let live_after =
          if can_raise env body then Ident.Set.union base_live env.try_owned
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
  | Let (id, (Field (index, ((Immutable_field | Mutable_field) as kind),
                     ((Var _ | BorrowedField _) as owner)) as ce), body) -> (
      let stable = kind = Immutable_field in
      match fuse_field_read ~stable id index owner body with
      | Some fused -> transform_aexpr env fused
      | None when stable && field_is_read_only_in_loop id body ->
          transform_view env id (Anf.BorrowedField (index, owner)) body
      | None -> transform_let env id ce body)
  | Let (id, Atom ((MutVar slot | BorrowedField (_, MutVar slot)) as source), body)
    when Ident.Set.mem slot env.muts && read_only_slot_snapshot slot id body ->
      transform_view env id source body
  | Let (id, ce, body) -> transform_let env id ce body
  | MutLet (id, ce, body) ->
      let immediate = mutlet_is_imm env id ce body in
      let ce = specialize_assignment env ce in
      let ce_may_raise = ce_may_raise env ce in
      let borrowed_in_ce, consumed_in_ce = atom_operands ce in
      let borrowed_in_ce = keep_view_owners env borrowed_in_ce in
      let base_live_body = Ident.Set.remove id (live_with_handlers env body) in
      let live_before_ce =
        Ident.Set.union base_live_body
          (if ce_may_raise || can_raise env body then env.try_owned
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
              (if can_raise env body then env.try_owned else Ident.Set.empty)
          in
          let dead_after = Ident.Set.diff rem_after_before live_for_after_ce in
          let live_for_body = Ident.Set.diff rem_after_before dead_after in
          let env_body =
            { env with
              owned = live_for_body;
              imm = set_imm env.imm id immediate;
              muts = if immediate then env.muts else Ident.Set.add id env.muts }
          in
          let body' = transform_aexpr env_body body in
          let body_with_dead_after = emit_drops env dead_after body' in
          let make_let next = Anf.MutLet (id, ce', next) in
          let node =
            emit_shadowed_call env ~ce:ce' ~ce_may_raise ~is_pure_tail:false
              ~rem_after_before ~body_cont:body_with_dead_after make_let
          in
          emit_drops env dead_before node)
  | LetJoin (id, rhs, body) -> (
      match mutable_slot_result rhs with
      | Some (slot, field, rhs)
        when Ident.Set.mem slot env.muts && read_only_slot_snapshot slot id body ->
          let ignored = Ident.create_local "slot_join" in
          let source = match field with
            | None -> Anf.MutVar slot
            | Some index -> Anf.BorrowedField (index, MutVar slot) in
          transform_join env ignored rhs (Anf.Let (id, Atom source, body))
      | _ -> transform_join env id rhs body)
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
        transform_pure_group env bindings body
      else
        let cap_list_per_rb =
          List.map
            (fun (rb : Anf.rec_binding) ->
              Anf.free_vars rb.def.body
              |> Ident.Set.filter (fun v ->
                     not (List.exists (Ident.same v) (Anf.bound_parameters rb.def))
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
          if can_raise env body then Ident.Set.union base_live env.try_owned
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
  | StaticCatch (body, hid, binders, handler, result_rep) ->
      let immediate = handler_immediates env hid binders body in
      let base_fh =
        List.fold_left
          (fun s b -> Ident.Set.remove b s)
          (live_with_handlers env handler)
          binders
      in
      let fv_handler =
        if can_raise env handler then Ident.Set.union base_fh env.try_owned
        else base_fh
      in
      let handler_owned = Ident.Set.inter env.owned fv_handler in
      let handler_owned_list =
        List.fold_left
          (fun acc b -> if Ident.Set.mem b immediate then acc else Ident.Set.add b acc)
          handler_owned binders
      in
      let target_live = Ident.Set.union handler_owned env.frame_borrowed in
      Hashtbl.replace env.handlers hid (handler_owned, target_live, env.muts);
      let body' = transform_aexpr env body in
      Hashtbl.remove env.handlers hid;
      let dead_at_handler = Ident.Set.diff handler_owned fv_handler in
      let handler' =
        transform_aexpr
          { env with
            owned = Ident.Set.diff handler_owned_list dead_at_handler;
            imm = Ident.Set.union (Ident.Set.diff env.imm (Ident.Set.of_list binders)) immediate }
          handler
      in
      StaticCatch (body', hid, binders, emit_drops env dead_at_handler handler', result_rep)
  | StaticRaise (hid, args) ->
      let target_owned, target_live, target_muts =
        match Hashtbl.find_opt env.handlers hid with
        | Some triple -> triple
        | None -> (Ident.Set.empty, env.frame_borrowed, env.muts)
      in
      prepare_consumed env ~borrowed_also:Ident.Set.empty
        ~live_after:target_owned args (fun remaining_owned args' ->
          let dead_vars =
            Ident.Set.diff
              (Ident.Set.union remaining_owned env.frame_borrowed)
              target_live
          in
          let dead_muts = Ident.Set.diff env.muts target_muts in
          emit_drops env dead_vars
            (emit_mut_releases dead_muts (StaticRaise (hid, args'))))
  | TryWith (body, exn_id, handler) ->
      let outer_needed =
        if can_raise env handler then env.try_owned else Ident.Set.empty
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
          try_depth = env.try_depth + 1;
          in_tail = false }
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
          no_release_muts = env.muts;
          in_tail = false }
      in
      let cond' = transform_aexpr loop_env cond in
      let body' = transform_aexpr loop_env body in
      if Ident.Set.is_empty env.owned && Ident.Set.is_empty env.muts then
        While (cond', body')
      else
        let u = Ident.create_local "wend" in
        let dead_muts = Ident.Set.diff env.muts env.no_release_muts in
        let cont =
          emit_drops env env.owned
            (emit_mut_releases dead_muts (Halt (Var u)))
        in
        LetJoin (u, While (cond', body'), cont)
  | For (idx, s, e, dir, body) ->
      let loop_env =
        { env with
          owned = Ident.Set.empty;
          frame_borrowed = Ident.Set.union env.frame_borrowed env.owned;
          imm = Ident.Set.add idx env.imm;
          no_release_muts = env.muts;
          in_tail = false }
      in
      let body' = transform_aexpr loop_env body in
      if Ident.Set.is_empty env.owned && Ident.Set.is_empty env.muts then
        For (idx, s, e, dir, body')
      else
        let u = Ident.create_local "fend" in
        let dead_muts = Ident.Set.diff env.muts env.no_release_muts in
        let cont =
          emit_drops env env.owned
            (emit_mut_releases dead_muts (Halt (Var u)))
        in
        LetJoin (u, For (idx, s, e, dir, body'), cont)

and transform_view env id source body =
  let owners = keep_view_owners env (atom_vars source) in
  let env = { env with view_owners = Ident.Map.add id owners env.view_owners } in
  let live = Ident.Set.union owners (live_with_handlers env body) in
  let live = if can_raise env body then Ident.Set.union live env.try_owned else live in
  let dead = Ident.Set.diff env.owned live in
  let body = transform_aexpr { env with owned = Ident.Set.diff env.owned dead } body in
  emit_drops env dead (Let (id, Atom source, body))

and transform_join env id rhs body : Anf.aexpr =
  let base_live_body = Ident.Set.remove id (live_with_handlers env body) in
  let live_body_only =
    if can_raise env body then Ident.Set.union base_live_body env.try_owned
    else base_live_body
  in
  let live_rhs =
    Ident.Set.union (live_with_handlers env rhs)
      (if can_raise env rhs then env.try_owned else Ident.Set.empty)
  in
  let shared = Ident.Set.inter env.owned live_body_only in
  let owned_rhs_only = Ident.Set.diff env.owned live_body_only in
  let dead_before = Ident.Set.diff owned_rhs_only live_rhs in
  let owned_for_rhs = Ident.Set.diff owned_rhs_only dead_before in
  let env_rhs =
    { env with
      owned = owned_for_rhs;
      frame_borrowed = Ident.Set.union env.frame_borrowed shared;
      no_release_muts = env.muts;
      in_tail = false }
  in
  let rhs' = transform_aexpr env_rhs rhs in
  let imm =
    if Ident.Set.mem id env.typed_imm || Anf.returns_scalar rhs
       || aexpr_returns_imm ~typed_imm:env.typed_imm ~pure:env.pure ~imm_funs:env.imm_funs env.imm rhs
    then Ident.Set.add id env.imm
    else Ident.Set.remove id env.imm
  in
  let env_body = { env with owned = Ident.Set.add id shared; imm } in
  let body' = transform_aexpr env_body body in
  emit_drops env dead_before (LetJoin (id, rhs', body'))

and transform_let env id ce body =
  let ce = specialize_assignment env ce in
  let ce_may_raise = ce_may_raise env ce in
  let base_live_body = Ident.Set.remove id (live_with_handlers env body) in
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
      (if ce_may_raise || can_raise env body then env.try_owned
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
          (if can_raise env body then env.try_owned else Ident.Set.empty)
      in
      let dead_after = Ident.Set.diff rem_after_before live_for_after_ce in
      let live_for_body = Ident.Set.diff rem_after_before dead_after in
      let is_imm = Ident.Set.mem id env.typed_imm || is_imm_cexpr env ce in
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
        env.in_tail
        &&
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

and transform_branch (env : state) (arm : Anf.aexpr) : Anf.aexpr =
  let base_live = live_with_handlers env arm in
  let live =
    if can_raise env arm then Ident.Set.union base_live env.try_owned
    else base_live
  in
  let dead = Ident.Set.diff env.owned live in
  let arm' = transform_aexpr { env with owned = Ident.Set.diff env.owned dead } arm in
  emit_drops env dead arm'

and transform_pure_group env (bindings : Anf.rec_binding list) body =
  let plan = recursive_borrows env bindings in
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
          env, (worker, params, { rb.def with private_entry = not (Ident.Set.mem rb.id env.exported) }) :: workers)
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
  let owned_params = Ident.Set.diff params_set borrowed_params in
  let fn_env =
    { env with
      owned = owned_params;
      borrowed = Ident.Set.union borrowed borrowed_params;
      frame_borrowed = Ident.Set.empty;
      view_owners = Ident.Map.empty;
      muts = Ident.Set.empty;
      no_release_muts = Ident.Set.empty;
      handlers = Hashtbl.create 8;
      imm = Ident.Set.union (Ident.Set.diff env.imm params_set) (imm_params_of lf);
      try_owned = Ident.Set.empty;
      try_muts = Ident.Set.empty;
      try_depth = 0;
      in_tail = true }
  in
  let live_body = Anf.free_vars lf.body in
  let dead_params = Ident.Set.diff owned_params live_body in
  let body' =
    transform_aexpr
      { fn_env with owned = Ident.Set.diff owned_params dead_params }
      lf.body
  in
  { lf with body = emit_drops fn_env dead_params body' }

and rebuild_cexpr (ce : Anf.cexpr) (atoms' : Anf.atom list) : Anf.cexpr =
  match (ce, atoms') with
  | Atom _, [ a ] -> Atom a
  | MakeBlock (tag, _), args -> MakeBlock (tag, args)
  | AllocReuse (tok, tag, _), args -> AllocReuse (tok, tag, args)
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
  let pure =
    Anf.pure_defs prog.code |> List.map fst |> Ident.Set.of_list
  in
  let known_funs, yielding_funs, raising_funs, ordinary_raising_funs =
    compute_call_info prog.code in
  let typed_imm =
    Ident.Map.fold
      (fun id kind acc -> if kind = Lambda.Pintval then Ident.Set.add id acc else acc)
      prog.value_kinds Ident.Set.empty
  in
  let imm_funs = compute_imm_funs ~typed_imm ~pure prog.code in
  let init_env =
    { owned = Ident.Set.empty;
      borrowed = Ident.Set.empty;
      frame_borrowed = Ident.Set.empty;
      view_owners = Ident.Map.empty;
      imm = Ident.Set.empty;
      typed_imm;
      pure;
      known_funs;
      yielding_funs;
      raising_funs;
      ordinary_raising_funs;
      imm_funs;
      borrowed_entries = Ident.Map.empty;
      exported = List.fold_left (fun ids (_, id) -> Ident.Set.add id ids) Ident.Set.empty exported;
      exported_workers = Hashtbl.create 16;
      muts = Ident.Set.empty;
      no_release_muts = Ident.Set.empty;
      handlers = Hashtbl.create 8;
      try_owned = Ident.Set.empty;
      try_muts = Ident.Set.empty;
      try_depth = 0;
      in_tail = true }
  in
  let effects id =
    let raises =
      if Ident.Set.mem id ordinary_raising_funs then Anf.May_raise
      else if Ident.Set.mem id raising_funs then Finalizer_raise
      else No_raise in
    Ident.Set.mem id yielding_funs, Ident.Map.mem id imm_funs, raises
  in
  let code = transform_aexpr init_env prog.code in
  let workers id = Option.map (fun entry -> entry.worker, entry.borrow)
      (Hashtbl.find_opt init_env.exported_workers id) in
  { prog with code }, effects, workers

let run prog = let prog, _, _ = run_with_effects prog in prog
