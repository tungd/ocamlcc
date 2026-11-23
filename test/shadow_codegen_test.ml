let compile source =
  let request = Pipeline.Request.create ~filename:"shadow_codegen.ml" ~modname:"Shadow_codegen" in
  match Pipeline.compile_source request source with
  | Ok output -> output.ssa
  | Error error -> failwith error

let () =
  let il = compile "let invoke f s = let result = f s in (result, s)" in
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
  let ssa = compile {|
      let invoke f a b c d =
        let first = f a in
        let second = f b in
        first, second, a, b, c, d
    |} in
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

let function_body ssa name =
  let find text offset = Str.search_forward (Str.regexp_string text) ssa offset in
  let start = find ("function l $ocamlcc_Shadow_codegen_" ^ name ^ "(") 0 in
  let finish = find "\n}" start in
  String.sub ssa start (finish - start)

let has_shadow ssa =
  match Str.search_forward (Str.regexp_string "$arc_fiber_push") ssa 0 with
  | _ -> true
  | exception Not_found -> false

let () =
  let ssa = compile {|
    let two f a = let result = f a in result, a
    let three f a b = let result = f a in result, a, b
    let four f a b c = let result = f a in result, a, b, c
  |} in
  List.iter (fun (name, arity) ->
    let body = function_body ssa name in
    let entry = Printf.sprintf "call extern $arc_fiber_push%d(" arity in
    let contains text =
      match Str.search_forward (Str.regexp_string text) body 0 with
      | _ -> true
      | exception Not_found -> false
    in
    if not (contains entry) then failwith (Printf.sprintf "missing %s in %s" entry name);
    assert (not (contains "=l alloc8 ")))
    ["two", 2; "three", 3; "four", 4]

let () =
  let ssa = compile {|
    external pause : unit -> unit = "ocamlcc_fiber_suspend"
    let[@inline never] choose enabled =
      if enabled then (fun x -> x) else (fun _ -> "none")
    let[@inline never] choose_pausing enabled = pause (); choose enabled
    let over enabled x = choose enabled x
    let over_pausing enabled x = choose_pausing enabled x
  |} in
  let split name callee =
    let body = function_body ssa name in
    let call = Str.regexp_string ("call extern $ocamlcc_Shadow_codegen_" ^ callee ^ "(") in
    let index = Str.search_forward call body 0 in
    String.sub body 0 index, String.sub body index (String.length body - index)
  in
  let first, second = split "over" "choose" in
  if has_shadow first then failwith "non-suspending first call has a shadow frame";
  assert (has_shadow second);
  let first, second = split "over_pausing" "choose_pausing" in
  assert (has_shadow first && has_shadow second)

let () =
  let ssa = compile {|
    external pause : unit -> unit = "ocamlcc_fiber_suspend"
    let[@inline never] later a b = pause (); a, b
    let partial a keep = let pending = later a in pending, keep
  |} in
  if has_shadow (function_body ssa "partial") then
    failwith "known partial application has a shadow frame"
