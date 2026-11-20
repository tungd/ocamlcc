let () =
  let source = {|
    let a1 f a = f a
    let a2 f a b = f a b
    let a3 f a b c = f a b c
    let a4 f a b c d = f a b c d
    let a5 f a b c d e = f a b c d e
  |} in
  let il =
    match Pipeline.compile_source ~filename:"apply.ml" ~modname:"Apply" source with
    | Ok il -> il
    | Error error -> failwith error
  in
  let contains s =
    try ignore (Str.search_forward (Str.regexp_string s) il 0); true
    with Not_found -> false
  in
  List.iter (fun arity ->
    let symbol = "call extern $ocamlcc_apply" ^ arity in
    if not (contains (symbol ^ "_raw(")) then failwith ("missing " ^ symbol ^ "_raw");
    if contains (symbol ^ "(") then failwith ("unexpected host gate " ^ symbol))
    ["1"; "2"; "3"; "4"; "_n"]
