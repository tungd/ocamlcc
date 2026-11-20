let () =
  let il =
    match
      Pipeline.compile_source ~filename:"shadow_codegen.ml"
        ~modname:"Shadow_codegen"
        "let invoke f s = let result = f s in (result, s)"
    with
    | Ok il -> il
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
    "loadw extern \\$ocamlcc_stackful_fibers_created\njnz [^\n]*, @shadow_active[^\n]*, @shadow_done[^\n]*\n@shadow_active[^\n]*\ncall extern \\$arc_fiber_push";
  check "shadow pop calls must be on the fiber-only branch"
    "loadw extern \\$ocamlcc_stackful_fibers_created\njnz [^\n]*, @shadow_active[^\n]*, @shadow_done[^\n]*\n@shadow_active[^\n]*\ncall extern \\$arc_fiber_pop"
