open Anf

let id = Ident.create_local

let collect_then_return value =
  Let (id "collected", Ccall ("caml_gc_major", [Unit]), Halt value)

let qbe code =
  { module_ident = id "Immediate_edges"; code; value_kinds = Ident.Map.empty }
  |> Arc_pass.run
  |> Codegen.compile_program
  |> Qbe_il.to_string

let count text il =
  let pattern = Str.regexp_string text in
  let rec go offset total =
    match Str.search_forward pattern il offset with
    | at -> go (at + String.length text) (total + 1)
    | exception Not_found -> total
  in
  go 0 0

let check name want il =
  let got = count "call extern $arc_fiber_push(" il in
  if got <> want then
    failwith (Printf.sprintf "%s: expected %d shadow roots, got %d" name want got)

let catch ~mixed handler =
  let r = id "r" in
  let n = id "n" in
  let qty =
    if mixed then MakeBlock (0, [Int 4])
    else Binop (Add, Int 1, Int 3)
  in
  StaticCatch
    (If (Int 0,
         Let (n, qty, StaticRaise (1, [Var n])),
         StaticRaise (1, [Int 3])),
     1, [r], handler r, None)

let mutable_slot ~mixed =
  let slot = id "slot" and v = id "stored" and read = id "read" in
  let stored = if mixed then MakeBlock (0, [Int 8]) else Binop (Add, Int 4, Int 4) in
  let update =
    Let (v, stored, Let (id "assign", Assign (slot, Var v), Halt Unit))
  in
  MutLet (slot, Atom (Int 0),
    LetJoin (id "join", If (Int 0, update, Halt Unit),
      Let (read, Atom (MutVar slot), collect_then_return (Var read))))

let lambda_il code =
  let program : Lambda.program =
    { module_ident = id "Typed_edges"; main_module_block_size = 0;
      required_globals = Ident.Set.empty; code }
  in
  match Anf.of_lambda ~use_builtins:false program with
  | Error message -> failwith message
  | Ok anf ->
      let anf, effects = Arc_pass.run_with_effects anf in
      Codegen.compile_program anf |> Qbe_il.to_string, effects

let typed_edges () =
  let open Lambda in
  let loc = Debuginfo.Scoped_location.Loc_unknown in
  let prim p args = Lprim (p, args, loc) in
  let zero = Lconst (Const_int 0) in
  let collect value =
    Lsequence (prim (Pccall (Primitive.simple ~name:"caml_gc_major" ~arity:1
      ~alloc:true)) [zero], value)
  in
  let tuple = id "tuple" and n = id "field" in
  let project kind =
    Llet (Strict, kind, n,
      prim (Pfield (0, Pointer, Immutable)) [Lvar tuple],
      collect (Lvar n))
  in
  let wrap ?(return = Pgenval) body =
    let fn = id "read" in
    let lf = lfunction ~kind:Curried ~params:[tuple, Pgenval] ~return ~body
      ~attr:default_function_attribute ~loc in
    fn, Llet (Strict, Pgenval, fn, lf, Lvar fn)
  in
  let _, immediate = wrap (project Pintval) in
  let il, _ = lambda_il immediate in
  check "typed tuple projection" 0 il;
  if count "call extern $arc_retain(" il <> 0 then
    failwith "typed tuple projection emitted ARC";
  let _, pointer = wrap (project Pgenval) in
  check "pointer tuple projection" 1 (fst (lambda_il pointer));
  let external_int = prim (Pccall (Primitive.simple ~name:"opaque_int"
    ~arity:1 ~alloc:true)) [zero] in
  let slot = id "slot" in
  let _, mutable_slot =
    wrap (Lmutlet (Pintval, slot, zero,
      Lsequence (Lassign (slot, external_int), collect (Lmutvar slot))))
  in
  check "typed mutable slot" 0 (fst (lambda_il mutable_slot));
  let handler = id "handler" in
  let _, catch =
    wrap (Lstaticcatch (Lstaticraise (1, [external_int]),
      (1, [handler, Pintval]), collect (Lvar handler)))
  in
  check "typed handler parameter" 0 (fst (lambda_il catch));
  let fn, producer = wrap ~return:Pintval external_int in
  let _, effects = lambda_il producer in
  if not (snd (effects fn)) then failwith "typed return missing from call facts";
  let choice = id "choice" in
  let _, join =
    wrap (Llet (Strict, Pintval, choice,
      Lifthenelse (zero, external_int, zero), collect (Lvar choice)))
  in
  check "typed let join" 0 (fst (lambda_il join));
  let _, promoted =
    wrap (Llet (Strict, Pgenval, slot, prim (Pmakeblock (0, Mutable, Some [Pintval])) [zero],
      Lsequence (prim (Psetfield (0, Pointer, Assignment))
        [Lvar slot; prim (Pmakeblock (0, Immutable, None)) [Lvar tuple]],
        collect (prim (Pfield (0, Pointer, Mutable)) [Lvar slot]))))
  in
  check "promoted slot with a pointer write" 1 (fst (lambda_il promoted))

let () =
  typed_edges ();
  check "immediate handler binders" 0
    (qbe (catch ~mixed:false (fun r -> collect_then_return (Var r))));
  check "mixed handler binders" 1
    (qbe (catch ~mixed:true (fun r -> collect_then_return (Var r))));
  let joined = id "joined" in
  check "immediate catch result" 0
    (qbe (LetJoin (joined, catch ~mixed:false (fun r -> Halt (Var r)),
                   collect_then_return (Var joined))));
  let local = qbe (mutable_slot ~mixed:false) in
  check "immediate mutable slot and read" 0 local;
  (* Module initialization releases the exception itself before aborting. *)
  if count "call extern $arc_retain_val(" local <> 0
     || count "call extern $arc_release_val(" local <> 1
     || count "call extern $arc_retain(" local <> 0
     || count "call extern $arc_release(" local <> 0
  then failwith ("immediate mutable initializer, assignment and read should need no ARC\n" ^ local);
  check "mutable slot with a heap write" 2 (qbe (mutable_slot ~mixed:true))
