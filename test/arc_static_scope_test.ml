open Anf

let () =
  let owner = Ident.create_local "owner" in
  let joined = Ident.create_local "joined" in
  let label = 1 in
  let nested = StaticCatch (StaticRaise (label, []), label, [], Halt Unit, None) in
  let code =
    Let (owner, MakeBlock (0, Scan_all, [Unit]),
      StaticCatch (LetJoin (joined, nested, StaticRaise (label, [])),
                   label, [], Halt (Var owner), None))
  in
  let program =
    { module_ident = Ident.create_persistent "Arc_static_scope";
      code; value_kinds = Ident.Map.empty; inline_bodies = Ident.Map.empty }
  in
  let result = Arc_pass.run program in
  match result.code with
  | Let (_, _, StaticCatch (LetJoin (_, _, exit), _, _, _, _)) ->
      let rec require_live = function
        | Release (id, _) when Ident.same id owner ->
            failwith "outer handler lost ownership after returning from the inner catch"
        | Release (_, next) -> require_live next
        | StaticRaise (target, []) when target = label -> ()
        | _ -> failwith "expected an exit to the outer handler"
      in
      require_live exit
  | _ -> failwith "expected a nested static catch"
