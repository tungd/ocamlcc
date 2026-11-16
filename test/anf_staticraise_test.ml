(* ANF conversion regression test: [Lstaticraise] inside a let binding RHS.

   The pattern matcher's tuple-let optimization (Matching.assign_pat /
   simple_for_let) emits [Llet] chains whose tail is [Lstaticraise], e.g.

     (let (y = 4 x = 3) (exit 1 x y))

   When such a chain is itself the RHS of a binding, [Anf.conv_bind] walks
   the chain's let bodies and must lower the terminating [Lstaticraise] the
   same way [conv_expr] does: the bound continuation is unreachable, so the
   result is a bare [StaticRaise]. *)

let const n = Lambda.Lconst (Const_int n)

(* Minimal diagnostic dump for the shapes these tests build. *)
let rec dump (e : Anf.aexpr) : string =
  match e with
  | Anf.Halt a -> Printf.sprintf "(halt %s)" (dump_atom a)
  | Anf.Let (id, ce, body) ->
      Printf.sprintf "(let %s %s %s)" (Ident.name id) (dump_ce ce) (dump body)
  | Anf.MutLet (id, ce, body) ->
      Printf.sprintf "(mutlet %s %s %s)" (Ident.name id) (dump_ce ce) (dump body)
  | Anf.LetJoin (id, rhs, body) ->
      Printf.sprintf "(join %s %s %s)" (Ident.name id) (dump rhs) (dump body)
  | Anf.StaticRaise (i, args) ->
      Printf.sprintf "(exit %d [%s])" i (String.concat "," (List.map dump_atom args))
  | Anf.StaticCatch (body, hid, binders, h) ->
      Printf.sprintf "(catch %s with (%d [%s]) %s)" (dump body) hid
        (String.concat "," (List.map Ident.name binders)) (dump h)
  | Anf.Release (id, cont) ->
      Printf.sprintf "(release %s %s)" (Ident.name id) (dump cont)
  | Anf.ReleaseMut (id, cont) ->
      Printf.sprintf "(release_mut %s %s)" (Ident.name id) (dump cont)
  | Anf.Retain (id, cont) ->
      Printf.sprintf "(retain %s %s)" (Ident.name id) (dump cont)
  | _ -> "<other>"
and dump_atom (a : Anf.atom) : string =
  match a with
  | Anf.Var id -> Ident.name id
  | Anf.MutVar id -> "*" ^ Ident.name id
  | Anf.Int n -> string_of_int n
  | _ -> "<atom>"
and dump_ce (ce : Anf.cexpr) : string =
  match ce with
  | Anf.Atom a -> dump_atom a
  | Anf.Binop (op, a, b) ->
      Printf.sprintf "(binop%d %s %s)"
        (match op with Anf.Add -> 1 | _ -> 0)
        (dump_atom a) (dump_atom b)
  | _ -> "<cexpr>"

let check name ok =
  Printf.printf "%s: %s\n" name (if ok then "PASS" else "FAIL");
  ok

let () =
  let a = Ident.create_local "a" in
  let r = Ident.create_local "r" in
  (* staticcatch
       (let r = (let a = 1 in exit 7 [a]) in r)
     with (7 a) -> (halt handler-value) *)
  let code =
    Lambda.Lstaticcatch
      ( Lambda.Llet
          ( Strict, Pgenval, r,
            Lambda.Llet
              (Strict, Pgenval, a, const 1, Lambda.Lstaticraise (7, [ Lambda.Lvar a ])),
            Lambda.Lvar r ),
        (7, [ (a, Pgenval) ]),
        Lambda.Lmutvar a )
  in
  let ok =
    match
      Anf.of_lambda
        { Lambda.module_ident = Ident.create_local "Test";
          main_module_block_size = 0;
          required_globals = Ident.Set.empty;
          code }
    with
    | Error msg ->
        Printf.printf "conv error: %s\n" msg;
        false
    | Ok anf -> (
        match anf.Anf.code with
        | Anf.StaticCatch
            ( Anf.Let (init, Anf.Atom (Anf.Int 1), Anf.StaticRaise (7, [ Anf.Var a' ])),
              7,
              [ binder ],
              handler )
          when Ident.same a' a && Ident.same init a && Ident.same binder a ->
            (* the handler must still be present and lowered *)
            (match handler with
            | Anf.Halt (Anf.MutVar _) -> true
            | _ -> false)
        | other ->
            Printf.printf "unexpected ANF: %s\n%!" (dump other);
            false)
  in
  let ok2 =
    (* Control: the same exit in tail position already lowers fine, and the
       unused bound continuation is dropped the same way. *)
    let a2 = Ident.create_local "a2" in
    match
      Anf.of_lambda
        { Lambda.module_ident = Ident.create_local "Test2";
          main_module_block_size = 0;
          required_globals = Ident.Set.empty;
          code =
            Lambda.Lstaticcatch
              ( Lambda.Llet
                  (Strict, Pgenval, a2, const 1, Lambda.Lstaticraise (8, [])),
                (8, [ (a2, Pgenval) ]),
                Lambda.Lmutvar a2 ) }
    with
    | Ok anf -> (
        match anf.Anf.code with
        | Anf.StaticCatch
            (Anf.Let (_, Anf.Atom (Anf.Int 1), Anf.StaticRaise (8, [])), 8, _, _)
          ->
            true
        | _ -> false)
    | Error _ -> false
  in
  let ok3 =
    (* The exit may also carry atoms needing conversion, e.g. a primitive
       computation, which binds through a [Let] before the raise. *)
    let a3 = Ident.create_local "a3" in
    let sum =
      Lambda.Lprim (Paddint, [ const 1; const 2 ], Debuginfo.Scoped_location.Loc_unknown)
    in
    match
      Anf.of_lambda
        { Lambda.module_ident = Ident.create_local "Test3";
          main_module_block_size = 0;
          required_globals = Ident.Set.empty;
          code =
            Lambda.Lstaticcatch
              ( Lambda.Llet
                  (Strict, Pgenval, a3, Lambda.Lstaticraise (9, [ sum ]),
                  Lambda.Lmutvar a3 ),
                (9, [ (a3, Pgenval) ]),
                Lambda.Lmutvar a3 ) }
    with
    | Ok anf -> (
        match anf.Anf.code with
        | Anf.StaticCatch
            (Anf.Let
               ( _,
                 Anf.Binop (Anf.Add, Anf.Int 1, Anf.Int 2),
                 Anf.StaticRaise (9, [ Anf.Var _ ]) ),
             9, _, _) ->
            true
        | _ -> false)
    | Error _ -> false
  in
  let failures = ref 0 in
  if not (check "staticraise in let rhs" ok) then incr failures;
  if not (check "staticraise in tail position" ok2) then incr failures;
  if not (check "staticraise with atom args" ok3) then incr failures;
  exit (if !failures = 0 then 0 else 1)
