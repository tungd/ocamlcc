(* Unit/IR test for [Tupled] function lowering and [value let rec]
   ([caml_alloc_dummy*] / [caml_update_dummy]) lowering. *)

let has_substr ~sub s =
  let sl = String.length sub in
  let n = String.length s in
  if sl = 0 then true
  else if sl > n then false
  else
    let rec go i =
      if i > n - sl then false
      else if String.sub s i sl = sub then true
      else go (i + 1)
    in
    go 0

let test_tupled () =
  let x = Ident.create_local "x" in
  let y = Ident.create_local "y" in
  let f = Ident.create_local "tup_add" in
  let attr : Lambda.function_attribute =
    { inline = Default_inline;
      specialise = Default_specialise;
      local = Default_local;
      poll = Default_poll;
      is_a_functor = false;
      stub = false;
      tmc_candidate = false;
      may_fuse_arity = true }
  in
  let lf =
    Lambda.lfunction' ~kind:Tupled
      ~params:[ (x, Pgenval); (y, Pgenval) ]
      ~return:Pintval
      ~body:(Lambda.Lprim (Paddint, [ Lambda.Lvar x; Lambda.Lvar y ], Loc_unknown))
      ~attr ~loc:Loc_unknown
  in
  let code =
    Lambda.Llet
      ( Strict, Pgenval, f, Lambda.Lfunction lf,
        Lambda.Lapply
          { ap_func = Lambda.Lvar f;
            ap_args =
              [ Lambda.Lprim
                  ( Pmakeblock (0, Immutable, None),
                    [ Lambda.Lconst (Const_int 10); Lambda.Lconst (Const_int 32) ],
                    Loc_unknown ) ];
            ap_loc = Loc_unknown;
            ap_tailcall = Default_tailcall;
            ap_inlined = Default_inline;
            ap_specialised = Default_specialise } )
  in
  let prog : Lambda.program =
    { module_ident = Ident.create_local "TupledTest";
      main_module_block_size = 0;
      required_globals = Ident.Set.empty;
      code }
  in
  match Anf.of_lambda ~use_builtins:false prog with
  | Error msg ->
      Printf.printf "tupled_anf: FAIL (%s)\n" msg;
      false
  | Ok anf ->
      let anf = Arc_pass.run anf in
      let il = Qbe_il.to_string (Codegen.compile_program anf) in
      let ok =
        has_substr ~sub:"tup_add" il && has_substr ~sub:"call extern $arc_alloc(" il
      in
      Printf.printf "tupled_anf: %s\n" (if ok then "PASS" else "FAIL");
      ok

let test_value_letrec () =
  let src =
    "type ilist = Nil | Cons of int * ilist\n\
     let rec ones = Cons (1, ones)\n\
     let head = match ones with Nil -> 0 | Cons (x, _) -> x"
  in
  match
    Pipeline.compile_source
      { (Pipeline.Request.create ~filename:"val_rec.ml" ~modname:"Val_rec") with
        nopervasives = true; nostdlib = true } src
  with
  | Error msg ->
      Printf.printf "value_letrec: FAIL (%s)\n" msg;
      false
  | Ok { Pipeline.Output.ssa = il; _ } ->
      let ok =
        has_substr ~sub:"call extern $caml_alloc_dummy(" il
        && has_substr ~sub:"call extern $caml_update_dummy(" il
      in
      Printf.printf "value_letrec: %s\n" (if ok then "PASS" else "FAIL");
      ok

let () =
  let r1 = test_tupled () in
  let r2 = test_value_letrec () in
  exit (if r1 && r2 then 0 else 1)
