(* Pure-function analysis regression test: non-capturing functions are static.

   A function whose free variables are only its own parameters (plus already
   known pure functions) is compiled as an immortal static function by
   codegen ([has_closure = false]). Its binding therefore must not be owned
   or released by the ARC pass — releasing it forces codegen to synthesize
   an immortal static closure wrapper ([clos.N]) purely to feed
   [arc_release_val].

   The pure-defs analyses (arc_pass [pure_defs_of_aexpr] / codegen
   [collect_pure_defs]) only walk the top-level spine: they descend through
   nested [Let] chains but skip [LetJoin] rhs and stop at branch constructs
   ([If], [Switch], [TryWith], [While], [For], [StaticCatch]). A
   non-capturing helper defined inside a branch — e.g. inside an [if] arm,
   which the ANF lowering places in a [LetJoin] rhs — misses the analysis,
   gets owned by the ARC pass, and is Released at its last use. *)

let count_release id (e : Anf.aexpr) : int =
  let rec go = function
    | Anf.ReleaseMut (_, cont) | Anf.Retain (_, cont) -> go cont
    | Anf.Release (m, cont) ->
        (if Ident.same m id then 1 else 0) + go cont
    | Anf.Halt _ | Anf.HaltScalar _ | Anf.Raise _ | Anf.Unwind -> 0
    | Anf.Let (_, ce, body) | Anf.MutLet (_, ce, body) ->
        go_ce (go body) ce
    | Anf.LetJoin (_, rhs, body) -> go rhs + go body
    | Anf.LetRec (bindings, body) ->
        List.fold_left
          (fun acc rb -> acc + go rb.Anf.def.Anf.body)
          (go body) bindings
    | Anf.If (_, th, el) | Anf.ScalarIf (_, _, th, el) -> go th + go el
    | Anf.Switch (_, sw) ->
        let arms =
          List.map snd sw.Anf.consts @ List.map snd sw.Anf.blocks
          @ (match sw.Anf.fail with Some f -> [ f ] | None -> [])
        in
        List.fold_left (fun acc a -> acc + go a) 0 arms
    | Anf.StringSwitch (_, cases, fail) ->
        List.fold_left
          (fun acc (_, a) -> acc + go a)
          (match fail with Some f -> go f | None -> 0) cases
    | Anf.StaticCatch (body, _, _, handler, _) -> go body + go handler
    | Anf.StaticRaise (_, _) -> 0
    | Anf.While (cond, body) | Anf.CheckExn (cond, body) -> go cond + go body
    | Anf.For (_, _, _, _, body) -> go body
    | Anf.TryWith (body, _, handler) -> go body + go handler
    | Anf.DropReuse (_, _, cont) | Anf.FreeReuse (_, cont)
    | Anf.ShadowPop (_, _, cont) | Anf.ShadowPush (_, _, _, cont) ->
        go cont
  and go_ce acc = function
    | Anf.Fun lf -> go lf.Anf.body + acc
    | _ -> acc
  in
  go e

(* Ids bound to non-capturing functions (plain [let] or whole [let rec]
   groups) anywhere in the ANF, including branches and join rhs. *)
let static_fun_ids (e : Anf.aexpr) : Ident.Set.t =
  let param_set (lf : Anf.lfunction) =
    List.fold_left (fun s (p, _) -> Ident.Set.add p s) Ident.Set.empty lf.params
  in
  let is_noncapturing ~extra lf =
    let free = Anf.free_vars lf.Anf.body in
    let allowed = Ident.Set.union (param_set lf) extra in
    Ident.Set.for_all (fun v -> Ident.Set.mem v allowed) free
  in
  let rec go extra acc = function
    | Anf.Let (id, Anf.Fun lf, body) ->
        if is_noncapturing ~extra lf then
          let extra' = Ident.Set.add id extra in
          let acc = Ident.Set.add id acc in
          let acc = go extra' acc lf.Anf.body in
          go extra' acc body
        else
          let acc = go extra acc lf.Anf.body in
          go extra acc body
    | Anf.Let (_, _, body) | Anf.MutLet (_, _, body) -> go extra acc body
    | Anf.LetJoin (_, rhs, body) -> go extra (go extra acc rhs) body
    | Anf.LetRec (bindings, body) ->
        let rec_ids =
          List.fold_left
            (fun s (rb : Anf.rec_binding) -> Ident.Set.add rb.id s)
            Ident.Set.empty bindings
        in
        let extra_grp = Ident.Set.union rec_ids extra in
        if
          List.for_all (fun (rb : Anf.rec_binding) ->
              is_noncapturing ~extra:extra_grp rb.def) bindings
        then
          let acc = Ident.Set.union rec_ids acc in
          let acc =
            List.fold_left
              (fun acc (rb : Anf.rec_binding) -> go extra_grp acc rb.def.Anf.body)
              acc bindings
          in
          go extra_grp acc body
        else
          let acc =
            List.fold_left
              (fun acc (rb : Anf.rec_binding) -> go extra acc rb.def.Anf.body)
              acc bindings
          in
          go extra acc body
    | Anf.If (_, th, el) | Anf.ScalarIf (_, _, th, el) -> go extra (go extra acc th) el
    | Anf.Switch (_, sw) ->
        let arms =
          List.map snd sw.Anf.consts @ List.map snd sw.Anf.blocks
          @ (match sw.Anf.fail with Some f -> [ f ] | None -> [])
        in
        List.fold_left (fun acc a -> go extra acc a) acc arms
    | Anf.StringSwitch (_, cases, fail) ->
        let acc =
          List.fold_left (fun acc (_, a) -> go extra acc a) acc cases
        in
        (match fail with Some f -> go extra acc f | None -> acc)
    | Anf.StaticCatch (body, _, _, handler, _) ->
        go extra (go extra acc body) handler
    | Anf.While (cond, b) | Anf.CheckExn (cond, b) ->
        go extra (go extra acc cond) b
    | Anf.For (_, _, _, _, body) -> go extra acc body
    | Anf.TryWith (body, _, handler) -> go extra (go extra acc body) handler
    | Anf.Halt _ | Anf.HaltScalar _ | Anf.Raise _ | Anf.Unwind | Anf.StaticRaise _ -> acc
    | Anf.Retain (_, cont) | Anf.Release (_, cont) | Anf.ReleaseMut (_, cont)
    | Anf.DropReuse (_, _, cont) | Anf.FreeReuse (_, cont)
    | Anf.ShadowPop (_, _, cont) | Anf.ShadowPush (_, _, _, cont) ->
        go extra acc cont
  in
  go Ident.Set.empty Ident.Set.empty e

