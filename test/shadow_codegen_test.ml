let () =
  let il =
    match
      Pipeline.compile_source (Pipeline.Request.create ~filename:"shadow_codegen.ml" ~modname:"Shadow_codegen")
        "let invoke f s = let result = f s in (result, s)"
    with
    | Ok { Pipeline.Output.ssa = il; _ } -> il
    | Error error -> failwith error
  in
  let contains pattern =
    match Str.search_forward (Str.regexp pattern) il 0 with
    | _ -> true
    | exception Not_found -> false
  in
  let check label pattern =
    if not (contains pattern) then failwith label
  in
  check "shadow push calls must be on the fiber-only branch"
    "loadw extern \\$ocamlcc_stackful_fibers_created\njnz [^\n]*, @shadow_active[^\n]*, @shadow_done[^\n]*\n@shadow_active[^\n]*\n\\([^@\n]+\n\\)*call extern \\$arc_fiber_push";
  check "shadow pop calls must be on the fiber-only branch"
    "loadw extern \\$ocamlcc_stackful_fibers_created\njnz [^\n]*, @shadow_active[^\n]*, @shadow_done[^\n]*\n@shadow_active[^\n]*\ncall extern \\$arc_fiber_pop"

let () =
  let request = Pipeline.Request.create ~filename:"shadow_codegen.ml" ~modname:"Shadow_codegen" in
  let ssa =
    match Pipeline.compile_source request {|
      let invoke f a b c =
        let first = f a in
        let second = f b in
        first, second, a, b, c
    |} with
    | Ok output -> output.ssa
    | Error error -> failwith error
  in
  let count pattern =
    let re = Str.regexp_string pattern in
    let rec count_from start n =
      match Str.search_forward re ssa start with
      | i -> count_from (i + String.length pattern) (n + 1)
      | exception Not_found -> n
    in
    count_from 0 0
  in
  if count "call extern $arc_fiber_push_batch(" <> 2 then
    failwith "each call must register its live roots in one batch";
  assert (count "call extern $arc_fiber_push(" = 0);
  assert (count "=l alloc8 " = 1)
