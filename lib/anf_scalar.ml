open Anf_ir

type scalar_binding = Value of cexpr | Join of aexpr

let rec boxed_branch = function
  | Let (_, _, body) -> boxed_branch body
  | If _ | Switch (_, { result_rep = None; _ }) | StaticCatch (_, _, _, _, None) -> true
  | _ -> false

let bind_scalar_chain id binding body =
  match binding with
  | Value (BoxScalar (Double_scalar, value)) ->
      (match body with
       | Let (store, SetField (index, Lambda.Pointer, owner, Var rhs), next)
         when Ident.same id rhs && not (Ident.Set.mem id (Variables.atom Ident.Set.empty owner))
              && not (Ident.Set.mem id (free_vars next)) ->
           Let (store, SetBoxedFloatField (index, owner, value), next)
       | _ -> Let (id, BoxScalar (Double_scalar, value), body))
  | Value ce -> Let (id, ce, body)
  | Join rhs -> LetJoin (id, rhs, body)

let raw_boxed_arithmetic op lhs rhs =
  match op with
  | Bint_arith (kind, arithmetic) ->
      Some (Integer_scalar kind, IntegerBinop (kind, arithmetic, lhs, Boxed_scalar rhs))
  | Bint_shift (kind, shift) ->
      Some (Integer_scalar kind, IntegerShift (kind, shift, lhs, rhs))
  | _ -> None

let raw_producer = function
  | BytesGetN (safe, Boxed_word word, bytes, index) ->
      Some (Integer_scalar (Builtins.Byte_access.boxed_integer word),
            BytesGetN (safe, Raw_word word, bytes, index))
  | ArrayGet (safe, Lambda.Pfloatarray, arr, index) ->
      Some (Double_scalar, FloatArrayGet (safe, arr, index))
  | Binop (Float_arithmetic op, lhs, rhs) ->
      Some (Double_scalar, FloatBinop (op, Boxed_scalar lhs, Boxed_scalar rhs))
  | Binop (op, lhs, rhs) -> raw_boxed_arithmetic op (Boxed_scalar lhs) rhs
  | Unop (Float_of_int, value) -> Some (Double_scalar, FloatOfInt value)
  | Unop ((Fneg | Fabs as op), value) ->
      let op = match op with Fneg -> `Neg | _ -> `Abs in
      Some (Double_scalar, FloatSign (op, Boxed_scalar value))
  | Unop (Bint_of_int kind, value) ->
      Some (Integer_scalar kind, IntegerOfInt (kind, value))
  | Unop (Bint_cvt (src, dst), value) ->
      Some (Integer_scalar dst, IntegerConvert (src, dst, Boxed_scalar value))
  | Unop (Bint_neg kind, value) ->
      Some (Integer_scalar kind, IntegerNeg (kind, Boxed_scalar value))
  | _ -> None

let collect_scalar_binding id ce bindings =
  match raw_producer ce with
  | Some (rep, producer) ->
      let raw = Ident.create_local "scalar" in
      (id, Value (BoxScalar (rep, Raw_scalar raw))) :: (raw, Value producer) :: bindings
  | None ->
      let ce =
        match ce with
        | Unop (Int_of_bint kind, value) -> IntOfInteger (kind, Boxed_scalar value)
        | Unop (Int_of_float, value) -> IntOfFloat (Boxed_scalar value)
        | Binop (Bint_cmp (kind, cmp), lhs, rhs) ->
            IntegerCompare (kind, Predicate cmp, Boxed_scalar lhs, Boxed_scalar rhs)
        | Binop (Compare_bints kind, lhs, rhs) ->
            IntegerCompare (kind, Three_way, Boxed_scalar lhs, Boxed_scalar rhs)
        | Binop (Fcmp cmp, lhs, rhs) -> FloatCompare (cmp, Boxed_scalar lhs, Boxed_scalar rhs)
        | ArraySet (safe, Lambda.Pfloatarray, arr, index, value) ->
            FloatArraySet (safe, arr, index, Boxed_scalar value)
        | _ -> ce
      in
      (id, Value ce) :: bindings

(* Walk backwards from scalar consumers. Uses that cross a control-flow
   boundary or need an OCaml value keep the binding boxed. Conflicting
   scalar representations are recorded as a present demand with no choice. *)
