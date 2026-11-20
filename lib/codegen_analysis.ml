(* Codegen static analyses: pure definitions, mutual tail-call SCCs,
   free-variable filtering, and external module dependency collection. *)

let collect_pure_defs (e : Anf.aexpr) : (Ident.t * Anf.lfunction) list =
  Anf.pure_defs e

let free_vars_of (b : Codegen_ctx.t) ?self_id (lf : Anf.lfunction) :
    Ident.t list =
  Anf.free_vars lf.body
  |> Ident.Set.filter (fun v ->
         not (List.exists (fun (p, _) -> Ident.same p v) lf.params)
         && (match self_id with Some s -> not (Ident.same s v) | None -> true)
         &&
         match Hashtbl.find_opt b.funs v with
         | Some info -> info.has_closure
         | None -> true)
  |> Ident.Set.elements

let tail_callees ?(arities : (Ident.t * int) list option) (e : Anf.aexpr) :
    Ident.Set.t =
  let rec go (e : Anf.aexpr) =
    match e with
    | Anf.Let (id, App (Var callee, args), Halt (Var v))
      when Ident.same id v -> (
        match arities with
        | None -> Ident.Set.singleton callee
        | Some tbl -> (
            match
              List.find_opt (fun (k, _) -> Ident.same k callee) tbl
            with
            | Some (_, arity) when List.length args = arity ->
                Ident.Set.singleton callee
            | _ -> Ident.Set.empty))
    | Let (_, _, body) | MutLet (_, _, body) | LetJoin (_, _, body)
    | LetRec (_, body) | Retain (_, body) | Release (_, body)
    | ReleaseMut (_, body) | DropReuse (_, _, body) | FreeReuse (_, body)
    | ShadowPush (_, _, _, body) | ShadowPop (_, _, body) ->
        go body
    | If (_, th, el) -> Ident.Set.union (go th) (go el)
    | ScalarIf _ -> Ident.Set.empty
    | Switch (_, sw) ->
        let acc =
          List.fold_left
            (fun acc (_, arm) -> Ident.Set.union acc (go arm))
            Ident.Set.empty sw.consts
        in
        let acc =
          List.fold_left
            (fun acc (_, arm) -> Ident.Set.union acc (go arm))
            acc sw.blocks
        in
        (match sw.fail with
        | Some f -> Ident.Set.union acc (go f)
        | None -> acc)
    | StringSwitch (_, cases, fail) ->
        let acc =
          List.fold_left
            (fun acc (_, arm) -> Ident.Set.union acc (go arm))
            Ident.Set.empty cases
        in
        (match fail with
        | Some f -> Ident.Set.union acc (go f)
        | None -> acc)
    | StaticCatch (body, _, _, handler, _)
    | TryWith (body, _, handler) ->
        Ident.Set.union (go body) (go handler)
    | CheckExn (_, on_ok) -> go on_ok
    | Halt _ | HaltScalar _ | StaticRaise _ | While _ | For _ | Raise _
    | Unwind ->
        Ident.Set.empty
  in
  go e

let strongly_connected_components nodes edges =
  let index = Hashtbl.create 16 in
  let low = Hashtbl.create 16 in
  let on_stack = Hashtbl.create 16 in
  let stack = ref [] in
  let counter = ref 0 in
  let comps = ref [] in
  let rec strongconnect v =
    Hashtbl.replace index v !counter;
    Hashtbl.replace low v !counter;
    Hashtbl.replace on_stack v true;
    incr counter;
    stack := v :: !stack;
    Ident.Set.iter
      (fun w ->
        if not (Hashtbl.mem index w) then begin
          strongconnect w;
          Hashtbl.replace low v
            (min (Hashtbl.find low v) (Hashtbl.find low w))
        end
        else if Hashtbl.find on_stack w then
          Hashtbl.replace low v
            (min (Hashtbl.find low v) (Hashtbl.find index w)))
      (edges v);
    if Hashtbl.find low v = Hashtbl.find index v then begin
      let rec pop comp =
        match !stack with
        | w :: rest ->
            stack := rest;
            Hashtbl.replace on_stack w false;
            let comp = w :: comp in
            if Ident.same w v then comps := comp :: !comps else pop comp
        | [] -> assert false
      in
      pop []
    end
  in
  List.iter
    (fun v -> if not (Hashtbl.mem index v) then strongconnect v)
    nodes;
  List.rev !comps

let collect_globals self_sym (e : Anf.aexpr) : string list =
  let seen = Hashtbl.create 8 in
  let deps = ref [] in
  let add name =
    let s = Codegen_ctx.sanitize name in
    if s <> self_sym && not (Hashtbl.mem seen s) then begin
      Hashtbl.add seen s ();
      deps := s :: !deps
    end
  in
  let rec scan_aexpr (e : Anf.aexpr) =
    match e with
    | Halt _ | HaltScalar _ | StaticRaise _ | Raise _ | Unwind -> ()
    | Let (_, ce, body) | MutLet (_, ce, body) ->
        scan_cexpr ce;
        scan_aexpr body
    | LetJoin (_, rhs, body)
    | StaticCatch (rhs, _, _, body, _)
    | While (rhs, body) | CheckExn (rhs, body) | TryWith (rhs, _, body) ->
        scan_aexpr rhs;
        scan_aexpr body
    | LetRec (bindings, body) ->
        List.iter (fun (rb : Anf.rec_binding) -> scan_aexpr rb.def.body) bindings;
        scan_aexpr body
    | If (_, th, el) | ScalarIf (_, _, th, el) ->
        scan_aexpr th;
        scan_aexpr el
    | Switch (_, sw) ->
        List.iter (fun (_, arm) -> scan_aexpr arm) sw.consts;
        List.iter (fun (_, arm) -> scan_aexpr arm) sw.blocks;
        Option.iter scan_aexpr sw.fail
    | StringSwitch (_, cases, fail) ->
        List.iter (fun (_, arm) -> scan_aexpr arm) cases;
        Option.iter scan_aexpr fail
    | For (_, _, _, _, body)
    | Retain (_, body)
    | Release (_, body)
    | ReleaseMut (_, body)
    | DropReuse (_, _, body)
    | FreeReuse (_, body)
    | ShadowPush (_, _, _, body)
    | ShadowPop (_, _, body) ->
        scan_aexpr body
  and scan_cexpr (ce : Anf.cexpr) =
    match ce with
    | GetGlobal name -> add name
    | DirectApp (target, _) -> add target.unit_name
    | Ccall (("ocamlcc_effect_perform" | "ocamlcc_effect_runstack"
             | "ocamlcc_effect_resume" | "ocamlcc_effect_reperform"), _) ->
        (* Primitive calls can mention no module global. Initialize the
           public Effect exception constructors before any such call. *)
        add "Stdlib__Effect"
    | Fun lf -> scan_aexpr lf.body
    | _ -> ()
  in
  scan_aexpr e;
  List.rev !deps
