(* Lambda -> ANF conversion and free-variable analysis. *)

include Anf_ir

exception Unsupported of string

let primitive_name p =
  let buf = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer buf in
  Format.fprintf ppf "%a" Printlambda.primitive p;
  Format.pp_print_flush ppf ();
  String.trim (Buffer.contents buf)

let rec describe (lam : Lambda.lambda) : string =
  match lam with
  | Lconst _ -> "non-integer, non-string constant"
  | Lvar _ | Lmutvar _ -> "variable"
  | Lapply _ -> "function application"
  | Lfunction _ -> "function value"
  | Llet (_, _, _, arg, _) | Lmutlet (_, _, arg, _) ->
      Printf.sprintf "let binding of %s" (describe arg)
  | Lletrec _ -> "recursive value binding"
  | Lprim (p, _, _) -> "primitive " ^ primitive_name p
  | Lswitch _ -> "switch"
  | Lstringswitch _ -> "string switch"
  | Lstaticraise _ -> "static raise"
  | Lstaticcatch _ -> "static catch"
  | Ltrywith _ -> "try ... with"
  | Lifthenelse _ -> "if/then/else"
  | Lsequence _ -> "sequence"
  | Lwhile _ -> "while loop"
  | Lfor _ -> "for loop"
  | Lassign _ -> "mutable assignment"
  | Lsend _ -> "method call"
  | Levent _ -> "event (internal)"
  | Lifused _ -> "ifused (internal)"

let parse_const_float (s : string) : float =
  match Float.of_string_opt s with
  | Some f -> f
  | None -> raise (Unsupported ("invalid float constant: " ^ s))

let rec conv_const_item (c : Lambda.structured_constant) : const_item =
  match c with
  | Const_int n -> C_int n
  | Const_char ch -> C_char ch
  | Const_immstring s -> C_string s
  | Const_float s -> C_float (parse_const_float s)
  | Const_int32 n -> C_int32 n
  | Const_int64 n -> C_int64 n
  | Const_nativeint n -> C_nativeint n
  | Const_float_array sl -> C_float_array (List.map parse_const_float sl)
  | Const_block (tag, items) -> C_block (tag, List.map conv_const_item items)

let conv_const (c : Lambda.structured_constant) : atom =
  match c with
  | Const_int n -> Int n
  | Const_char ch -> Char ch
  | Const_immstring s -> String s
  | Const_float s -> Float (parse_const_float s)
  | Const_int32 n -> Int32 n
  | Const_int64 n -> Int64 n
  | Const_nativeint n -> Nativeint n
  | Const_float_array sl -> ConstFloatArray (List.map parse_const_float sl)
  | Const_block (tag, items) -> ConstBlock (tag, List.map conv_const_item items)

module Lower_env = struct
  type t = {
    scalars : scalar_rep Ident.Map.t;
    imports : string -> exports option;
    slots : Lambda.value_kind Ident.Map.t;
    printing : Builtins.table option;
    selectors : Builtins.int_selection_table Lazy.t option;
    byte_access : Lambda.lambda -> Builtins.Byte_access.t option;
  }
end

let variable (env : Lower_env.t) id =
  match Ident.Map.find_opt id env.slots with
  | Some kind -> ModuleSlot (id, kind)
  | None -> Var id

let check_array_kind (_k : Lambda.array_kind) = ()

(* Guard the yielding, raising callback path before ARC liveness analysis.
   Idle polls need neither a shadow-stack frame nor an exception check. *)
let with_finalizer_poll body =
  Let (Ident.create_local "poll", PollFinalizers, body)

let with_poll_when due body =
  let ignored = Ident.create_local "loop_poll" in
  LetJoin (ignored, If (Var due, with_finalizer_poll (Halt Unit), Halt Unit), body)

(* Masking a distance from the first check works through tagged-int wraparound. *)
let with_periodic_finalizer_poll distance body =
  let phase = Ident.create_local "poll_phase" in
  let due = Ident.create_local "loop_poll_due" in
  Let (phase, Binop (And, distance, Int 63),
    Let (due, Binop (Cmp Ceq, Var phase, Int 0), with_poll_when due body))

let with_counted_loop_poll index start body =
  let due = Ident.create_local "loop_poll_due" in
  Let (due, LoopPollDue (Var index, start), with_poll_when due body)

let while_with_poll cond body =
  if is_bounded_local cond && is_bounded_local body then
    let counter = Ident.create_local "poll_counter" in
    let count = Ident.create_local "poll_count" in
    let next = Ident.create_local "poll_next" in
    let ignored = Ident.create_local "poll_tick" in
    let cond =
      Let (count, Atom (MutVar counter),
        Let (next, Binop (Add, Var count, Int 1),
          Let (ignored, Assign (counter, Var next),
            with_periodic_finalizer_poll (Var count) cond)))
    in
    MutLet (counter, Atom (Int 0), While (cond, body))
  else While (with_finalizer_poll cond, body)

let float_arithmetic = function
  | Lambda.Paddfloat -> Addf
  | Psubfloat -> Subf
  | Pmulfloat -> Mulf
  | Pdivfloat -> Divf
  | _ -> assert false

let unicode_scalar_test arg =
  let outside = Ident.create_local "outside_first_range" in
  let offset = Ident.create_local "scalar_offset" in
  let outside_high = Ident.create_local "outside_second_range" in
  (* Tagged unsigned comparisons reject negative integers as well. After
     subtraction, only the second scalar interval falls within its width. *)
  Let (outside, Binop (Isout, Int 0xD7FF, arg),
    If (Var outside,
      Let (offset, Binop (Sub, arg, Int 0xE000),
        Let (outside_high, Binop (Isout, Int (0x10FFFF - 0xE000), Var offset),
          If (Var outside_high, Halt (Int 0), Halt (Int 1)))),
      Halt (Int 1)))