let rec specialize_scalar_chain bindings tail =
  let demand rep vars = function
    | Boxed_scalar (Var id) ->
        Ident.Map.update id (function
          | None -> Some (Some rep)
          | Some previous -> Some (if previous = Some rep then previous else None)) vars
    | Boxed_scalar _ | Raw_scalar _ -> vars
  in
  let select (boxed, scalar, raw, code) (id, binding) =
    let wanted =
      if Ident.Set.mem id boxed then None
      else Option.join (Ident.Map.find_opt id scalar)
    in
    let binding, raw =
      match wanted, binding with
      | Some rep, Value (BoxScalar (actual, value)) when rep = actual ->
          Value (ScalarValue (rep, value)), Ident.Set.add id raw
      | Some rep, Value (Atom value) ->
          Value (ScalarValue (rep, Boxed_scalar value)), Ident.Set.add id raw
      | Some rep, Value (BigarrayAccess
          (({ operation = `Get; rank = 1; kind; layout; _ } as access), [arr; index]))
        when scalar_layout layout && scalar_rep kind = Some rep ->
          Value (ScalarLoad (access, arr, index)), Ident.Set.add id raw
      | Some rep, Join rhs ->
          Join (specialize_branch rep rhs), Ident.Set.add id raw
      | _ -> binding, raw
    in
    let boxed = Ident.Set.remove id boxed and scalar = Ident.Map.remove id scalar in
    let boxed, scalar =
      match binding with
      | Value (AssignScalar (slot, rep, value)) ->
          Ident.Set.add slot boxed, demand rep scalar value
      | Value (ScalarStore (access, arr, index, v)) ->
          let rep = Option.get (scalar_rep access.kind) in
          Variables.atom (Variables.atom boxed arr) index, demand rep scalar v
      | Value (BytesSetN (_, bytes, index, word)) ->
          let boxed = Variables.atom (Variables.atom boxed bytes) index in
          (match word with
           | Uint16 v -> Variables.atom boxed v, scalar
           | Int32 v -> boxed, demand (Integer_scalar Pint32) scalar v
           | Int64 v -> boxed, demand (Integer_scalar Pint64) scalar v)
      | Value (FloatArraySet (_, arr, index, v)) ->
          Variables.atom (Variables.atom boxed arr) index, demand Double_scalar scalar v
      | Value (SetFloatField (_, owner, v) | SetBoxedFloatField (_, owner, v)) ->
          Variables.atom boxed owner, demand Double_scalar scalar v
      | Value (FloatBinop (_, lhs, rhs) | FloatCompare (_, lhs, rhs)) ->
          boxed, demand Double_scalar (demand Double_scalar scalar lhs) rhs
      | Value (IntOfFloat value | FloatSign (_, value)) ->
          boxed, demand Double_scalar scalar value
      | Value (IntegerBinop (kind, _, lhs, rhs) | IntegerCompare (kind, _, lhs, rhs)) ->
          let rep = Integer_scalar kind in
          boxed, demand rep (demand rep scalar lhs) rhs
      | Value (IntegerNeg (kind, value) | IntOfInteger (kind, value)
               | IntegerConvert (kind, _, value)) ->
          boxed, demand (Integer_scalar kind) scalar value
      | Value (IntegerShift (kind, _, value, count)) ->
          Variables.atom boxed count, demand (Integer_scalar kind) scalar value
      | Value (ScalarValue (rep, value) | BoxScalar (rep, value)) ->
          boxed, demand rep scalar value
      | Value ce -> Variables.computation free_vars boxed ce, scalar
      | Join rhs -> Ident.Set.union boxed (free_vars rhs), scalar
    in
    boxed, scalar, raw, (id, binding) :: code
  in
  let _, _, raw, code =
    List.fold_left select (free_vars tail, Ident.Map.empty, Ident.Set.empty, []) bindings
  in
  let operand = function
    | Boxed_scalar (Var id) when Ident.Set.mem id raw -> Raw_scalar id
    | v -> v
  in
  List.fold_right (fun (id, binding) body ->
    let binding =
      match binding with
      | Value (AssignScalar (slot, rep, value)) ->
          Value (AssignScalar (slot, rep, operand value))
      | Value (ScalarStore (access, arr, index, v)) ->
          Value (ScalarStore (access, arr, index, operand v))
      | Value (BytesSetN (safe, bytes, index, Int32 v)) ->
          Value (BytesSetN (safe, bytes, index, Int32 (operand v)))
      | Value (BytesSetN (safe, bytes, index, Int64 v)) ->
          Value (BytesSetN (safe, bytes, index, Int64 (operand v)))
      | Value (FloatBinop (op, lhs, rhs)) -> Value (FloatBinop (op, operand lhs, operand rhs))
      | Value (FloatCompare (op, lhs, rhs)) -> Value (FloatCompare (op, operand lhs, operand rhs))
      | Value (FloatArraySet (safe, arr, index, value)) ->
          Value (FloatArraySet (safe, arr, index, operand value))
      | Value (IntOfFloat value) -> Value (IntOfFloat (operand value))
      | Value (FloatSign (op, value)) -> Value (FloatSign (op, operand value))
      | Value (BoxScalar (rep, value)) -> Value (BoxScalar (rep, operand value))
      | Value (IntegerBinop (kind, op, lhs, rhs)) ->
          Value (IntegerBinop (kind, op, operand lhs, operand rhs))
      | Value (IntegerCompare (kind, op, lhs, rhs)) ->
          Value (IntegerCompare (kind, op, operand lhs, operand rhs))
      | Value (IntOfInteger (kind, value)) -> Value (IntOfInteger (kind, operand value))
      | Value (IntegerConvert (src, dst, value)) ->
          Value (IntegerConvert (src, dst, operand value))
      | Value (IntegerNeg (kind, value)) -> Value (IntegerNeg (kind, operand value))
      | Value (IntegerShift (kind, op, value, count)) ->
          Value (IntegerShift (kind, op, operand value, count))
      | Value (ScalarValue (rep, v)) -> Value (ScalarValue (rep, operand v))
      | _ -> binding
    in
    bind_scalar_chain id binding body) code tail

and specialize_branch rep = function
  | Let (id, ce, body) -> Let (id, ce, specialize_branch rep body)
  | If (cond, yes, no) ->
      ScalarIf (rep, cond, specialize_scalar_arm rep [] yes, specialize_scalar_arm rep [] no)
  | Switch (scrutinee, cases) ->
      let arm (tag, body) = tag, specialize_scalar_arm rep [] body in
      Switch (scrutinee,
              { result_rep = Some rep;
                consts = List.map arm cases.consts;
                blocks = List.map arm cases.blocks;
                fail = Option.map (specialize_scalar_arm rep []) cases.fail })
  | StaticCatch (body, label, params, handler, _) ->
      StaticCatch (specialize_scalar_arm rep [] body, label, params,
                   specialize_scalar_arm rep [] handler, Some rep)
  | _ -> assert false

and specialize_scalar_arm rep bindings = function
  | Let (id, ce, body) -> specialize_scalar_arm rep (collect_scalar_binding id ce bindings) body
  | LetJoin (id, rhs, body) when boxed_branch rhs ->
      specialize_scalar_arm rep ((id, Join rhs) :: bindings) body
  | Halt value ->
      let id = Ident.create_local "scalar" in
      let bindings = (id, Value (ScalarValue (rep, Boxed_scalar value))) :: bindings in
      specialize_scalar_chain bindings (HaltScalar id)
  | (StaticRaise _ | Raise _) as exit -> specialize_scalar_chain bindings exit
  | branch when boxed_branch branch ->
      let id = Ident.create_local "scalar" in
      let tail = LetJoin (id, specialize_branch rep branch, HaltScalar id) in
      specialize_scalar_chain bindings tail
  | expr ->
      (* A complex arm computes an ordinary OCaml value before unboxing. *)
      let boxed = Ident.create_local "boxed_arm" in
      let raw = Ident.create_local "scalar" in
      let tail = LetJoin (boxed, expr,
                          Let (raw, ScalarValue (rep, Boxed_scalar (Var boxed)), HaltScalar raw)) in
      specialize_scalar_chain bindings tail

(* A raw backedge is only emitted when every occurrence of the function
   rewrites to a jump and the selected inputs have exclusively scalar uses.
   The public entry and all results use the ordinary boxed calling convention. *)
let map_loop_children visit ~tail = function
  | Let (id, ce, body) -> Let (id, ce, visit ~tail body)
  | MutLet (id, ce, body) -> MutLet (id, ce, visit ~tail body)
  | LetJoin (id, rhs, body) -> LetJoin (id, visit ~tail:false rhs, visit ~tail body)
  | LetRec (defs, body) -> LetRec (defs, visit ~tail body)
  | If (cond, yes, no) -> If (cond, visit ~tail yes, visit ~tail no)
  | ScalarIf (rep, cond, yes, no) ->
      ScalarIf (rep, cond, visit ~tail:false yes, visit ~tail:false no)
  | Switch (value, cases) ->
      let arm (tag, body) = tag, visit ~tail body in
      Switch (value, { cases with consts = List.map arm cases.consts;
                                  blocks = List.map arm cases.blocks;
                                  fail = Option.map (visit ~tail) cases.fail })
  | StringSwitch (value, cases, fail) ->
      StringSwitch (value, List.map (fun (tag, body) -> tag, visit ~tail body) cases,
                    Option.map (visit ~tail) fail)
  | StaticCatch (body, label, params, handler, rep) ->
      let tail = tail && Option.is_none rep in
      StaticCatch (visit ~tail body, label, params, visit ~tail handler, rep)
  | TryWith (body, exn, handler) ->
      TryWith (visit ~tail:false body, exn, visit ~tail:false handler)
  | While (cond, body) -> While (visit ~tail:false cond, visit ~tail:false body)
  | For (id, start, stop, dir, body) -> For (id, start, stop, dir, visit ~tail:false body)
  | expr -> expr

let scalarize_loop specialize (rb : rec_binding) =
  let lf = rb.def in
  let reps =
    List.map (fun (_, kind) ->
      match kind with
      | Lambda.Pfloatval -> Some Double_scalar
      | Pboxedintval kind -> Some (Integer_scalar kind)
      | _ -> None) lf.params
  in
  let loop_scalars =
    List.filter_map Fun.id
      (List.map2 (fun (id, _) rep ->
        Option.map (fun rep -> id, (rep, Ident.create_local "loop_box")) rep) lf.params reps)
  in
  if loop_scalars = [] || not (Ident.Set.mem rb.id (free_vars lf.body)) then None
  else
    let exception Boxed_use in
    let raw_ids = Ident.Set.of_list (List.map fst loop_scalars) in
    let raw_rep id = Option.map fst (List.assoc_opt id loop_scalars) in
    let owners = List.map (fun (_, (_, owner)) -> Var owner) loop_scalars in
    let keep_alive body = Let (Ident.create_local "keep", KeepAlive owners, body) in
    let found = ref false in
    let rec prepare ~tail expr =
      match expr with
      | Let (id, App (Var fn, args), Halt (Var result))
        when tail && Ident.same rb.id fn && Ident.same id result
             && List.length args = List.length reps ->
          found := true;
          let args = List.map2 (fun rep arg ->
            match rep with
            | None -> arg, None
            | Some rep ->
                let raw = Ident.create_local "loop_scalar" in
                Var raw, Some (raw, ScalarValue (rep, Boxed_scalar arg))) reps args
          in
          List.fold_right (fun (_, binding) body ->
            match binding with
            | None -> body
            | Some (raw, ce) -> Let (raw, ce, body))
            args (Let (id, Recur (List.map fst args), Halt (Var result)))
      | Halt (Var id) when tail ->
          keep_alive (match List.assoc_opt id loop_scalars with
          | None -> expr
          | Some (rep, owner) ->
              let boxed = Ident.create_local "loop_result" in
              If (Var owner, Halt (Var owner),
                  Let (boxed, BoxScalar (rep, Raw_scalar id), Halt (Var boxed))))
      | Halt _ when tail -> keep_alive expr
      | expr -> map_loop_children prepare ~tail expr
    in
    let scalar_operand rep = function
      | Boxed_scalar (Var id) when raw_rep id = Some rep -> Raw_scalar id
      | operand -> operand
    in
    let float = scalar_operand Double_scalar in
    let int kind = scalar_operand (Integer_scalar kind) in
    let check_ids uses =
      if not (Ident.Set.disjoint raw_ids uses) then raise Boxed_use
    in
    let check_atom value = check_ids (Variables.atom Ident.Set.empty value) in
    let rewrite_ce ce =
      let ce =
        match ce with
        | ScalarValue (rep, value) -> ScalarValue (rep, scalar_operand rep value)
        | AssignScalar (slot, rep, value) ->
            AssignScalar (slot, rep, scalar_operand rep value)
        | BoxScalar (rep, value) -> BoxScalar (rep, scalar_operand rep value)
        | FloatBinop (op, lhs, rhs) -> FloatBinop (op, float lhs, float rhs)
        | FloatCompare (op, lhs, rhs) -> FloatCompare (op, float lhs, float rhs)
        | FloatSign (op, value) -> FloatSign (op, float value)
        | IntOfFloat value -> IntOfFloat (float value)
        | FloatArraySet (safe, arr, index, value) -> FloatArraySet (safe, arr, index, float value)
        | SetFloatField (index, owner, v) -> SetFloatField (index, owner, float v)
        | SetBoxedFloatField (index, owner, v) -> SetBoxedFloatField (index, owner, float v)
        | ScalarStore (access, arr, index, value) ->
            let rep = Option.get (scalar_rep access.kind) in
            ScalarStore (access, arr, index, scalar_operand rep value)
        | IntegerBinop (kind, op, lhs, rhs) ->
            IntegerBinop (kind, op, int kind lhs, int kind rhs)
        | IntegerCompare (kind, op, lhs, rhs) ->
            IntegerCompare (kind, op, int kind lhs, int kind rhs)
        | IntOfInteger (kind, value) -> IntOfInteger (kind, int kind value)
        | IntegerConvert (src, dst, value) -> IntegerConvert (src, dst, int src value)
        | IntegerNeg (kind, value) -> IntegerNeg (kind, int kind value)
        | IntegerShift (kind, op, value, count) -> IntegerShift (kind, op, int kind value, count)
        | ce -> ce
      in
      check_ids (Variables.computation ~include_raw:false free_vars Ident.Set.empty ce);
      ce
    in
    (* The scalar pass has decided whether a backedge input still has an
       observable box. Keep that box as an owner when present. *)
    let boxes = Hashtbl.create 8 in
    let box_for_operand = function
      | Boxed_scalar value -> Some value
      | Raw_scalar value ->
          (match List.assoc_opt value loop_scalars with
          | Some (_, owner) -> Some (Var owner)
          | None -> Option.value ~default:(Some Unit) (Hashtbl.find_opt boxes value))
    in
    let rec validate ~tail expr =
      match expr with
      | Let (id, Recur args, body) ->
          List.iter check_atom args;
          let backedge_boxes =
            List.filter_map Fun.id (List.map2 (fun rep arg ->
              match rep, arg with
              | None, _ -> None
              | Some _, Var arg ->
                  (match Hashtbl.find boxes arg with
                  | Some value -> Some value
                  | None -> raise Boxed_use)
              | Some _, _ -> assert false) reps args)
          in
          keep_alive (Let (id, Recur (args @ backedge_boxes), body))
      | Let (id, ce, body) ->
          let ce = rewrite_ce ce in
          (match ce with
          | ScalarValue (_, value) -> Hashtbl.add boxes id (box_for_operand value)
          | _ -> ());
          Let (id, ce, validate ~tail body)
      | LetJoin (id, rhs, body) when returns_scalar rhs ->
          Hashtbl.add boxes id None;
          LetJoin (id, validate ~tail:false rhs, validate ~tail body)
      | MutLet (id, ce, body) -> MutLet (id, rewrite_ce ce, validate ~tail body)
      | expr ->
          (match expr with
          | Halt value | Raise value | If (value, _, _) | ScalarIf (_, value, _, _)
          | Switch (value, _) | StringSwitch (value, _, _) -> check_atom value
          | StaticRaise (_, args) -> List.iter check_atom args
          | For (_, first, last, _, _) -> List.iter check_atom [first; last]
          | LetRec (defs, _) ->
              List.iter (fun (rb : rec_binding) -> check_ids (free_vars rb.def.body)) defs
          | _ -> ());
          map_loop_children validate ~tail expr
    in
    let body = prepare ~tail:true lf.body in
    if not !found || Ident.Set.mem rb.id (free_vars body) then None
    else
      match validate ~tail:true (specialize body) with
      | body -> Some { lf with body; loop_scalars }
      | exception Boxed_use -> None

let with_entry_poll lf =
  if is_bounded_local lf.body then lf
  else { lf with body = Let (Ident.create_local "poll", PollFinalizers, lf.body) }

let rec specialize_scalar_bindings = function
  | Let _ as expr -> specialize_let_chain [] expr
  | LetJoin (_, rhs, _) as expr when boxed_branch rhs ->
      specialize_let_chain [] expr
  | MutLet (id, ce, body) ->
      MutLet (id, ce, specialize_scalar_bindings body)
  | LetJoin (id, rhs, body) ->
      LetJoin (id, specialize_scalar_bindings rhs, specialize_scalar_bindings body)
  | LetRec (defs, body) ->
      let defs =
        match defs with
        | [rb] ->
            let def = match scalarize_loop specialize_scalar_bindings rb with
              | Some def -> with_entry_poll def
              | None -> specialize_scalar_function rb.def
            in
            [{ rb with def }]
        | _ -> List.map (fun rb -> { rb with def = specialize_scalar_function rb.def }) defs
      in
      LetRec (defs, specialize_scalar_bindings body)
  | If (v, yes, no) ->
      If (v, specialize_scalar_bindings yes, specialize_scalar_bindings no)
  | ScalarIf (rep, v, yes, no) ->
      ScalarIf (rep, v, specialize_scalar_bindings yes, specialize_scalar_bindings no)
  | Switch (v, cases) ->
      Switch (v, { cases with consts = List.map specialize_scalar_case cases.consts;
                   blocks = List.map specialize_scalar_case cases.blocks;
                   fail = Option.map specialize_scalar_bindings cases.fail })
  | StringSwitch (v, cases, fail) ->
      StringSwitch (v, List.map specialize_scalar_case cases,
                    Option.map specialize_scalar_bindings fail)
  | StaticCatch (body, label, params, handler, result_rep) ->
      StaticCatch (specialize_scalar_bindings body, label, params,
                   specialize_scalar_bindings handler, result_rep)
  | TryWith (body, exn, handler) ->
      TryWith (specialize_scalar_bindings body, exn, specialize_scalar_bindings handler)
  | While (cond, body) ->
      While (specialize_scalar_bindings cond, specialize_scalar_bindings body)
  | For (id, start, stop, dir, body) ->
      For (id, start, stop, dir, specialize_scalar_bindings body)
  | expr -> expr

and specialize_let_chain bindings = function
  | Let (id, ce, body) ->
      let ce = match ce with Fun lf -> Fun (specialize_scalar_function lf) | _ -> ce in
      specialize_let_chain (collect_scalar_binding id ce bindings) body
  | LetJoin (id, rhs, body) when boxed_branch rhs ->
      let rhs = specialize_scalar_bindings rhs in
      specialize_let_chain ((id, Join rhs) :: bindings) body
  | tail ->
      let tail = specialize_scalar_bindings tail in
      if List.exists (function
        | _, Value (BoxScalar _ | AssignScalar _ | ScalarStore _ | FloatBinop _ | IntegerBinop _
                   | BytesSetN (_, _, _, (Int32 _ | Int64 _))
                   | ScalarValue _ | IntegerCompare _ | IntOfInteger _
                   | FloatCompare _ | IntOfFloat _ | FloatArraySet _ | SetFloatField _ | SetBoxedFloatField _) -> true
        | _ -> false) bindings
      then specialize_scalar_chain bindings tail
      else List.fold_left (fun body (id, binding) -> bind_scalar_chain id binding body) tail bindings

and specialize_scalar_function lf =
  with_entry_poll { lf with body = specialize_scalar_bindings lf.body }

and specialize_scalar_case : 'a. 'a * aexpr -> 'a * aexpr =
  fun (tag, arm) -> tag, specialize_scalar_bindings arm

let run program =
  { program with code = specialize_scalar_bindings program.code }