let compile name src =
  match
    Frontend.compile_implementation ~filename:(name ^ ".ml")
      ~modname:(String.uncapitalize_ascii name) src
  with
  | Error { msg } ->
      Printf.printf "%s: ERROR %s\n" name msg;
      None
  | Ok lam -> (
      match Anf.of_lambda lam with
      | Error msg ->
          Printf.printf "%s: ANF error %s\n" name msg;
          None
      | Ok anf -> Some anf)

let assert_no_release name anf =
  let static_ids = static_fun_ids anf.Anf.code in
  let arc = Arc_pass.run anf in
  let bad =
    Ident.Set.fold
      (fun id acc ->
        let n = count_release id arc.Anf.code in
        if n > 0 then begin
          Printf.printf "%s: static fun %s released %d times\n" name
            (Ident.name id) n;
          acc + 1
        end
        else acc)
      static_ids 0
  in
  if static_ids = Ident.Set.empty then begin
    Printf.printf "%s: ERROR no static funs found (test bug)\n" name;
    false
  end
  else if bad = 0 then begin
    Printf.printf "%s: PASS (%d static funs, 0 releases)\n" name
      (Ident.Set.cardinal static_ids);
    true
  end
  else false

let nested_branch_helper =
  {|
let f x =
  if x > 0 then
    let helper y = y + 1 in
    helper x
  else x - 1

let r = f 3
|}

let nested_branch_letrec =
  {|
let g n =
  if n > 0 then
    let rec ev x = if x = 0 then 1 else od (x - 1)
    and od x = if x = 0 then 0 else ev (x - 1) in
    ev n
  else n

let r = g 4
|}

let toplevel_helper =
  {|
let h x = x + 1

let f x = h x + h (x * 2)

let r = f 3
|}

let seq_unexported_helper =
  {|
let outer n =
  let h x = x + 1 in
  let f y = h y + h (y * 2) in
  f n

let r = outer 3
|}

let capturing =
  {|
let k n =
  let cap y = y + n in
  cap 1 + cap 2

let r = k 3
|}

let () =
  let failures = ref 0 in
  let expect_ok name ok =
    Printf.printf "%s: %s\n" name (if ok then "PASS" else "FAIL");
    if not ok then incr failures
  in
  (* Controls that must already hold. *)
  (match compile "toplevel_helper" toplevel_helper with
  | Some anf -> expect_ok "toplevel helper not released" (assert_no_release "toplevel_helper" anf)
  | None -> incr failures);
  (match compile "capturing" capturing with
  | Some anf ->
      let cap_ids =
        Ident.Set.filter
          (fun id -> String.equal (Ident.name id) "cap")
          (static_fun_ids anf.Anf.code)
      in
      expect_ok "capturing nested fun still owned"
        (Ident.Set.is_empty cap_ids)
  | None -> incr failures);
  (* Regressions: non-capturing helpers inside branches. *)
  (match compile "nested_branch_helper" nested_branch_helper with
  | Some anf -> expect_ok "branch helper not released" (assert_no_release "nested_branch_helper" anf)
  | None -> incr failures);
  (match compile "nested_branch_letrec" nested_branch_letrec with
  | Some anf -> expect_ok "branch letrec not released" (assert_no_release "nested_branch_letrec" anf)
  | None -> incr failures);
  (match compile "seq_unexported_helper" seq_unexported_helper with
  | Some anf -> expect_ok "sequential unexported helper not released" (assert_no_release "seq_unexported_helper" anf)
  | None -> incr failures);
  exit (if !failures = 0 then 0 else 1)