let rec conv_tail (env : Lower_env.t) (lam : Lambda.lambda) : aexpr =
  conv_expr env lam (fun a -> Halt a)

and conv_atoms env (lams : Lambda.lambda list) (k : atom list -> aexpr) : aexpr =
  match lams with
  | [] -> k []
  | x :: xs -> conv_expr env x (fun a -> conv_atoms env xs (fun rest -> k (a :: rest)))

and conv_bigstring env symbol width unsafe args k =
  let checked = Int (if unsafe then 0 else 1) in
  conv_atoms env args (fun args -> k (Ccall (symbol, args @ [Int width; checked])))

and conv_byte_load env safe width b i k =
  conv_expr env b (fun b ->
    conv_expr env i (fun i -> k (BytesGetN (safe, width, b, i))))

and conv_byte_store env safe word b i v k =
  conv_expr env b (fun b -> conv_expr env i (fun i -> conv_expr env v (fun v ->
    k (BytesSetN (safe, b, i, word v)))))

and conv_fun env ?self (lf : Lambda.lfunction) : lfunction =
  match lf.kind with
  | Curried ->
      let body = conv_tail env lf.body in
      let periodic_poll =
        Option.fold ~none:false ~some:(fun id ->
          not (is_bounded_local body)
          && is_bounded_local ~backedge:(id, List.length lf.params) body) self
      in
      { params = lf.params; return = lf.return; private_entry = false;
        periodic_poll; loop_scalars = []; body }
  | Tupled ->
      let tup = Ident.create_local "tup" in
      let rec bind_fields i = function
        | [] -> conv_tail env lf.body
        | (p, vk) :: rest ->
            let kind = if vk = Lambda.Pintval then Immediate_field else Immutable_field in
            Let (p, Field (i, kind, Var tup), bind_fields (i + 1) rest)
      in
      { params = [ (tup, Lambda.Pgenval) ]; return = lf.return; private_entry = false;
        periodic_poll = false; loop_scalars = []; body = bind_fields 0 lf.params }

and conv_bind env vk (id : Ident.t) (rhs : Lambda.lambda) (k : unit -> aexpr) : aexpr =
  match rhs with
  | Levent (l, _) | Lifused (_, l) ->
      conv_bind env vk id l k
  | Lprim (Psetglobal _, [ l ], _) -> conv_bind env vk id l k
  | Llet (_, vk1, id1, arg1, body1) ->
      conv_let env vk1 id1 arg1 (fun () -> conv_bind env vk id body1 k)
  | Lmutlet (vk1, id1, arg1, body1) ->
      conv_mut_bind env vk1 id1 arg1 (fun () -> conv_bind env vk id body1 k)
  | Lletrec (bindings, body1) ->
      let rbs =
        List.map
          (fun (rb : Lambda.rec_binding) ->
            { id = rb.id; def = conv_fun env ~self:rb.id rb.def })
          bindings
      in
      LetRec (rbs, conv_bind env vk id body1 k)
  | Lsequence (a, b) ->
      conv_sequence env a (fun () -> conv_bind env vk id b k)
  | Lconst c -> Let (id, Atom (conv_const c), k ())
  | Lvar v -> Let (id, Atom (variable env v), k ())
  | Lmutvar v -> conv_mut_read env v id k
  | Lfunction lf -> Let (id, Fun (conv_fun env lf), k ())
  | Lassign (v, arg) ->
      conv_expr env arg (fun a -> Let (id, mut_assignment env v a, k ()))
  | Lapply _ | Lprim _ | Lsend _ -> (
      match rhs with
      | Lprim (Psequand, _, _)
      | Lprim (Psequor, _, _) ->
          LetJoin (id, conv_tail env rhs, k ())
      | _ -> conv_simple env ~result_kind:vk id rhs k)
  | Lifthenelse _ | Lswitch _ | Lstringswitch _ | Lstaticcatch _
  | Ltrywith _ ->
      LetJoin (id, conv_tail env rhs, k ())
  | Lwhile _ | Lfor _ ->
      conv_expr env rhs (fun a -> Let (id, Atom a, k ()))
  | Lstaticraise (i, args) ->
      (* A static raise is a terminator: the binding's continuation is
         unreachable and is dropped, exactly as [conv_expr env] does. The
         matcher's tuple-let optimization ([assign_pat]) can leave an
         [Lstaticraise] at the tail of a let chain used as a binding RHS. *)
      conv_atoms env args (fun vs -> StaticRaise (i, vs))

and conv_let env vk id rhs k =
  conv_bind env vk id rhs (fun () ->
    if Ident.Map.mem id env.slots then
      Let (Ident.create_local "publish", StoreModuleSlot (id, Var id), k ())
    else k ())

and conv_sequence env action k =
  match action with
  | Lambda.Lprim (Pgetglobal id, [], _) ->
      Let (Ident.create_local "import", ImportDependency (Ident.name id), k ())
  | _ -> conv_expr env action (fun _ -> k ())

and conv_mut_bind env vk (id : Ident.t) (rhs : Lambda.lambda) (k : unit -> aexpr) :
    aexpr =
  let t = Ident.create_local (Ident.name id ^ "_init") in
  conv_bind env vk t rhs (fun () ->
    let init = match Ident.Map.find_opt id env.scalars with
      | None -> Atom (Var t)
      | Some rep -> ScalarValue (rep, Boxed_scalar (Var t))
    in
    MutLet (id, init, k ()))

