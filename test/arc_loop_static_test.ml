(* Regression tests for ARC ownership in loops & StaticRaise:
   1. Tail-position While/For with MutLet emits ReleaseMut on normal exit.
   2. StaticRaise from While/For/LetJoin rhs drops dead frame_borrowed vars.
   3. has_static_raise recurses into While/For bodies. *)

let count_release_mut (e : Anf.aexpr) : int =
  let rec go = function
    | Anf.ReleaseMut (_, cont) -> 1 + go cont
    | Halt _ | HaltScalar _ | Raise _ | Unwind | StaticRaise _ -> 0
    | Let (_, _, b) | MutLet (_, _, b) | LetRec (_, b)
    | Retain (_, b) | Release (_, b) | DropReuse (_, _, b) | FreeReuse (_, b)
    | ShadowPush (_, _, _, b) | ShadowPop (_, _, b) | For (_, _, _, _, b) ->
        go b
    | LetJoin (_, a, b) | If (_, a, b) | ScalarIf (_, _, a, b)
    | CheckExn (a, b) | While (a, b) | StaticCatch (a, _, _, b, _)
    | TryWith (a, _, b) ->
        go a + go b
    | Switch (_, sw) ->
        let arms =
          List.map snd sw.consts @ List.map snd sw.blocks
          @ Option.to_list sw.fail
        in
        List.fold_left (fun acc a -> acc + go a) 0 arms
    | StringSwitch (_, cs, fail) ->
        List.fold_left (fun acc (_, a) -> acc + go a)
          (Option.fold ~none:0 ~some:go fail) cs
  in
  go e

let count_release_of id (e : Anf.aexpr) : int =
  let rec go = function
    | Anf.Release (x, cont) -> (if Ident.same x id then 1 else 0) + go cont
    | Halt _ | HaltScalar _ | Raise _ | Unwind | StaticRaise _ -> 0
    | Let (_, _, b) | MutLet (_, _, b) | LetRec (_, b)
    | Retain (_, b) | ReleaseMut (_, b) | DropReuse (_, _, b)
    | FreeReuse (_, b) | ShadowPush (_, _, _, b) | ShadowPop (_, _, b)
    | For (_, _, _, _, b) ->
        go b
    | LetJoin (_, a, b) | If (_, a, b) | ScalarIf (_, _, a, b)
    | CheckExn (a, b) | While (a, b) | StaticCatch (a, _, _, b, _)
    | TryWith (a, _, b) ->
        go a + go b
    | Switch (_, sw) ->
        let arms =
          List.map snd sw.consts @ List.map snd sw.blocks
          @ Option.to_list sw.fail
        in
        List.fold_left (fun acc a -> acc + go a) 0 arms
    | StringSwitch (_, cs, fail) ->
        List.fold_left (fun acc (_, a) -> acc + go a)
          (Option.fold ~none:0 ~some:go fail) cs
  in
  go e

let () =
  (* 1. Tail-position While with MutLet must emit ReleaseMut on normal exit. *)
  let m = Ident.create_local "m" in
  let tail_while =
    Anf.MutLet (m, Atom (Int 0), While (Halt (Int 0), Halt Unit))
  in
  let m_id = Ident.create_persistent "M" in
  let prog1 = Arc_pass.run { Anf.module_ident = m_id; code = tail_while } in
  let rm_while = count_release_mut prog1.code in

  (* 2. Tail-position For with MutLet must emit ReleaseMut on normal exit. *)
  let m2 = Ident.create_local "m2" in
  let idx = Ident.create_local "i" in
  let tail_for =
    Anf.MutLet
      (m2, Atom (Int 0), For (idx, Int 0, Int 3, Asttypes.Upto, Halt Unit))
  in
  let prog2 = Arc_pass.run { Anf.module_ident = m_id; code = tail_for } in
  let rm_for = count_release_mut prog2.code in

  (* 3. StaticRaise inside While inside StaticCatch must drop dead frame_borrowed x. *)
  let x = Ident.create_local "x" in
  let static_raise_in_while =
    Anf.Let
      ( x,
        MakeBlock (0, [ Int 1 ]),
        StaticCatch
          ( While (Halt (Int 1), StaticRaise (7, [])),
            7,
            [],
            Halt (Int 42),
            None ) )
  in
  let prog3 =
    Arc_pass.run { Anf.module_ident = m_id; code = static_raise_in_while }
  in
  let rel_x = count_release_of x prog3.code in
  Printf.printf "rm_while=%d rm_for=%d rel_x=%d\n" rm_while rm_for rel_x
