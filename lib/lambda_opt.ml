open Anf_ir

let imported_callee_and_unit imports callee =
  let open Lambda in
  let rec resolve path = function
    | Lprim (Pfield (slot, Pointer, Immutable), [owner], _) ->
        resolve (slot :: path) owner
    | Lprim (Pgetglobal id, [], _) ->
        Option.bind (imports (Ident.name id))
          (fun exports -> Option.map (fun fn -> fn, id) (List.assoc_opt path exports))
    | _ -> None
  in
  resolve [] callee

(* Drop zero-occurrence [Alias] and [StrictOpt] let bindings before ANF
   lowering. [Matching] shares catch arms across constructors with different
   field arities and emits [Llet (Alias, _, w, Pfield i p, body)] for unused
   wildcard bindings; per [lambda.mli], 0-occurrence [Alias] / [StrictOpt]
   bindings must be discarded rather than evaluated out of bounds. *)
let drop_unused_alias_lets (lam : Lambda.lambda) : Lambda.lambda =
  let rec go (lam : Lambda.lambda) : Lambda.lambda * Ident.Set.t =
    match lam with
    | Lambda.Lvar id | Lambda.Lmutvar id -> (lam, Ident.Set.singleton id)
    | Lambda.Lconst _ -> (lam, Ident.Set.empty)
    | Lambda.Llet (((Lambda.Alias | Lambda.StrictOpt) as kind), vk, id, arg, body) ->
        let body', body_fvs = go body in
        if not (Ident.Set.mem id body_fvs) then (body', body_fvs)
        else
          let arg', arg_fvs = go arg in
          ( Lambda.Llet (kind, vk, id, arg', body'),
            Ident.Set.union arg_fvs (Ident.Set.remove id body_fvs) )
    | Lambda.Llet (Lambda.Strict, vk, id, arg, body) ->
        let arg', arg_fvs = go arg in
        let body', body_fvs = go body in
        ( Lambda.Llet (Lambda.Strict, vk, id, arg', body'),
          Ident.Set.union arg_fvs (Ident.Set.remove id body_fvs) )
    | Lambda.Lmutlet (vk, id, arg, body) ->
        let arg', arg_fvs = go arg in
        let body', body_fvs = go body in
        ( Lambda.Lmutlet (vk, id, arg', body'),
          Ident.Set.union arg_fvs (Ident.Set.remove id body_fvs) )
    | Lambda.Lletrec (decls, body) ->
        let fvs = ref Ident.Set.empty in
        let decls' =
          List.map
            (fun (rb : Lambda.rec_binding) ->
              let def =
                Lambda.map_lfunction
                  (fun b ->
                    let b', bfvs = go b in
                    let bfvs =
                      List.fold_left
                        (fun s (p, _) -> Ident.Set.remove p s)
                        bfvs rb.def.params
                    in
                    fvs := Ident.Set.union !fvs bfvs;
                    b')
                  rb.def
              in
              { rb with Lambda.def })
            decls
        in
        let body', body_fvs = go body in
        let all_fvs = Ident.Set.union !fvs body_fvs in
        let all_fvs =
          List.fold_left
            (fun s (rb : Lambda.rec_binding) -> Ident.Set.remove rb.id s)
            all_fvs decls
        in
        (Lambda.Lletrec (decls', body'), all_fvs)
    | Lambda.Lfunction lf ->
        let body_fvs = ref Ident.Set.empty in
        let def =
          Lambda.map_lfunction
            (fun b ->
              let b', bfvs = go b in
              body_fvs := bfvs;
              b')
            lf
        in
        let fvs =
          List.fold_left
            (fun s (p, _) -> Ident.Set.remove p s)
            !body_fvs lf.params
        in
        (Lambda.Lfunction def, fvs)
    | Lambda.Lstaticcatch (body, (id, params), handler) ->
        let body', body_fvs = go body in
        let handler', handler_fvs = go handler in
        let handler_fvs =
          List.fold_left
            (fun s (p, _) -> Ident.Set.remove p s)
            handler_fvs params
        in
        ( Lambda.Lstaticcatch (body', (id, params), handler'),
          Ident.Set.union body_fvs handler_fvs )
    | Lambda.Ltrywith (body, param, handler) ->
        let body', body_fvs = go body in
        let handler', handler_fvs = go handler in
        ( Lambda.Ltrywith (body', param, handler'),
          Ident.Set.union body_fvs (Ident.Set.remove param handler_fvs) )
    | Lambda.Lfor (v, lo, hi, dir, body) ->
        let lo', lo_fvs = go lo in
        let hi', hi_fvs = go hi in
        let body', body_fvs = go body in
        ( Lambda.Lfor (v, lo', hi', dir, body'),
          Ident.Set.union lo_fvs
            (Ident.Set.union hi_fvs (Ident.Set.remove v body_fvs)) )
    | Lambda.Lassign (id, rhs) ->
        let rhs', rhs_fvs = go rhs in
        (Lambda.Lassign (id, rhs'), Ident.Set.add id rhs_fvs)
    | _ ->
        let fvs = ref Ident.Set.empty in
        let child sub =
          let sub', sub_fvs = go sub in
          fvs := Ident.Set.union !fvs sub_fvs;
          sub'
        in
        let lam' = Lambda.shallow_map child lam in
        (lam', !fvs)
  in
  fst (go lam)

type call_uses = Calls of { arity : int; count : int } | Other_use

(* Inline before lowering creates closures and inserts polls. Lambda identifiers
   are globally unique. The compiler-libs copier freshens them, but leaves
   static exit labels alone. Freshen labels in the scope of their catch. *)
let inline_local_calls ~imports code =
  let open Lambda in
  let module Labels = Map.Make (Int) in
  let next_label = ref 0 in
  let uses = ref Ident.Map.empty in
  let callbacks = ref Ident.Set.empty in
  let callback_limit = 768 in
  let mark_other id = uses := Ident.Map.add id Other_use !uses in
  let rec size expr =
    (match expr with
    | Lstaticcatch (_, (id, _), _) | Lstaticraise (id, _) ->
        next_label := max !next_label id
    | _ -> ());
    let n = ref 1 in
    iter_head_constructor (fun child -> n := !n + size child) expr;
    !n
  in
  let rec record_uses skip = function
    | Lapply { ap_func = Lvar id; ap_args; _ } when not (Ident.Set.mem id skip) ->
        let arity = List.length ap_args in
        let use = match Ident.Map.find_opt id !uses with
          | None -> Calls { arity; count = 1 }
          | Some (Calls previous) when previous.arity = arity ->
              Calls { previous with count = previous.count + 1 }
          | Some _ -> Other_use
        in
        uses := Ident.Map.add id use !uses;
        List.iter (record_uses skip) ap_args
    | (Lvar id | Lmutvar id) when not (Ident.Set.mem id skip) -> mark_other id
    | expr -> iter_head_constructor (record_uses skip) expr
  in
  record_uses Ident.Set.empty code;
  let nodes = size code in
  let max_depth = 12 in
  let small_body_limit = 24 in
  let repeated_call_limit = 32 in
  let local_budget = ref (2 * nodes) in
  let inline_initializers = Hashtbl.create 8 in
  let import_budget = ref (min 2048 (nodes + 192)) in
  let budget = function None -> local_budget | Some _ -> import_budget in
  let rec fresh_exits labels = function
    | Lstaticcatch (body, (id, binders), handler) ->
        incr next_label;
        let fresh = !next_label in
        Lstaticcatch (fresh_exits (Labels.add id fresh labels) body,
          (fresh, binders), fresh_exits labels handler)
    | Lstaticraise (id, args) ->
        let id = Option.value ~default:id (Labels.find_opt id labels) in
        Lstaticraise (id, List.map (fresh_exits labels) args)
    | expr -> shallow_map (fresh_exits labels) expr
  in
  let known defs = function
    | Lfunction def -> Some (def, size def.body)
    | Lvar id -> Ident.Map.find_opt id defs
    | _ -> None
  in
  let known_callback defs (param, _) arg =
    match Ident.Map.find_opt param !uses, known defs arg with
    | Some (Calls { arity; count }), Some (def, cost) ->
        def.kind = Curried && List.length def.params = arity
        && def.attr.inline <> Never_inline
        && cost <= (if count = 1 then callback_limit else small_body_limit)
    | _ -> false
  in
  let explicitly_hinted def call =
    match def.attr.inline, call.ap_inlined with
    | Never_inline, _ | _, Never_inline -> false
    | (Always_inline | Hint_inline), _ | _, (Always_inline | Hint_inline) -> true
    | _ -> false
  in
  let should_inline defs def cost call =
    match def.attr.inline, call.ap_inlined with
    | Never_inline, _ | _, Never_inline -> false
    | _ when explicitly_hinted def call -> true
    | _ ->
        let small =
          match call.ap_func with
          | Lfunction _ -> cost <= 64
          | Lvar id ->
              Ident.Set.mem id !callbacks
              || (match Ident.Map.find_opt id !uses with
              | Some (Calls { count = 1; _ }) -> cost <= 64
              | Some (Calls _) -> cost <= repeated_call_limit
              | _ -> false)
          | _ -> false
        in
        small || (cost <= callback_limit
          && (def.attr.is_a_functor
              || List.exists2 (known_callback defs) def.params call.ap_args))
  in
  let find_import aliases = function
    | Lvar id -> Ident.Map.find_opt id aliases
    | expr -> imported_callee_and_unit imports expr
  in
  let callee defs aliases call =
    match known defs call.ap_func with
    | Some (def, cost) when List.compare_lengths def.params call.ap_args = 0
                             && should_inline defs def cost call ->
        Some (def, cost, None)
    | Some _ -> None
    | None when call.ap_inlined = Never_inline -> None
    | None ->
        Option.bind (find_import aliases call.ap_func) (fun (target, unit_id) ->
          Option.map (fun def -> def, size def.body, Some (unit_id, target.inline_init)) target.inline_lambda)
  in
  (* Preserve the small explicit-hint fallback after the unit's budget is
     spent. A hinted helper can participate when its expanded body fits the
     same bound and the normal visitor can still inline the nested call. *)
  let small_inline_hint defs def call depth =
    let rec count depth remaining expr =
      if remaining = 0 then None
      else
        let remaining = remaining - 1 in
        match expr with
        | Lapply call when depth < max_depth ->
            (match known defs call.ap_func with
            | Some (helper, _) when helper.kind = Curried && explicitly_hinted helper call
                && List.compare_lengths helper.params call.ap_args = 0 ->
                let count_next budget arg = Option.bind budget (fun n -> count (depth + 1) n arg) in
                let arguments = List.fold_left count_next (Some remaining) call.ap_args in
                Option.bind arguments (fun n -> count (depth + 1) n helper.body)
            | _ -> None)
        | Lapply _ | Lsend _ | Lfunction _ | Lletrec _ -> None
        | expr ->
            let budget = ref (Some remaining) in
            iter_head_constructor (fun child ->
              budget := Option.bind !budget (fun n -> count depth n child)) expr;
            !budget
    in
    explicitly_hinted def call
    && Option.is_some (count (depth + 1) small_body_limit def.body)
  in
  (* Collapsing a projection-only wrapper leaves the sealed provider call in
     place. Even when the local budget is spent, the wrapper adds no calls. *)
  let rec projection = function
    | Lvar _ | Lconst (Const_int _ | Const_char _) -> true
    | Lprim (Pfield _, [owner], _) -> projection owner
    | _ -> false
  in
  let forwards_to_import def =
    match def.body with
    | Lapply call ->
        List.for_all projection call.ap_args
        && Option.exists (fun (target, _) ->
          target.arity = List.length call.ap_args && Option.is_none target.inline_lambda)
          (imported_callee_and_unit imports call.ap_func)
    | _ -> false
  in
  let rec visit depth defs import_aliases = function
    | Llet (mode, kind, id, rhs, body) ->
        let def = known defs rhs in
        let defs' = match def with
          | Some def -> Ident.Map.add id def defs
          | None -> defs
        in
        let aliases' = match find_import import_aliases rhs with
          | Some (({ inline_init = Some _; _ }, _) as entry) -> Ident.Map.add id entry import_aliases
          | _ -> import_aliases
        in
        let body = visit depth defs' aliases' body in
        let mode = if Option.is_some def then Alias else mode in
        Llet (mode, kind, id, visit depth defs import_aliases rhs, body)
    | Lapply call ->
        (match callee defs import_aliases call with
        | Some (def, cost, imported) when def.kind = Curried
            && List.compare_lengths def.params call.ap_args = 0
            && depth < max_depth
            && (cost <= !(budget imported)
                || (Option.is_none imported && cost <= small_body_limit
                    && (small_inline_hint defs def call depth || forwards_to_import def))) ->
            let remaining = budget imported in
            remaining := max 0 (!remaining - cost);
            let def = duplicate_function def in
            let body = fresh_exits Labels.empty def.body in
            record_uses (free_variables (Lfunction def)) body;
            List.iter2 (fun ((id, _) as param) arg ->
              if known_callback defs param arg then
                callbacks := Ident.Set.add id !callbacks)
              def.params call.ap_args;
            (* [conv_atoms] evaluates arguments from left to right. Use
               strict bindings for any argument that needs evaluation or has
               a representation annotation. Value aliases need no extra owner. *)
            let aliases, body = List.fold_right2 (fun (id, kind) arg (aliases, body) ->
              match kind, arg with
              | Pgenval, Lvar source when not (Ident.Set.mem id !callbacks) ->
                  Ident.Map.add id source aliases, body
              | _ -> aliases, Llet (Strict, kind, id, arg, body))
              def.params call.ap_args (Ident.Map.empty, body) in
            let body = if Ident.Map.is_empty aliases then body else Lambda.rename aliases body in
            let body = visit (depth + 1) defs import_aliases body in
            (match imported with
             | None -> body
             | Some (unit_id, init) ->
                 Option.iter (Hashtbl.replace inline_initializers (Ident.name unit_id)) init;
                 Lsequence (Lprim (Pgetglobal unit_id, [], call.ap_loc), body))
        | _ -> shallow_map (visit depth defs import_aliases) (Lapply call))
    | expr -> shallow_map (visit depth defs import_aliases) expr
  in
  let code = visit 0 Ident.Map.empty Ident.Map.empty code in
  code, (Hashtbl.to_seq inline_initializers |> List.of_seq |> List.sort compare)

(* Inlining introduces argument bindings around the returned value.
   Move those bindings and any preceding effects out of strict right-hand
   sides so later passes can see the allocation being bound. Keep optional
   right-hand sides and control-flow regions separate. *)
let flatten_let_rhs code =
  let open Lambda in
  let rec visit next = function
    | Llet (mode, kind, id, rhs, body) ->
        let bind rhs = Llet (mode, kind, id, rhs, visit next body) in
        (match mode with
        | Strict -> visit bind rhs
        | Alias | StrictOpt -> bind (visit Fun.id rhs))
    | Lsequence (action, body) ->
        Lsequence (visit Fun.id action, visit next body)
    | expr -> next (shallow_map (visit Fun.id) expr)
  in
  visit Fun.id code

(* A known module block contains already-evaluated fields. Expose bindings
   introduced by a functor's inlined initializer so a later module
   projection can still name the original function. *)
let resolve_module_projections code =
  let open Lambda in
  let fields_of = function
    | Lprim (Pmakeblock (0, Immutable, None), fields, _)
      when List.for_all
        (function Lvar _ | Lconst (Const_int _ | Const_char _) -> true | _ -> false)
        fields ->
        Some (Array.of_list fields)
    | _ -> None
  in
  let extend modules id rhs =
    let fields =
      match rhs with Lvar alias -> Ident.Map.find_opt alias modules | _ -> fields_of rhs
    in
    match fields with
    | Some fields -> Ident.Map.add id fields modules
    | None -> modules
  in
  let rec returns_module = function
    | Llet (_, _, _, _, body) | Lletrec (_, body) | Lsequence (_, body) ->
        returns_module body
    | rhs -> Option.is_some (fields_of rhs)
  in
  (* Signature coercions can place a primitive stub directly in a module
     field. Name closed representation casts so the export pass can seal
     the function identity and publish its body. *)
  let bind_byte_cast field (bindings, fields) =
    match field with
    | Lfunction { kind = Curried; params = [param, _]; attr = { stub = true; _ };
                  body = Lprim ((Pbytes_of_string | Pbytes_to_string), [Lvar arg], _); _ }
      when Ident.same param arg ->
        let id = Ident.create_local "byte_cast" in
        (id, field) :: bindings, Lvar id :: fields
    | _ -> bindings, field :: fields
  in
  let rec visit modules = function
    | Llet (mode, kind, id, rhs, body) ->
        let bind modules rhs =
          Llet (mode, kind, id, rhs, visit (extend modules id rhs) body)
        in
        let rhs = visit modules rhs in
        if mode = Strict && returns_module rhs then expose bind modules rhs
        else bind modules rhs
    | Lprim ((Pfield (index, _, Immutable) as field_prim), [owner], loc) ->
        let owner = visit modules owner in
        let field =
          match owner with
          | Lvar id ->
              Option.bind (Ident.Map.find_opt id modules) (fun fields ->
                if index >= 0 && index < Array.length fields then Some fields.(index)
                else None)
          | _ -> None
        in
        Option.value ~default:(Lprim (field_prim, [owner], loc)) field
    | Lprim ((Pmakeblock (0, Immutable, _) as block), fields, loc) ->
        let fields = List.map (visit modules) fields in
        let bindings, fields = List.fold_right bind_byte_cast fields ([], []) in
        List.fold_right (fun (id, rhs) body -> Llet (Alias, Pgenval, id, rhs, body))
          bindings (Lprim (block, fields, loc))
    | expr -> shallow_map (visit modules) expr
  and expose bind modules = function
    | Llet (mode, kind, id, rhs, body) ->
        Llet (mode, kind, id, rhs, expose bind (extend modules id rhs) body)
    | Lletrec (defs, body) -> Lletrec (defs, expose bind modules body)
    | Lsequence (action, body) -> Lsequence (action, expose bind modules body)
    | rhs -> bind modules rhs
  in
  visit Ident.Map.empty code

(* The address of a one-field mutable block can be removed when every
   occurrence reads or writes that field. Immutable aliases have the same
   address. Closures, unknown calls and other uses can observe the block. *)
let promote_local_refs code =
  let open Lambda in
  let exception Escapes in
  let rec replace slot aliases may_store_pointer = function
    | Llet (_, _, alias, Lvar id, body) when Ident.Set.mem id aliases ->
        replace slot (Ident.Set.add alias aliases) may_store_pointer body
    | Lprim (Pfield (0, _, _), [ Lvar id ], _) when Ident.Set.mem id aliases ->
        Lmutvar slot
    | Lprim (Psetfield (0, repr, _), [ Lvar id; rhs ], _) when Ident.Set.mem id aliases ->
        if repr = Pointer then may_store_pointer := true;
        Lassign (slot, replace slot aliases may_store_pointer rhs)
    | Lprim (Poffsetref offset, [ Lvar id ], loc) when Ident.Set.mem id aliases ->
        Lassign (slot, Lprim (Poffsetint offset, [ Lmutvar slot ], loc))
    | Lvar id | Lmutvar id | Lassign (id, _) | Lifused (id, _)
      when Ident.Set.mem id aliases -> raise Escapes
    | Lfunction _ as expr ->
        if not (Ident.Set.disjoint aliases (free_variables expr)) then raise Escapes;
        expr
    | Lletrec (defs, body) ->
        List.iter (fun def ->
          if not (Ident.Set.disjoint aliases (free_variables (Lfunction def.def))) then
            raise Escapes) defs;
        Lletrec (defs, replace slot aliases may_store_pointer body)
    | expr -> shallow_map (replace slot aliases may_store_pointer) expr
  in
  let rec visit = function
    | Llet (mode, kind, id, Lprim ((Pmakeblock (0, Mutable, shape) as p), [init], loc), body) ->
        let init = visit init in
        let body = visit body in
        let may_store_pointer = ref false in
        (match replace id (Ident.Set.singleton id) may_store_pointer body with
        | body ->
            let slot_kind = match shape with
              | Some [kind] when not !may_store_pointer -> kind
              | _ -> Pgenval
            in
            Lmutlet (slot_kind, id, init, body)
        | exception Escapes -> Llet (mode, kind, id, Lprim (p, [init], loc), body))
    | expr -> shallow_map visit expr
  in
  visit code

(* An immutable block can disappear when all its uses project a field or
   inspect its known constructor. The fields still evaluate once, in the
   order used by allocation, even when the continuation ignores them. *)
let replace_local_aggregates code =
  let open Lambda in
  let exception Escapes in
  let small_aggregate fields =
    fields <> [] && List.compare_length_with fields 4 <= 0
  in
  let labels = lazy (
    let last = ref 0 in
    let rec scan expr =
      (match expr with
      | Lstaticcatch (_, (id, _), _) | Lstaticraise (id, _) -> last := max !last id
      | _ -> ());
      iter_head_constructor scan expr
    in
    scan code;
    last)
  in
  let fresh_label () =
    let last = Lazy.force labels in
    incr last;
    !last
  in
  let rec replace tag fields aliases = function
    | Llet (_, _, alias, Lvar id, body) when Ident.Set.mem id aliases ->
        replace tag fields (Ident.Set.add alias aliases) body
    | Lprim (Pfield (i, _, _), [Lvar id], _) when Ident.Set.mem id aliases ->
        (match List.nth_opt fields i with
        | Some field -> Lvar field
        | None -> raise Escapes)
    | Lprim (Pisint, [Lvar id], _) when Ident.Set.mem id aliases ->
        Lconst (Const_int 0)
    | Lifthenelse (Lvar id, yes, _) when Ident.Set.mem id aliases ->
        replace tag fields aliases yes
    | Lswitch (Lvar id, sw, _) when Ident.Set.mem id aliases ->
        let arm =
          match List.assoc_opt tag sw.sw_blocks with
          | Some _ as arm -> arm
          | None -> sw.sw_failaction
        in
        (match arm with
        | Some arm -> replace tag fields aliases arm
        | None -> raise Escapes)
    | Lvar id | Lmutvar id | Lassign (id, _) | Lifused (id, _)
      when Ident.Set.mem id aliases -> raise Escapes
    | Lfunction _ as expr ->
        if not (Ident.Set.disjoint aliases (free_variables expr)) then raise Escapes;
        expr
    | Lletrec (defs, body) ->
        List.iter (fun def ->
          if not (Ident.Set.disjoint aliases (free_variables (Lfunction def.def))) then
            raise Escapes) defs;
        Lletrec (defs, replace tag fields aliases body)
    | expr -> shallow_map (replace tag fields aliases) expr
  in
  (* Split matching branch results at a static join so the continuation is
     emitted once. Only the selected arm evaluates its field expressions. *)
  let join_fields id init body =
    let rec shape = function
      | Lprim (Pmakeblock (tag, Immutable, _), args, _)
        when small_aggregate args -> Some (tag, List.length args)
      | Lstaticraise _ | Lprim (Praise _, _, _) -> None
      | Llet (_, _, _, _, tail) | Lmutlet (_, _, _, tail) | Lsequence (_, tail) ->
          shape tail
      | Lifthenelse (_, yes, no) -> shared_shape [yes; no]
      | Lstaticcatch (body, _, handler) -> shared_shape [body; handler]
      | Lswitch (_, sw, _) ->
          shared_shape (List.map snd (sw.sw_consts @ sw.sw_blocks) @ Option.to_list sw.sw_failaction)
      | Lstringswitch (_, cases, fail, _) ->
          shared_shape (List.map snd cases @ Option.to_list fail)
      | _ -> raise Escapes
    and shared_shape arms =
      match List.filter_map shape arms with
      | [] -> None
      | first :: rest ->
          if List.for_all (( = ) first) rest then Some first else raise Escapes
    in
    let tag, arity = match shape init with Some shape -> shape | None -> raise Escapes in
    let fields = List.init arity (fun _ -> Ident.create_local "component") in
    let body = replace tag fields (Ident.Set.singleton id) body in
    let label = fresh_label () in
    let rec transfer = function
      | Lprim (Pmakeblock _, args, _) -> Lstaticraise (label, args)
      | (Lstaticraise _ | Lprim (Praise _, _, _)) as exit -> exit
      | Llet (mode, rep, id, value, tail) -> Llet (mode, rep, id, value, transfer tail)
      | Lmutlet (rep, id, value, tail) -> Lmutlet (rep, id, value, transfer tail)
      | Lsequence (value, tail) -> Lsequence (value, transfer tail)
      | Lifthenelse (cond, yes, no) -> Lifthenelse (cond, transfer yes, transfer no)
      | Lstaticcatch (body, binders, handler) ->
          Lstaticcatch (transfer body, binders, transfer handler)
      | Lswitch (value, sw, loc) ->
          let arm (tag, expr) = tag, transfer expr in
          Lswitch (value,
            { sw with sw_consts = List.map arm sw.sw_consts;
                      sw_blocks = List.map arm sw.sw_blocks;
                      sw_failaction = Option.map transfer sw.sw_failaction }, loc)
      | Lstringswitch (value, cases, fail, loc) ->
          Lstringswitch (value, List.map (fun (tag, arm) -> tag, transfer arm) cases,
                         Option.map transfer fail, loc)
      | _ -> assert false
    in
    Lstaticcatch (transfer init, (label, List.map (fun field -> field, Pgenval) fields), body)
  in
  let rec visit = function
    | Llet (mode, kind, id, Lprim ((Pmakeblock (tag, Immutable, shape) as prim), args, loc), body)
      when small_aggregate args ->
        let args = List.map visit args in
        let body = visit body in
        let fields = List.map (fun _ -> Ident.create_local "component") args in
        (match replace tag fields (Ident.Set.singleton id) body with
        | body ->
            let values = List.combine fields args in
            let kinds = Option.value ~default:(List.map (fun _ -> Pgenval) args) shape in
            List.fold_right2
              (fun (field, arg) kind body -> Llet (Strict, kind, field, arg, body))
              values kinds body
        | exception Escapes -> Llet (mode, kind, id, Lprim (prim, args, loc), body))
    | Llet (mode, kind, id, ((Lifthenelse _ | Lswitch _ | Lstringswitch _ | Lstaticcatch _) as init), body) ->
        let init = visit init in
        let body = visit body in
        (match join_fields id init body with
        | result -> result
        | exception Escapes -> Llet (mode, kind, id, init, body))
    | expr -> shallow_map visit expr
  in
  visit code

(* Groups that use their members only as saturated calls can share a
   dispatcher closure. Its environment stays borrowed across transitions.
   First-class uses outside the group call it through wrappers of the original
   arities, each owning the dispatcher independently. *)
let lift_recursive_calls program =
  let open Lambda in
  let free_fun def = free_variables (Lfunction def) in
  let rec visit mutable_ids static = function
    | Llet (mode, kind, id, rhs, body) ->
        let rhs = visit mutable_ids static rhs in
        let static =
          match rhs with
          | Lfunction def when Ident.Set.subset (free_fun def) static ->
              Ident.Set.add id static
          | _ -> static
        in
        Llet (mode, kind, id, rhs, visit mutable_ids static body)
    | Lmutlet (kind, id, rhs, body) ->
        Lmutlet (kind, id, visit mutable_ids static rhs,
          visit (Ident.Set.add id mutable_ids) static body)
    | Lletrec (bindings, body) ->
        let ids = Ident.Set.of_list (List.map (fun rb -> rb.id) bindings) in
        let free =
          List.fold_left
            (fun acc rb -> Ident.Set.union acc (free_fun rb.def))
            Ident.Set.empty bindings
        in
        let captures = Ident.Set.diff free (Ident.Set.union static ids) in
        let static = if Ident.Set.is_empty captures then Ident.Set.union ids static else static in
        let bindings =
          List.map
            (fun rb -> { rb with def = map_lfunction (visit mutable_ids static) rb.def })
            bindings
        in
        let body = visit mutable_ids static body in
        lift_group mutable_ids bindings captures body
    | expr -> shallow_map (visit mutable_ids static) expr
  and lift_group mutable_ids bindings captures body =
    let original = Lletrec (bindings, body) in
    let arity =
      List.fold_left (fun n rb -> max n (List.length rb.def.params)) 0 bindings
    in
    if List.length bindings < 2 || Ident.Set.is_empty captures
       || not (Ident.Set.disjoint mutable_ids captures)
       || arity + 1 > min 32 (Lambda.max_arity ())
       || List.exists (fun rb -> rb.def.kind <> Curried) bindings
    then original
    else
      let cases = List.mapi (fun tag rb -> tag, rb) bindings in
      let members =
        List.fold_left
          (fun acc (tag, rb) ->
            Ident.Map.add rb.id (tag, List.length rb.def.params) acc)
          Ident.Map.empty cases
      in
      let call_target id args =
        match Ident.Map.find_opt id members with
        | Some (tag, arity) when List.length args = arity -> Some tag
        | _ -> None
      in
      let rec uses_values = function
        | Lapply { ap_func = Lvar id; ap_args; _ }
          when Option.is_some (call_target id ap_args) ->
            List.exists uses_values ap_args
        | Lvar id -> Ident.Map.mem id members
        | expr ->
            let found = ref false in
            iter_head_constructor (fun e -> if uses_values e then found := true) expr;
            !found
      in
      if List.exists (fun rb -> uses_values rb.def.body) bindings then original
      else
        let dispatcher = Ident.create_local "mutrec_dispatch" in
        let selector = Ident.create_local "member" in
        let tag_and_args tag args =
          Lconst (Const_int tag)
          :: (args @ List.init (arity - List.length args) (fun _ -> lambda_unit))
        in
        let rec rewrite = function
          | Lapply ({ ap_func = Lvar id; ap_args; _ } as app) ->
              let args = List.map rewrite ap_args in
              (match call_target id args with
              | Some tag ->
                  Lapply { app with ap_func = Lvar dispatcher; ap_args = tag_and_args tag args }
              | None -> Lapply { app with ap_args = args })
          | expr -> shallow_map rewrite expr
        in
        let slots =
          List.init arity (fun i ->
              let immediate rb =
                match List.nth_opt rb.def.params i with
                | None | Some (_, Pintval) -> true
                | Some _ -> false
              in
              let kind = if List.for_all immediate bindings then Pintval else Pgenval in
              (Ident.create_local "arg", kind))
        in
        let arms =
          List.map
            (fun (tag, rb) ->
              let params = rb.def.params in
              let body =
                List.fold_right2
                  (fun (param, kind) (slot, _) body -> Llet (Alias, kind, param, Lvar slot, body))
                  params (List.take (List.length params) slots) (rewrite rb.def.body)
              in
              (tag, body))
            cases
        in
        let loc = (List.hd bindings).def.loc in
        let switch =
          Lswitch (Lvar selector,
            { sw_numconsts = List.length arms; sw_consts = arms;
              sw_numblocks = 0; sw_blocks = []; sw_failaction = None },
            loc)
        in
        let def =
          lfunction' ~kind:Curried ~params:((selector, Pintval) :: slots)
            ~return:Pgenval ~body:switch ~attr:default_function_attribute ~loc
        in
        let body = rewrite body in
        let value_uses = free_variables body in
        let body =
          List.fold_right
            (fun (tag, rb) body ->
              if not (Ident.Set.mem rb.id value_uses) then body
              else
                let def = rb.def in
                let params = List.map (fun (id, kind) -> Ident.rename id, kind) def.params in
                let args = List.map (fun (id, _) -> Lvar id) params in
                let call =
                  Lapply { ap_func = Lvar dispatcher; ap_args = tag_and_args tag args;
                    ap_loc = def.loc; ap_tailcall = Default_tailcall;
                    ap_inlined = Default_inline; ap_specialised = Default_specialise }
                in
                Llet (Strict, Pgenval, rb.id,
                  lfunction ~kind:Curried ~params ~return:def.return ~body:call
                    ~attr:def.attr ~loc:def.loc,
                  body))
            cases body
        in
        Lletrec ([ { id = dispatcher; def } ], body)
  in
  visit Ident.Set.empty Ident.Set.empty program

(* An immutable alias of a known stdlib selector still names that selector.
   Rewrite saturated applications only; the original binding remains available
   for exports, partial application, and other first-class uses. *)
let specialize_int_selector_aliases table code =
  let open Lambda in
  let rec visit aliases = function
    | Llet (mode, kind, id, rhs, body) ->
        let rhs = visit aliases rhs in
        let selector =
          match rhs with
          | Lvar source -> Ident.Map.find_opt source aliases
          | _ when Option.is_some (Builtins.resolve_int_selection table rhs) -> Some rhs
          | _ -> None
        in
        let aliases =
          match selector with
          | Some selector -> Ident.Map.add id selector aliases
          | None -> aliases
        in
        Llet (mode, kind, id, rhs, visit aliases body)
    | Lapply ({ ap_func = Lvar fn; ap_args = [ lhs; rhs ]; _ } as call) ->
        let ap_func = Option.value ~default:call.ap_func (Ident.Map.find_opt fn aliases) in
        Lapply { call with ap_func; ap_args = [ visit aliases lhs; visit aliases rhs ] }
    | expr -> shallow_map (visit aliases) expr
  in
  visit Ident.Map.empty code

(* Recover function identities from immutable Lambda blocks, including the
   conservative field reads emitted when a signature projects a submodule.
   Mutable records can change through aliases and never establish a shape. *)
type module_value = Unknown | Known_function of Ident.t | Structure of module_value array

let exported_functions code =
  let open Lambda in
  let rec scan env = function
    | Lvar id -> Option.value ~default:Unknown (Ident.Map.find_opt id env)
    | Llet (_, _, id, rhs, body) ->
        let value = match rhs with
          | Lfunction _ -> Known_function id
          | _ -> scan env rhs
        in
        scan (Ident.Map.add id value env) body
    | Lletrec (defs, body) ->
        let env = List.fold_left (fun env rb ->
          Ident.Map.add rb.id (Known_function rb.id) env) env defs in
        scan env body
    | Lmutlet (_, _, _, body) | Lsequence (_, body) | Levent (body, _) ->
        scan env body
    | Lprim (Psetglobal _, [body], _) -> scan env body
    | Lprim (Pmakeblock (0, Immutable, _), fields, _) ->
        Structure (Array.of_list (List.map (scan env) fields))
    | Lprim (Pfield (slot, _, _), [owner], _) ->
        (match scan env owner with
        | Structure fields when slot >= 0 && slot < Array.length fields -> fields.(slot)
        | _ -> Unknown)
    | _ -> Unknown
  in
  let rec gather path acc = function
    | Known_function id -> (List.rev path, id) :: acc
    | Structure fields ->
        let acc = ref acc in
        Array.iteri (fun i field -> acc := gather (i :: path) !acc field) fields;
        !acc
    | Unknown -> acc
  in
  gather [] [] (scan Ident.Map.empty code)

let propagate_immediate_constants code =
  let open Lambda in
  let rec visit constants = function
    | Lvar id as expr -> Option.value ~default:expr (Ident.Map.find_opt id constants)
    | Llet (mode, kind, id, rhs, body) ->
        (match visit constants rhs with
         | Lconst (Const_int _ | Const_char _) as value ->
             visit (Ident.Map.add id value constants) body
         | rhs -> Llet (mode, kind, id, rhs, visit constants body))
    | expr -> shallow_map (visit constants) expr
  in
  visit Ident.Map.empty code

let module_bindings code =
  let open Lambda in
  let rec bindings defs = function
    | Llet (_, kind, id, rhs, body) ->
        bindings (Ident.Map.add id (kind, rhs) defs) body
    | Lletrec (group, body) ->
        let defs = List.fold_left (fun defs rb ->
          Ident.Map.add rb.id (Pgenval, Lfunction rb.def) defs) defs group
        in
        bindings defs body
    | Lmutlet (_, _, _, body) | Lsequence (_, body) | Levent (body, _)
    | Lprim (Psetglobal _, [body], _) -> bindings defs body
    | _ -> defs
  in
  bindings Ident.Map.empty code

(* Seal the Unicode fast path only after recognizing the implementation's
   scalar bounds and identity success path. The cold call keeps the original
   failure behavior and links against the same sealed implementation. *)
let unicode_validations code =
  let open Lambda in
  let definitions = module_bindings (propagate_immediate_constants code) in
  let unary id =
    match Ident.Map.find_opt id definitions with
    | Some (_, Lfunction { kind = Curried; params = [input, Pintval];
                            return = Pintval; attr; body; _ })
      when attr.inline <> Never_inline -> Some (input, body)
    | _ -> None
  in
  let is_range input lo hi = function
    | Lprim (Psequand,
        [ Lprim (Pintcomp Cle, [Lconst (Const_int first); Lvar left], _);
          Lprim (Pintcomp Cle, [Lvar right; Lconst (Const_int last)], _) ], _) ->
        first = lo && last = hi && Ident.same left input && Ident.same right input
    | _ -> false
  in
  let is_validator id = match unary id with
    | Some (input, Lprim (Psequor, [first; second], _)) ->
        is_range input 0 0xD7FF first && is_range input 0xE000 0x10FFFF second
    | _ -> false
  in
  fun id ->
    if is_validator id then Some Unicode_test else
      match unary id with
      | Some (input, Lifthenelse
          (Lapply { ap_func = Lvar validate; ap_args = [Lvar checked]; _ }, Lvar result, _))
        when Ident.same input checked && Ident.same input result && is_validator validate ->
          Some Unicode_check
      | _ -> None

(* Make a module slot only for values already rooted by a published closure.
   Local functions and values that die in the initializer retain their normal
   lifetimes. Follow private direct helpers from the published definitions. *)
let module_captures defs exported =
  let rec follow (seen, slots) id =
    if Ident.Set.mem id seen then seen, slots
    else
      let seen = Ident.Set.add id seen in
      match Ident.Map.find_opt id defs with
      | Some (_, (Lambda.Lfunction _ as fn)) ->
          Ident.Set.fold (fun capture state -> follow state capture)
            (Lambda.free_variables fn) (seen, slots)
      | Some (kind, _) -> seen, Ident.Map.add id kind slots
      | None -> seen, slots
  in
  snd (List.fold_left (fun state (_, id) -> follow state id)
         (Ident.Set.empty, Ident.Map.empty) exported)

(* Publish allocation-producing small bodies before ANF consumes their field
   shapes. An acyclic helper can travel with the body, provided it has no
   module-local value captures and the complete copy still fits the budget. *)
let inline_export_bodies defs exported =
  let open Lambda in
  let exception Ineligible in
  let rec returns_product = function
    | Lprim (Pmakeblock (_, Immutable, _), fields, _) ->
        List.compare_length_with fields 2 >= 0 && List.compare_length_with fields 4 <= 0
    | Llet (_, _, _, _, tail) | Lsequence (_, tail) | Lmutlet (_, _, _, tail) ->
        returns_product tail
    | Lifthenelse (_, yes, no) | Lstaticcatch (yes, _, no) ->
        returns_product yes || returns_product no
    | Lswitch (_, sw, _) ->
        List.exists (fun (_, arm) -> returns_product arm) (sw.sw_consts @ sw.sw_blocks)
        || Option.exists returns_product sw.sw_failaction
    | Lstringswitch (_, cases, fail, _) ->
        List.exists (fun (_, arm) -> returns_product arm) cases
        || Option.exists returns_product fail
    | _ -> false
  in
  let function_at id =
    match Ident.Map.find_opt id defs with
    | Some (_, Lfunction def) when def.kind = Curried
        && def.attr.inline <> Never_inline && not def.attr.is_a_functor -> def
    | _ -> raise Ineligible
  in
  let called_helpers def =
    let captures = free_variables (Lfunction def) in
    let rec check = function
      | Lapply { ap_func = Lvar id; ap_args; _ } when Ident.Set.mem id captures ->
          let helper = function_at id in
          if List.compare_lengths ap_args helper.params <> 0 then raise Ineligible;
          List.iter check ap_args
      | Lvar id when Ident.Set.mem id captures -> raise Ineligible
      | expr -> iter_head_constructor check expr
    in
    check def.body;
    captures
  in
  let copy_product id def =
    if not (returns_product def.body) then raise Ineligible;
    let remaining = ref 192 in
    let rec measure expr =
      decr remaining;
      if !remaining < 0 then raise Ineligible;
      iter_head_constructor measure expr
    in
    measure def.body;
    let rec close active (seen, helpers) id =
      if Ident.Set.mem id active then raise Ineligible;
      if Ident.Set.mem id seen then seen, helpers
      else
        let helper = function_at id in
        measure helper.body;
        let active = Ident.Set.add id active in
        let seen, helpers =
          Ident.Set.fold (fun id state -> close active state id)
            (called_helpers helper) (seen, helpers)
        in
        Ident.Set.add id seen, (id, helper) :: helpers
    in
    let _, helpers =
      Ident.Set.fold (fun capture state -> close (Ident.Set.singleton id) state capture)
        (called_helpers def) (Ident.Set.empty, [])
    in
    map_lfunction (fun body ->
      List.fold_left (fun body (id, helper) ->
        Llet (Alias, Pgenval, id, Lfunction helper, body))
        body helpers) def
  in
  let copy id =
    let def = function_at id in
    if Option.is_some (Lambda_leaf.encode def) then def else copy_product id def
  in
  List.fold_left (fun bodies (_, id) ->
    if Ident.Map.mem id bodies then bodies
    else match copy id with
      | def -> Ident.Map.add id def bodies
      | exception Ineligible -> bodies) Ident.Map.empty exported

(* Only private numeric values can lose their boxes. The slot initializer and
   writes must produce their own values, and a read that needs an OCaml value
   must leave the slot's scope. References that escape have already been
   excluded by [promote_local_refs]. *)
let specialize_mutable_slots code =
  let open Lambda in
  let exception Boxed_use in
  let slots = ref Ident.Map.empty in
  let produced_by = function
    | Paddfloat | Psubfloat | Pmulfloat | Pdivfloat
    | Pfloatofint | Pnegfloat | Pabsfloat | Pfloatfield _
    | Parrayrefu Pfloatarray | Parrayrefs Pfloatarray -> Some Double_scalar
    | Pbintofint k | Pcvtbint (_, k) | Pnegbint k
    | Paddbint k | Psubbint k | Pmulbint k | Pandbint k | Porbint k | Pxorbint k
    | Plslbint k | Plsrbint k | Pasrbint k
    | Pdivbint { size = k; _ } | Pmodbint { size = k; _ } -> Some (Integer_scalar k)
    | _ -> None
  in
  let rec producer = function
    | Lconst c ->
        let rep = match c with
          | Const_float _ -> Some Double_scalar
          | Const_int32 _ -> Some (Integer_scalar Pint32)
          | Const_int64 _ -> Some (Integer_scalar Pint64)
          | Const_nativeint _ -> Some (Integer_scalar Pnativeint)
          | _ -> None in
        Option.map (fun kind -> kind, Some c) rep
    | Lprim (p, _, _) -> Option.map (fun rep -> rep, None) (produced_by p)
    | Llet (_, _, _, _, tail) | Lsequence (_, tail) | Levent (tail, _) -> producer tail
    | Lifthenelse (_, yes, no) ->
        (match producer yes, producer no with
        | Some (rep, None), Some (other, None) when rep = other -> Some (rep, None)
        | _ -> None)
    | _ -> None
  in
  let consumes rep prim index =
    let expected = match prim with
      | Paddfloat | Psubfloat | Pmulfloat | Pdivfloat | Pfloatcomp _
      | Pnegfloat | Pabsfloat | Pintoffloat -> Some Double_scalar
      | Parraysets Pfloatarray | Parraysetu Pfloatarray when index = 2 -> Some Double_scalar
      | Paddbint k | Psubbint k | Pmulbint k | Pandbint k | Porbint k | Pxorbint k
      | Pdivbint { size = k; _ } | Pmodbint { size = k; _ }
      | Pbintcomp (k, _) | Pcompare_bints k
      | Pnegbint k | Pintofbint k | Pcvtbint (k, _) -> Some (Integer_scalar k)
      | (Plslbint k | Plsrbint k | Pasrbint k) when index = 0 -> Some (Integer_scalar k)
      | _ -> None in
    expected = Some rep
  in
  let prepare slot rep initial body =
    let assigns = ref false and boxed_exit = ref false and writes_literal = ref false in
    let rec visit flag ~exit expr =
      let check = visit flag ~exit:false in
      let tail = visit flag ~exit in
      match expr with
      | Lmutvar id when Ident.same id slot ->
          if not exit then raise Boxed_use;
          boxed_exit := true;
          (match flag with
          | None -> expr
          | Some (written, constant) ->
              Lifthenelse (Lmutvar written, expr, Lconst constant))
      | Lassign (id, rhs) when Ident.same id slot ->
          (match producer rhs with
          | Some (actual, literal) when actual = rep ->
              assigns := true;
              if Option.is_some literal then writes_literal := true
          | _ -> raise Boxed_use);
          let assignment = Lassign (id, check rhs) in
          (match flag with
          | None -> assignment
          | Some (written, _) ->
              Lsequence (assignment, Lassign (written, Lconst (Const_int 1))))
      | Lprim (prim, args, loc) ->
          let args = List.mapi (fun index value ->
            match value with
            | Lmutvar id when Ident.same id slot && consumes rep prim index -> value
            | _ -> check value) args in
          Lprim (prim, args, loc)
      | Llet (mode, kind, id, rhs, body) -> Llet (mode, kind, id, check rhs, tail body)
      | Lmutlet (kind, id, rhs, body) -> Lmutlet (kind, id, check rhs, tail body)
      | Lsequence (first, body) -> Lsequence (check first, tail body)
      | Lifthenelse (cond, yes, no) -> Lifthenelse (check cond, tail yes, tail no)
      | Lswitch (value, cases, loc) ->
          let arm (tag, body) = tag, tail body in
          Lswitch (check value,
            { cases with sw_consts = List.map arm cases.sw_consts;
                         sw_blocks = List.map arm cases.sw_blocks;
                         sw_failaction = Option.map tail cases.sw_failaction }, loc)
      | Lstringswitch (value, cases, fail, loc) ->
          Lstringswitch (check value, List.map (fun (tag, body) -> tag, tail body) cases,
                         Option.map tail fail, loc)
      | Lstaticcatch (body, binders, handler) ->
          Lstaticcatch (tail body, binders, tail handler)
      | Ltrywith (body, id, handler) -> Ltrywith (tail body, id, tail handler)
      | Levent (body, event) -> Levent (tail body, event)
      | Lfunction _ ->
          if Ident.Set.mem slot (free_variables expr) then raise Boxed_use;
          expr
      | Lletrec (defs, body) ->
          List.iter (fun def ->
            if Ident.Set.mem slot (free_variables (Lfunction def.def)) then raise Boxed_use) defs;
          Lletrec (defs, tail body)
      | _ -> shallow_map check expr
    in
    ignore (visit None ~exit:true body);
    if not !assigns || (!boxed_exit && !writes_literal) then raise Boxed_use;
    match initial with
    | Some constant when !boxed_exit ->
        (* A zero-write exit still returns a static constant. *)
        let written = Ident.create_local "slot_written" in
        Lmutlet (Pintval, written, Lconst (Const_int 0),
                 visit (Some (written, constant)) ~exit:true body)
    | _ -> body
  in
  let rec visit = function
    | Lmutlet (kind, id, init, body) ->
        let init = visit init in
        let body = visit body in
        let body =
          match producer init with
          | Some (rep, literal) ->
              (match prepare id rep literal body with
              | prepared -> slots := Ident.Map.add id rep !slots; prepared
              | exception Boxed_use -> body)
          | None -> body in
        Lmutlet (kind, id, init, body)
    | expr -> shallow_map visit expr
  in
  let code = visit code in
  code, !slots

(* The Lambda identifiers survive ANF conversion. Keep source representation
   facts alongside the tree so later rewrites can keep using the same binders. *)
let binding_kinds code =
  let kinds = ref Ident.Map.empty in
  let add id kind = kinds := Ident.Map.add id kind !kinds in
  let rec visit expr =
    (match expr with
    | Lambda.Llet (_, kind, id, _, _) | Lmutlet (kind, id, _, _) -> add id kind
    | Lstaticcatch (_, (_, binders), _) ->
        List.iter (fun (id, kind) -> add id kind) binders
    | _ -> ());
    Lambda.iter_head_constructor visit expr
  in
  visit code;
  !kinds

module Optimized = struct
  type t = {
    code : Lambda.lambda;
    scalars : scalar_rep Ident.Map.t;
    slots : Lambda.value_kind Ident.Map.t;
    value_kinds : Lambda.value_kind Ident.Map.t;
    inline_bodies : Lambda.lfunction Ident.Map.t;
    inline_initializers : (string * string) list;
    export_ids : (int list * Ident.t) list;
  }
end

let optimize ~imports ~selectors ~is_array_initializer ~collect_exports code =
  let code =
    match selectors with
    | Some table -> specialize_int_selector_aliases table code
    | None -> code
  in
  let code, inline_initializers =
    inline_local_calls ~imports (propagate_immediate_constants code)
  in
  let code =
    code |> flatten_let_rhs |> resolve_module_projections
    |> drop_unused_alias_lets |> promote_local_refs
    |> replace_local_aggregates
    |> Bounds.remove_redundant_checks ~is_array_initializer |> lift_recursive_calls
  in
  let code, scalars = specialize_mutable_slots code in
  let exported = exported_functions code in
  let bindings = module_bindings code in
  let slots = module_captures bindings exported in
  let inline_bodies, export_ids =
    if collect_exports then inline_export_bodies bindings exported, exported
    else Ident.Map.empty, []
  in
  { Optimized.code; scalars; slots; value_kinds = binding_kinds code;
    inline_bodies; inline_initializers; export_ids }

(* A small closed expression over tagged scalar parameters can be copied into
   the caller. Its body uses neither ownership operations nor exception state. *)
let inline_export_leaves lambda code =
  let allowed = ref Ident.Set.empty in
  let add id (lf : Lambda.lfunction) =
    match lf.attr.inline with
    | Never_inline | Unroll _ -> ()
    | _ -> allowed := Ident.Set.add id !allowed
  in
  let rec visit expr =
    (match expr with
    | Lambda.Llet (_, _, id, Lfunction lf, _) -> add id lf
    | Lambda.Lletrec (defs, _) ->
        List.iter (fun (rb : Lambda.rec_binding) -> add rb.id rb.def) defs
    | _ -> ());
    Lambda.iter_head_constructor visit expr
  in
  visit lambda;
  let scalar = function Var _ | Int _ | Char _ | Unit -> true | _ -> false in
  let rec leaf remaining = function
    | Halt a when scalar a -> remaining - 1
    | Let (_, Atom a, body) when scalar a && remaining > 0 ->
        leaf (remaining - 1) body
    | Let (_, Binop ((Add | Sub | Mul | And | Or | Xor | Lsl | Lsr | Asr
                     | Cmp _ | Compare_ints | Isout), lhs, rhs), body)
      when scalar lhs && scalar rhs && remaining > 0 ->
        leaf (remaining - 1) body
    | Let (_, Unop ((Neg | Not | Offset _ | Isint), a), body)
      when scalar a && remaining > 0 ->
        leaf (remaining - 1) body
    | If (cond, yes, no) when scalar cond && remaining > 0 ->
        let after_yes = leaf (remaining - 1) yes in
        if after_yes >= 0 then leaf after_yes no else -1
    | LetJoin (_, rhs, body) when remaining > 0 ->
        let after_rhs = leaf (remaining - 1) rhs in
        if after_rhs >= 0 then leaf after_rhs body else -1
    | _ -> -1
  in
  let leaves = List.fold_left (fun acc (id, lf) ->
    let params = Ident.Set.of_list (List.map fst lf.params) in
    if Ident.Set.mem id !allowed
       && List.for_all (fun (_, rep) -> rep = Lambda.Pintval) lf.params
       && leaf 12 lf.body >= 0
       && Ident.Set.subset (free_vars lf.body) params
    then Ident.Map.add id lf acc else acc) Ident.Map.empty (pure_defs code)
  in
  fun id -> Ident.Map.find_opt id leaves
