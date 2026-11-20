open Anf

let id = Ident.create_local

let collect_then_return value =
  Let (id "collected", Ccall ("caml_gc_major", [Unit]), Halt value)

let qbe code =
  { module_ident = id "Immediate_edges"; code }
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

let () =
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
