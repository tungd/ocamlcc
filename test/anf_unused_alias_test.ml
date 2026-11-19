(* Regression test for unused Alias / StrictOpt let bindings in Lambda IR.

   OCaml's pattern matcher shares catch arms across constructors with different
   payload arities (for example Typedtree.shallow_iter_pattern_desc sharing an
   arm across 5-field Tpat_alias and 1-field Tpat_lazy / Tpat_value). It emits
   Llet(Alias, ..., Pfield(4, param), ...) for unused wildcard fields and
   relies on 0-occurrence Alias / StrictOpt bindings being dropped rather than
   evaluated out of bounds at runtime. *)

let contains_substring ~sub s =
  let sl = String.length s and nl = String.length sub in
  let rec loop i =
    if i + nl > sl then false
    else if String.sub s i nl = sub then true
    else loop (i + 1)
  in
  nl = 0 || loop 0

let extract_func ~name ssa =
  let marker = "function l $" ^ name ^ "(" in
  let sl = String.length ssa and ml = String.length marker in
  let rec find i =
    if i + ml > sl then failwith ("missing function " ^ name)
    else if String.sub ssa i ml = marker then i
    else find (i + 1)
  in
  let start = find 0 in
  let stop = String.index_from ssa start '}' in
  String.sub ssa start (stop - start + 1)

let rec aexpr_has_field idx = function
  | Anf.Let (_, ce, body) | Anf.MutLet (_, ce, body) ->
      cexpr_has_field idx ce || aexpr_has_field idx body
  | Anf.LetRec (bindings, body) ->
      List.exists
        (fun (rb : Anf.rec_binding) -> aexpr_has_field idx rb.def.body)
        bindings
      || aexpr_has_field idx body
  | Anf.LetJoin (_, rhs, body) ->
      aexpr_has_field idx rhs || aexpr_has_field idx body
  | Anf.If (_, t, e) | Anf.ScalarIf (_, _, t, e) ->
      aexpr_has_field idx t || aexpr_has_field idx e
  | Anf.Switch (_, sw) ->
      List.exists (fun (_, arm) -> aexpr_has_field idx arm) sw.consts
      || List.exists (fun (_, arm) -> aexpr_has_field idx arm) sw.blocks
      || Option.fold ~none:false ~some:(aexpr_has_field idx) sw.fail
  | Anf.StringSwitch (_, cases, fail) ->
      List.exists (fun (_, arm) -> aexpr_has_field idx arm) cases
      || Option.fold ~none:false ~some:(aexpr_has_field idx) fail
  | Anf.StaticCatch (b, _, _, h, _) | Anf.TryWith (b, _, h) ->
      aexpr_has_field idx b || aexpr_has_field idx h
  | Anf.While (c, b) | Anf.CheckExn (c, b) ->
      aexpr_has_field idx c || aexpr_has_field idx b
  | Anf.For (_, _, _, _, b)
  | Anf.Retain (_, b)
  | Anf.Release (_, b)
  | Anf.ReleaseMut (_, b)
  | Anf.DropReuse (_, _, b)
  | Anf.FreeReuse (_, b)
  | Anf.ShadowPush (_, _, _, b)
  | Anf.ShadowPop (_, _, b) -> aexpr_has_field idx b
  | Anf.Halt _ | Anf.HaltScalar _ | Anf.Raise _ | Anf.Unwind
  | Anf.StaticRaise _ -> false

and cexpr_has_field idx = function
  | Anf.Field (i, _) -> i = idx
  | Anf.Fun lf -> aexpr_has_field idx lf.body
  | _ -> false

let () =
  (* 1. Unused chained Alias + StrictOpt bindings must be dropped. *)
  let p = Ident.create_local "param" in
  let mid = Ident.create_local "mid" in
  let unused_alias = Ident.create_local "unused_alias" in
  let unused_opt = Ident.create_local "unused_opt" in
  let mod_id = Ident.create_persistent "UnusedAliasTest" in
  let lam_code : Lambda.lambda =
    Lambda.Llet
      ( Lambda.Alias,
        Lambda.Pgenval,
        mid,
        Lambda.Lprim (Lambda.Pfield (4, Pointer, Mutable), [ Lambda.Lvar p ], Loc_unknown),
        Lambda.Llet
          ( Lambda.Alias,
            Lambda.Pgenval,
            unused_alias,
            Lambda.Lprim
              (Lambda.Pfield (3, Pointer, Mutable), [ Lambda.Lvar mid ], Loc_unknown),
            Lambda.Llet
              ( Lambda.StrictOpt,
                Lambda.Pgenval,
                unused_opt,
                Lambda.Lprim
                  ( Lambda.Pfield (2, Pointer, Mutable),
                    [ Lambda.Lvar p ],
                    Loc_unknown ),
                Lambda.Lvar p ) ) )
  in
  let prog : Lambda.program =
    { Lambda.module_ident = mod_id;
      main_module_block_size = 0;
      required_globals = Ident.Set.empty;
      code = lam_code;
    }
  in
  (match Anf.of_lambda ~use_builtins:false prog with
  | Error e -> failwith ("Anf.of_lambda failed: " ^ e)
  | Ok anf ->
      assert (not (aexpr_has_field 4 anf.code));
      assert (not (aexpr_has_field 3 anf.code));
      assert (not (aexpr_has_field 2 anf.code)));

  (* 2. Unused Strict binding must still be retained. *)
  let strict_id = Ident.create_local "strict_keep" in
  let strict_code : Lambda.lambda =
    Lambda.Llet
      ( Lambda.Strict,
        Lambda.Pgenval,
        strict_id,
        Lambda.Lprim (Lambda.Pfield (1, Pointer, Mutable), [ Lambda.Lvar p ], Loc_unknown),
        Lambda.Lvar p )
  in
  let strict_prog : Lambda.program =
    { prog with Lambda.code = strict_code }
  in
  (match Anf.of_lambda ~use_builtins:false strict_prog with
  | Error e -> failwith ("Anf.of_lambda strict failed: " ^ e)
  | Ok anf -> assert (aexpr_has_field 1 anf.code));

  (* 3. Full frontend -> QBE SSA test matching shared GADT pattern arm. *)
  let source =
    {|
      type t =
        | C0
        | B0 of int * int * int
        | B1 of int * int * int * int * int
        | B2 of int
        | B3 of int

      let f g = function
        | C0 -> ()
        | B0 _ -> ()
        | B1 (x, _, _, _, _) -> g x
        | B2 x -> g x
        | B3 x -> g x
    |}
  in
  match
    Pipeline.compile_source ~nostdlib:true ~nopervasives:true
      ~filename:"shared_arm.ml" ~modname:"Shared_arm" source
  with
  | Error msg -> failwith ("Pipeline failed: " ^ msg)
  | Ok ssa ->
      let fn_ssa = extract_func ~name:"ocamlcc_Shared_arm_f" ssa in
      assert (not (contains_substring ~sub:", 32\n" fn_ssa));
      assert (not (contains_substring ~sub:", 24\n" fn_ssa));
      assert (not (contains_substring ~sub:", 16\n" fn_ssa));
      assert (not (contains_substring ~sub:", 8\n" fn_ssa))