and conv_mut_read env slot id k =
  match Ident.Map.find_opt slot env.scalars with
  | None -> Let (id, Atom (MutVar slot), k ())
  | Some rep ->
      let raw = Ident.create_local "slot_value" in
      Let (raw, ReadScalarSlot (rep, slot),
        Let (id, BoxScalar (rep, Raw_scalar raw), k ()))

and mut_assignment env slot value =
  match Ident.Map.find_opt slot env.scalars with
  | None -> Assign (slot, value)
  | Some rep -> AssignScalar (slot, rep, Boxed_scalar value)

and conv_simple env ?(result_kind = Lambda.Pgenval) (id : Ident.t)
    (lam : Lambda.lambda) (k : unit -> aexpr) : aexpr =
  let emit_cexpr ce = Let (id, ce, k ()) in
  match lam with
  | Lsend (((Public | Cached) as dispatch), label, receiver, args, _) ->
      conv_expr env receiver (fun receiver ->
          conv_expr env label (fun label ->
              conv_atoms env args (fun values ->
                  let args =
                    match dispatch, values with
                    | Public, _ -> values
                    | Cached, _cache :: _position :: args -> args
                    | _ -> raise (Unsupported (describe lam))
                  in
                  let meth = Ident.create_local "method" in
                  Let (meth, Ccall ("ocamlcc_public_method", [receiver; label]),
                    emit_cexpr (App (Var meth, receiver :: args))))))
  | Lapply { ap_func; ap_args; ap_inlined; _ } -> (
      let { Lower_env.printing; selectors; byte_access; _ } = env in
      let select = Option.bind selectors (fun table -> Builtins.resolve_int_selection table ap_func) in
      let access = if ap_inlined = Never_inline then None else byte_access ap_func in
      match select, access, ap_args with
      | Some op, _, [ lhs; rhs ] ->
          conv_expr env lhs (fun a ->
              conv_expr env rhs (fun b -> emit_cexpr (IntSelect (op, a, b))))
      | _, Some (Load word), [ b; i ] ->
          Let (Ident.create_local "import", ImportDependency "Stdlib__Bytes",
            conv_byte_load env true (Byte_load.Boxed_word word) b i emit_cexpr)
      | _, Some (Store store), [ b; i; v ] ->
          let word v = match store with
            | Builtins.Byte_access.Word32 -> Byte_store.Int32 (Boxed_scalar v)
            | Word64 -> Byte_store.Int64 (Boxed_scalar v)
          in
          Let (Ident.create_local "import", ImportDependency "Stdlib__Bytes",
            conv_byte_store env true word b i v emit_cexpr)
      | _ -> (
          match Option.bind printing (fun table -> Builtins.resolve ~table ap_func) with
          | Some { symbol; arg_kind } -> (
              match ap_args with
              | [ arg ] ->
                  conv_expr env arg (fun a -> emit_cexpr (Builtin (symbol, arg_kind, a)))
              | _ -> raise (Unsupported (describe lam)))
          | None -> (
              match Option.map fst (Lambda_opt.imported_callee_and_unit env.imports ap_func) with
              | Some target when target.arity = List.length ap_args ->
                  let target =
                    if ap_inlined = Never_inline then
                      { target with inline_leaf = None; unicode_validation = None }
                    else target
                  in
                  conv_atoms env ap_args (fun args ->
                    match target.unicode_validation, args with
                    | Some validation, [arg] ->
                        let valid = Ident.create_local "scalar_valid" in
                        let result = Ident.create_local "scalar_checked" in
                        let success = match validation with
                          | Unicode_test -> Int 1 | Unicode_check -> arg in
                        let slow_target = { target with unicode_validation = None } in
                        let checked = LetJoin (valid, unicode_scalar_test arg,
                          If (Var valid, Halt success,
                            Let (result, DirectApp (slow_target, args), Halt (Var result)))) in
                        (match k () with
                        | Halt (Var output) when Ident.same output id -> checked
                        | continuation -> LetJoin (id, checked, continuation))
                    | _ -> emit_cexpr (DirectApp (target, args)))
              | _ ->
              conv_expr env ap_func (fun fn ->
                  conv_atoms env ap_args (fun args -> emit_cexpr (App (fn, args)))))))
  | Lprim (Pignore, [ arg ], _) ->
      conv_expr env arg (fun _ -> emit_cexpr (Atom Unit))
  | Lprim (Pbytes_to_string, [ arg ], _)
  | Lprim (Pbytes_of_string, [ arg ], _) ->
      conv_expr env arg (fun a -> emit_cexpr (Atom a))
  | Lprim (Pmakeblock (tag, mutability, _), args, _) -> (
      match args with
      | [] -> emit_cexpr (Atom Unit)
      | _ ->
          let scan = if mutability = Immutable then Scan_if_managed else Scan_all in
          conv_atoms env args (fun vs -> emit_cexpr (MakeBlock (tag, scan, vs))))
  | Lprim (Pmakelazyblock ltag, [ arg ], _) ->
      let sym =
        match ltag with
        | Lambda.Lazy_tag -> "caml_lazy_make_block"
        | Lambda.Forward_tag -> "caml_lazy_make_forward"
      in
      conv_expr env arg (fun av -> emit_cexpr (Ccall (sym, [ av ])))
  | Lprim (Pmakearray (kind, _), args, _) ->
      check_array_kind kind;
      conv_atoms env args (fun vs -> emit_cexpr (MakeArray (kind, vs)))
  | Lprim (Pduparray (kind, _), [ Lambda.Lconst (Const_block (_, items)) ], _) ->
      check_array_kind kind;
      emit_cexpr (MakeArray (kind, List.map conv_const items))
  | Lprim (Pduparray (kind, _), [ Lambda.Lconst (Const_float_array sl) ], _) ->
      check_array_kind kind;
      emit_cexpr (MakeArray (kind, List.map (fun s -> Float (parse_const_float s)) sl))
  | Lprim (Pfield (i, repr, mutability), [ arg ], _) ->
      let kind =
        match result_kind, repr, mutability with
        | Lambda.Pintval, _, _ | _, Lambda.Immediate, _ -> Immediate_field
        | _, Pointer, Immutable -> Immutable_field
        | _, Pointer, Mutable -> Mutable_field
      in
      conv_expr env arg (fun a -> emit_cexpr (Field (i, kind, a)))
  | Lprim (Pfield_computed, [ arg; idx ], _) ->
      conv_atoms env [ arg; idx ] (fun vs ->
          emit_cexpr (Ccall ("caml_obj_field", vs)))
  | Lprim (Psetfield (i, repr, _), [ arg; rhs ], _) ->
      conv_expr env arg (fun a ->
          conv_expr env rhs (fun v -> emit_cexpr (SetField (i, repr, a, v))))
  | Lprim (Psetfield_computed _, [ arg; idx; rhs ], _) ->
      conv_atoms env [ arg; idx; rhs ] (fun vs ->
          emit_cexpr (Ccall ("caml_obj_set_field", vs)))
  | Lprim (Pbigarrayref (unsafe, rank, kind, layout), args, _) ->
      let access = { operation = `Get; rank; kind; layout; checked = not unsafe } in
      conv_atoms env args (fun vs -> emit_cexpr (BigarrayAccess (access, vs)))
  | Lprim (Pbigarrayset (unsafe, 1, ((Pbigarray_float32 | Pbigarray_float64) as kind), layout), [arr; index; value], _)
    when scalar_layout layout ->
      let access = { operation = `Set; rank = 1; kind;
                     layout; checked = not unsafe } in
      conv_expr env arr (fun a -> conv_expr env index (fun i ->
        conv_float_operand env value (fun v -> emit_cexpr (ScalarStore (access, a, i, v)))))
  | Lprim (Pbigarrayset (unsafe, 1,
             ((Pbigarray_int32 | Pbigarray_int64 | Pbigarray_native_int) as kind),
             layout), [arr; index; value], _)
    when scalar_layout layout ->
      let access = { operation = `Set; rank = 1; kind;
                     layout; checked = not unsafe } in
      conv_atoms env [arr; index; value] (function
        | [a; i; v] -> emit_cexpr (ScalarStore (access, a, i, Boxed_scalar v))
        | _ -> assert false)
  | Lprim (Pbigarrayset (unsafe, rank, kind, layout), args, _) ->
      let access = { operation = `Set; rank; kind; layout; checked = not unsafe } in
      conv_atoms env args (fun vs -> emit_cexpr (BigarrayAccess (access, vs)))
  | Lprim (Pbigarraydim d, [ arg ], _) ->
      conv_expr env arg (fun a ->
          emit_cexpr (Ccall ("caml_ba_dim", [ a; Int (d - 1) ])))
  | Lprim (Pfloatfield i, [ arg ], _) ->
      conv_expr env arg (fun a ->
          let raw = Ident.create_local "float_field" in
          Let (raw, FloatField (i, a), emit_cexpr (BoxScalar (Double_scalar, Raw_scalar raw))))
  | Lprim (Psetfloatfield (i, _), [ arg; rhs ], _) ->
      conv_expr env arg (fun a ->
          conv_float_operand env rhs (fun v -> emit_cexpr (SetFloatField (i, a, v))))
  | Lprim (Poffsetref n, [ arg ], _) ->
      conv_expr env arg (fun a -> emit_cexpr (OffsetRef (n, a)))
  | Lprim ((Pstringlength | Pbyteslength), [ arg ], _) ->
      conv_expr env arg (fun a -> emit_cexpr (Unop (String_length, a)))
  | Lprim ((Pstringrefu | Pbytesrefu), [ s; i ], _) ->
      conv_expr env s (fun sa ->
          conv_expr env i (fun ia -> emit_cexpr (StringGet (false, sa, ia))))
  | Lprim ((Pstringrefs | Pbytesrefs), [ s; i ], _) ->
      conv_expr env s (fun sa ->
          conv_expr env i (fun ia -> emit_cexpr (StringGet (true, sa, ia))))
  | Lprim (Pbytessetu, [ s; i; c ], _) ->
      conv_expr env s (fun sa ->
          conv_expr env i (fun ia ->
              conv_expr env c (fun ca -> emit_cexpr (BytesSet (false, sa, ia, ca)))))
  | Lprim (Pbytessets, [ s; i; c ], _) ->
      conv_expr env s (fun sa ->
          conv_expr env i (fun ia ->
              conv_expr env c (fun ca -> emit_cexpr (BytesSet (true, sa, ia, ca)))))
  | Lprim (Parraylength kind, [ arg ], _) ->
      check_array_kind kind;
      conv_expr env arg (fun a -> emit_cexpr (Unop (Array_length, a)))
  | Lprim (Parrayrefu kind, [ arr; i ], _) ->
      check_array_kind kind;
      conv_expr env arr (fun aa ->
          conv_expr env i (fun ia -> emit_cexpr (ArrayGet (false, kind, aa, ia))))
  | Lprim (Parrayrefs kind, [ arr; i ], _) ->
      check_array_kind kind;
      conv_expr env arr (fun aa ->
          conv_expr env i (fun ia -> emit_cexpr (ArrayGet (true, kind, aa, ia))))
  | Lprim (Parraysetu kind, [ arr; i; v ], _) ->
      check_array_kind kind;
      conv_expr env arr (fun aa ->
          conv_expr env i (fun ia ->
              conv_expr env v (fun va ->
                  emit_cexpr (ArraySet (false, kind, aa, ia, va)))))
  | Lprim (Parraysets kind, [ arr; i; v ], _) ->
      check_array_kind kind;
      conv_expr env arr (fun aa ->
          conv_expr env i (fun ia ->
              conv_expr env v (fun va ->
                  emit_cexpr (ArraySet (true, kind, aa, ia, va)))))
  | Lprim (((Pperform | Prunstack | Presume | Preperform) as prim), args, _) ->
      let symbol =
        match prim with
        | Pperform -> "ocamlcc_effect_perform"
        | Prunstack -> "ocamlcc_effect_runstack"
        | Presume -> "ocamlcc_effect_resume"
        | Preperform -> "ocamlcc_effect_reperform"
        | _ -> assert false
      in
      let abi = Ccalls.find symbol in
      if List.length args <> abi.argc then raise (Unsupported (describe lam));
      conv_atoms env args (fun vs -> emit_cexpr (Ccall (symbol, vs)))
  | Lprim (Pccall pd, args, _) -> (
      match (pd.Primitive.prim_name, args) with
      | "caml_create_bytes", [ len ] ->
          conv_expr env len (fun la -> emit_cexpr (CreateBytes la))
      | "caml_array_make", [ len; init ] ->
          conv_expr env len (fun la ->
              conv_expr env init (fun ia -> emit_cexpr (MakeArrayInit (la, ia))))
      | "caml_fresh_oo_id", [ arg ] ->
          conv_expr env arg (fun a -> emit_cexpr (Ccall ("caml_fresh_oo_id", [ a ])))
      | ( "caml_string_equal" | "caml_bytes_equal" ), args ->
          conv_atoms env args (fun vs -> emit_cexpr (Ccall ("caml_equal", vs)))
      | ( "caml_string_notequal" | "caml_bytes_notequal" ), args ->
          conv_atoms env args (fun vs -> emit_cexpr (Ccall ("caml_notequal", vs)))
      | ( "caml_string_compare" | "caml_bytes_compare" ), args ->
          conv_atoms env args (fun vs -> emit_cexpr (Ccall ("caml_compare", vs)))
      | ( "caml_string_lessthan" | "caml_bytes_lessthan" ), args ->
          conv_atoms env args (fun vs -> emit_cexpr (Ccall ("caml_lessthan", vs)))
      | ( "caml_string_lessequal" | "caml_bytes_lessequal" ), args ->
          conv_atoms env args (fun vs -> emit_cexpr (Ccall ("caml_lessequal", vs)))
      | ( "caml_string_greaterthan" | "caml_bytes_greaterthan" ), args ->
          conv_atoms env args (fun vs -> emit_cexpr (Ccall ("caml_greaterthan", vs)))
      | ( "caml_string_greaterequal" | "caml_bytes_greaterequal" ), args ->
          conv_atoms env args (fun vs -> emit_cexpr (Ccall ("caml_greaterequal", vs)))
      | "caml_restore_raw_backtrace", [ ex; bt ] ->
          conv_expr env ex (fun _ -> conv_expr env bt (fun _ -> emit_cexpr (Atom (Int 0))))
      | sym, args when pd.Primitive.prim_arity = List.length args -> (
          (* C externals: [caml_*] primitives must be registered with their
             C ABI in [Ccalls] (unknown ones are rejected — they are
             compiler/runtime implementation details, not a user ABI);
             registered runtime entries use ocamlcc's boxed ABI.
             User externals use the native entry and its declared ABI. *)
          if String.starts_with ~prefix:"caml_" sym then
            match Ccalls.find_opt sym with
            | Some abi when abi.Ccalls.argc = List.length args ->
                conv_atoms env args (fun vs -> emit_cexpr (Ccall (sym, vs)))
            | Some _ ->
                raise
                  (Unsupported
                    (Printf.sprintf "C primitive %s with %d arguments" sym
                       (List.length args)))
            | None -> raise (Unsupported (describe lam))
          else if Ccalls.is_known sym then
            conv_atoms env args (fun vs -> emit_cexpr (Ccall (sym, vs)))
          else conv_atoms env args (fun vs ->
            let call = NativeCcall (pd, vs) in
            match native_scalar pd.prim_native_repr_res with
            | None -> emit_cexpr call
            | Some rep ->
                let raw = Ident.create_local "native_result" in
                Let (raw, call, emit_cexpr (BoxScalar (rep, Raw_scalar raw)))))
      | _ -> raise (Unsupported (describe lam)))
  | Lprim (Pgetglobal id, [], _) -> emit_cexpr (GetGlobal (Ident.name id))
  | Lprim (Praise _, [ arg ], _) ->
      conv_expr env arg (fun a -> Raise a)
  | Lprim (Pisint, [ arg ], _) ->
      conv_expr env arg (fun a -> emit_cexpr (Unop (Isint, a)))
  | Lprim (Pnegint, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Neg, av)))
  | Lprim (Pnot, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Not, av)))
  | Lprim (Poffsetint n, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Offset n, av)))
  | Lprim (Paddint, [ a; c ], _) -> binop env Add a c emit_cexpr
  | Lprim (Psubint, [ a; c ], _) -> binop env Sub a c emit_cexpr
  | Lprim (Pmulint, [ a; c ], _) -> binop env Mul a c emit_cexpr
  | Lprim (Pdivint _, [ a; c ], _) -> binop env Div a c emit_cexpr
  | Lprim (Pmodint _, [ a; c ], _) -> binop env Mod a c emit_cexpr
  | Lprim (Pandint, [ a; c ], _) -> binop env And a c emit_cexpr
  | Lprim (Porint, [ a; c ], _) -> binop env Or a c emit_cexpr
  | Lprim (Pxorint, [ a; c ], _) -> binop env Xor a c emit_cexpr
  | Lprim (Plslint, [ a; c ], _) -> binop env Lsl a c emit_cexpr
  | Lprim (Plsrint, [ a; c ], _) -> binop env Lsr a c emit_cexpr
  | Lprim (Pasrint, [ a; c ], _) -> binop env Asr a c emit_cexpr
  | Lprim (Pintcomp cmp, [ a; c ], _) -> binop env (Cmp cmp) a c emit_cexpr
  | Lprim (Pcompare_ints, [ a; c ], _) -> binop env Compare_ints a c emit_cexpr
  | Lprim (Pisout, [ a; c ], _) -> binop env Isout a c emit_cexpr
  | Lprim (Pfloatofint, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Float_of_int, av)))
  | Lprim (Pintoffloat, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Int_of_float, av)))
  | Lprim (Pnegfloat, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Fneg, av)))
  | Lprim (Pabsfloat, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Fabs, av)))
  | Lprim (((Paddfloat | Psubfloat | Pmulfloat | Pdivfloat) as prim), [ a; c ], _) ->
      binop env (Float_arithmetic (float_arithmetic prim)) a c emit_cexpr
  | Lprim (Pfloatcomp cmp, [ a; c ], _) -> binop env (Fcmp cmp) a c emit_cexpr
  | Lprim (Pcompare_floats, [ a; c ], _) -> binop env Compare_floats a c emit_cexpr
  | Lprim (Pbintofint bi, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Bint_of_int bi, av)))
  | Lprim (Pintofbint bi, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Int_of_bint bi, av)))
  | Lprim (Pcvtbint (src, dst), [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Bint_cvt (src, dst), av)))
  | Lprim (Pnegbint bi, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Unop (Bint_neg bi, av)))
  | Lprim (Paddbint bi, [ a; c ], _) -> binop env (Bint_arith (bi, Add_int)) a c emit_cexpr
  | Lprim (Psubbint bi, [ a; c ], _) -> binop env (Bint_arith (bi, Sub_int)) a c emit_cexpr
  | Lprim (Pmulbint bi, [ a; c ], _) -> binop env (Bint_arith (bi, Mul_int)) a c emit_cexpr
  | Lprim (Pdivbint { size; _ }, [ a; c ], _) ->
      binop env (Bint_arith (size, Div_int)) a c emit_cexpr
  | Lprim (Pmodbint { size; _ }, [ a; c ], _) ->
      binop env (Bint_arith (size, Rem_int)) a c emit_cexpr
  | Lprim (Pandbint bi, [ a; c ], _) -> binop env (Bint_arith (bi, And_int)) a c emit_cexpr
  | Lprim (Porbint bi, [ a; c ], _) -> binop env (Bint_arith (bi, Or_int)) a c emit_cexpr
  | Lprim (Pxorbint bi, [ a; c ], _) -> binop env (Bint_arith (bi, Xor_int)) a c emit_cexpr
  | Lprim (Plslbint bi, [ a; c ], _) -> binop env (Bint_shift (bi, Left_shift)) a c emit_cexpr
  | Lprim (Plsrbint bi, [ a; c ], _) -> binop env (Bint_shift (bi, Logical_right)) a c emit_cexpr
  | Lprim (Pasrbint bi, [ a; c ], _) -> binop env (Bint_shift (bi, Arithmetic_right)) a c emit_cexpr
  | Lprim (Pbintcomp (bi, cmp), [ a; c ], _) ->
      binop env (Bint_cmp (bi, cmp)) a c emit_cexpr
  | Lprim (Pcompare_bints bi, [ a; c ], _) ->
      binop env (Compare_bints bi) a c emit_cexpr
  | Lprim (Patomic_load, [ ptr; idx ], _) ->
      conv_atoms env [ ptr; idx ] (fun vs ->
          emit_cexpr (Ccall ("caml_atomic_load_field", vs)))
  | Lprim (Patomic_load, [ ptr ], _) ->
      conv_expr env ptr (fun p ->
          emit_cexpr (Ccall ("caml_atomic_load_field", [ p; Int 0 ])))
  | Lprim (Pbswap16, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (Bswap16 av))
  | Lprim (Pbbswap bi, [ a ], _) ->
      conv_expr env a (fun av -> emit_cexpr (BswapBint (bi, av)))
  | Lprim ((Pstring_load_16 unsafe | Pbytes_load_16 unsafe), [ s; i ], _) ->
      conv_byte_load env (not unsafe) Byte_load.Uint16 s i emit_cexpr
  | Lprim ((Pstring_load_32 unsafe | Pbytes_load_32 unsafe), [ s; i ], _) ->
      conv_byte_load env (not unsafe) (Byte_load.Boxed_word Word32) s i emit_cexpr
  | Lprim ((Pstring_load_64 unsafe | Pbytes_load_64 unsafe), [ s; i ], _) ->
      conv_byte_load env (not unsafe) (Byte_load.Boxed_word Word64) s i emit_cexpr
  | Lprim (Pbytes_set_16 unsafe, [ b; i; v ], _) ->
      conv_byte_store env (not unsafe) (fun v -> Byte_store.Uint16 v) b i v emit_cexpr
  | Lprim (Pbytes_set_32 unsafe, [ b; i; v ], _) ->
      conv_byte_store env (not unsafe) (fun v -> Byte_store.Int32 (Boxed_scalar v)) b i v emit_cexpr
  | Lprim (Pbytes_set_64 unsafe, [ b; i; v ], _) ->
      conv_byte_store env (not unsafe) (fun v -> Byte_store.Int64 (Boxed_scalar v)) b i v emit_cexpr
  | Lprim (Pbigstring_load_16 unsafe, ([ _; _ ] as args), _) ->
      conv_bigstring env "ocamlcc_bigstring_get" 2 unsafe args emit_cexpr
  | Lprim (Pbigstring_load_32 unsafe, ([ _; _ ] as args), _) ->
      conv_bigstring env "ocamlcc_bigstring_get" 4 unsafe args emit_cexpr
  | Lprim (Pbigstring_load_64 unsafe, ([ _; _ ] as args), _) ->
      conv_bigstring env "ocamlcc_bigstring_get" 8 unsafe args emit_cexpr
  | Lprim (Pbigstring_set_16 unsafe, ([ _; _; _ ] as args), _) ->
      conv_bigstring env "ocamlcc_bigstring_set" 2 unsafe args emit_cexpr
  | Lprim (Pbigstring_set_32 unsafe, ([ _; _; _ ] as args), _) ->
      conv_bigstring env "ocamlcc_bigstring_set" 4 unsafe args emit_cexpr
  | Lprim (Pbigstring_set_64 unsafe, ([ _; _; _ ] as args), _) ->
      conv_bigstring env "ocamlcc_bigstring_set" 8 unsafe args emit_cexpr
  | Lprim (Pctconst c, _, _) ->
      let atom =
        match c with
        | Big_endian -> Int (if Sys.big_endian then 1 else 0)
        | Word_size -> Int 64
        | Int_size -> Int 63
        | Max_wosize -> Int ((1 lsl 29) - 1)
        | Ostype_unix -> Int (if Sys.win32 then 0 else 1)
        | Ostype_win32 -> Int (if Sys.win32 then 1 else 0)
        | Ostype_cygwin -> Int 0
        | Backend_type -> Int 0
        | Standard_library_default -> String ""
      in
      emit_cexpr (Atom atom)
  | Lprim (Popaque, [arg], _) ->
      conv_expr env arg (fun value -> emit_cexpr (Ccall ("ocamlcc_opaque_identity", [value])))
  | Lprim (Ppoll, _, _) -> with_finalizer_poll (emit_cexpr (Atom Unit))
  | _ -> raise (Unsupported (describe lam))

