let compile source =
  match Pipeline.compile_source ~emit_entry:false ~filename:"native_ffi.ml"
          ~modname:"Native_ffi" source with
  | Ok il -> il
  | Error error -> failwith error

let contains il pattern =
  try ignore (Str.search_forward (Str.regexp pattern) il 0); true
  with Not_found -> false

let () =
  let il = compile {|
    external f : float -> float = "test_boxed" "test_double" [@@unboxed] [@@noalloc]
    let twice x = f (f x)
  |} in
  assert (contains il "=d call extern \\$test_double(d ");
  assert (not (contains il "call extern \\$test_boxed("));
  let call = Str.search_forward (Str.regexp_string "call extern $test_double(") il 0 in
  let after_call = String.sub il call (String.length il - call) in
  assert (not (contains after_call "call extern \\$ocamlcc_get_exn("))

let () =
  let il = compile {|
    external f : (int [@untagged]) -> float -> (int64 [@unboxed])
      = "test_mixed_boxed" "test_mixed"
    let call i fval = try f i fval with _ -> 42L
  |} in
  let find symbol pos = Str.search_forward (Str.regexp_string ("call extern $" ^ symbol ^ "(")) il pos in
  let native = find "test_mixed" 0 in
  let check = find "ocamlcc_get_exn" native in
  let boxing = find "ocamlcc_alloc_custom" check in
  assert (native < check && check < boxing)