(* A typed store demands a double. Propagate that demand only into local
   scalar expressions. Every other expression uses the ordinary value ABI. *)
and conv_float_operand env lam k =
  let bind ce =
    let id = Ident.create_local "scalar" in
    Let (id, ce, k (Raw_scalar id))
  in
  match lam with
  | Lambda.Lprim (Pbigarrayref (unsafe, 1, ((Pbigarray_float32 | Pbigarray_float64) as kind), layout), [arr; index], _)
    when scalar_layout layout ->
      let access = { operation = `Get; rank = 1; kind;
                     layout; checked = not unsafe } in
      conv_expr env arr (fun a -> conv_expr env index (fun i -> bind (ScalarLoad (access, a, i))))
  | Lprim (((Paddfloat | Psubfloat | Pmulfloat | Pdivfloat) as prim), [lhs; rhs], _) ->
      conv_float_operand env lhs (fun l ->
          conv_float_operand env rhs (fun r -> bind (FloatBinop (float_arithmetic prim, l, r))))
  | Lifthenelse (cond, yes, no) ->
      conv_expr env cond (fun cond ->
          let id = Ident.create_local "scalar_join" in
          let branches = ScalarIf (Double_scalar, cond, conv_float_tail env yes, conv_float_tail env no) in
          LetJoin (id, branches, k (Raw_scalar id)))
  | _ -> conv_expr env lam (fun a -> k (Boxed_scalar a))

and conv_float_tail env lam =
  conv_float_operand env lam (function
    | Raw_scalar id -> HaltScalar id
    | Boxed_scalar value ->
        let id = Ident.create_local "scalar" in
        Let (id, ScalarValue (Double_scalar, Boxed_scalar value), HaltScalar id))

and binop env op a c emit_cexpr =
  conv_expr env a (fun av -> conv_expr env c (fun cv -> emit_cexpr (Binop (op, av, cv))))

and conv_expr env (lam : Lambda.lambda) (k : atom -> aexpr) : aexpr =
  match lam with
  | Lconst c -> k (conv_const c)
  | Lvar id -> k (variable env id)
  | Lmutvar slot ->
      (match Ident.Map.find_opt slot env.scalars with
      | None -> k (MutVar slot)
      | Some _ ->
          let id = Ident.create_local "slot_read" in
          conv_mut_read env slot id (fun () -> k (Var id)))
  | Levent (l, _) | Lifused (_, l) ->
      conv_expr env l k
  | Lprim (Psetglobal _, [ body ], _) -> conv_expr env body k
  | Llet (_, vk, id, arg, body) ->
      conv_let env vk id arg (fun () -> conv_expr env body k)
  | Lmutlet (vk, id, arg, body) ->
      conv_mut_bind env vk id arg (fun () -> conv_expr env body k)
  | Lletrec (bindings, body) ->
      let rbs =
        List.map
          (fun (rb : Lambda.rec_binding) ->
            { id = rb.id; def = conv_fun env ~self:rb.id rb.def })
          bindings
      in
      LetRec (rbs, conv_expr env body k)
  | Lsequence (a, b) -> conv_sequence env a (fun () -> conv_expr env b k)
  | Lfunction lf ->
      let id = Ident.create_local "anon" in
      Let (id, Fun (conv_fun env lf), k (Var id))
  | Lassign (id, rhs) ->
      let t = Ident.create_local "assign" in
      conv_expr env rhs (fun a -> Let (t, mut_assignment env id a, k (Var t)))
  | Lprim (Psequand, [ a; b ], _) ->
      let e =
        conv_expr env a (fun ca -> If (ca, conv_tail env b, Halt (Int 0)))
      in
      wrap_or_tail e k
  | Lprim (Psequor, [ a; b ], _) ->
      let e =
        conv_expr env a (fun ca -> If (ca, Halt (Int 1), conv_tail env b))
      in
      wrap_or_tail e k
  | Lifthenelse (cond, th, el) ->
      let e =
        conv_expr env cond (fun ca -> If (ca, conv_tail env th, conv_tail env el))
      in
      wrap_or_tail e k
  | Lswitch (scrut, sw, _) ->
      let e =
        conv_expr env scrut (fun sa ->
            Switch
              ( sa,
                { result_rep = None;
                  consts = List.map (fun (n, arm) -> (n, conv_tail env arm)) sw.sw_consts;
                  blocks =
                    List.map (fun (t, arm) -> (t, conv_tail env arm)) sw.sw_blocks;
                  fail = Option.map (conv_tail env) sw.sw_failaction } ))
      in
      wrap_or_tail e k
  | Lstringswitch (scrut, cases, fail, _) ->
      let e =
        conv_expr env scrut (fun sa ->
            StringSwitch
              ( sa,
                List.map (fun (s, arm) -> (s, conv_tail env arm)) cases,
                Option.map (conv_tail env) fail ))
      in
      wrap_or_tail e k
  | Lstaticcatch (body, (id, binders), handler) ->
      let e =
        StaticCatch
          (conv_tail env body, id, List.map fst binders, conv_tail env handler, None)
      in
      wrap_or_tail e k
  | Lstaticraise (id, args) ->
      conv_atoms env args (fun vs -> StaticRaise (id, vs))
  | Ltrywith (body, exn_id, handler) ->
      let e = TryWith (conv_tail env body, exn_id, conv_tail env handler) in
      wrap_or_tail e k
  | Lwhile (cond, body) ->
      seq_stmt (while_with_poll (conv_tail env cond) (conv_tail env body)) (k Unit)
  | Lfor (id, start_e, stop_e, dir, body) ->
      conv_expr env start_e (fun sa ->
          conv_expr env stop_e (fun ea ->
              seq_stmt (For (id, sa, ea, dir, with_counted_loop_poll id sa (conv_tail env body))) (k Unit)))
  | Lapply _ | Lprim _ | Lsend _ ->
      let id = Ident.create_local "anf" in
      conv_simple env id lam (fun () -> k (Var id))

and wrap_or_tail e k =
  (* Avoid duplicating continuations across branches: only inline [Halt]. *)
  let id = Ident.create_local "join" in
  match k (Var id) with
  | Halt (Var v) when Ident.same v id -> e
  | cont -> LetJoin (id, e, cont)

and seq_stmt (stmt : aexpr) (next : aexpr) : aexpr =
  let id = Ident.create_local "seq" in
  LetJoin (id, stmt, next)

let lower ?(use_builtins = true) ?(include_dirs = []) ?stdlib_dir ?(imports = [])
    ?(load_exports = fun _ -> None) ~collect_exports (program : Lambda.program) :
    (program * (int list * Ident.t) list, string) result =
  let printing = if use_builtins then Some (Builtins.load ~include_dirs ()) else None in
  let stdlib_dir =
    match stdlib_dir with
    | None when use_builtins -> Some Config.standard_library
    | dir -> dir
  in
  let selectors =
    Option.map
      (fun stdlib_dir -> lazy (Builtins.load_int_selection ~include_dirs ~stdlib_dir))
      stdlib_dir
  in
  let imports name =
    match List.assoc_opt name imports with
    | Some _ as known -> known
    | None -> load_exports name
  in
  try
    let is_array_initializer =
      Option.fold ~none:(fun _ -> false)
        ~some:(fun stdlib_dir -> Builtins.array_initializer ~include_dirs ~stdlib_dir)
        stdlib_dir
    in
    let optimized =
      Lambda_opt.optimize ~imports ~selectors ~is_array_initializer
        ~collect_exports program.code
    in
    let env =
      let byte_access =
        Option.fold ~none:(fun _ -> None)
          ~some:(fun stdlib_dir -> Builtins.Byte_access.resolve ~include_dirs ~stdlib_dir)
          stdlib_dir
      in
      { Lower_env.scalars = optimized.scalars; imports; slots = optimized.slots;
        printing; selectors; byte_access }
    in
    let anf =
      Anf_scalar.run
        { module_ident = program.module_ident; code = conv_tail env optimized.code;
          value_kinds = optimized.value_kinds; inline_bodies = optimized.inline_bodies }
    in
    Ok (anf, optimized.export_ids)
  with Unsupported what -> Error what

let of_lambda ?use_builtins ?include_dirs ?stdlib_dir program =
  lower ?use_builtins ?include_dirs ?stdlib_dir ~collect_exports:false program
  |> Result.map fst
