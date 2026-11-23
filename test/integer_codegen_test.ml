let il =
  match Pipeline.compile_source (Pipeline.Request.create ~filename:"integer_codegen.ml" ~modname:"Integer_codegen") {|
    external observe : int -> unit = "probe_observe"
    let select (x : int) y = if x < y then 11 else 22
    let separated (x : int) y =
      let result = x < y in
      observe x;
      if result then 11 else 22
    let saved (x : int) y =
      let result = x < y in
      if result then (result, x) else (result, y)
    let count start stop =
      let i = ref start in
      while !i < stop do incr i done;
      !i
    let inc x = x + 1
    let dec x = x - 1
    let add_left x = (-7) + x
    let sub_left x = 0 - x
    let add_min x = x + (-4611686018427387904)
    let scale x = 4 * x
  |} with
  | Ok { Pipeline.Output.ssa = il; _ } -> il
  | Error error -> failwith error

let function_body name =
  let start = Str.search_forward
    (Str.regexp_string ("function l $ocamlcc_Integer_codegen_" ^ name ^ "(")) il 0 in
  let finish = Str.search_forward (Str.regexp_string "\n}") il start in
  String.sub il start (finish - start)

let check name pattern expected =
  let body = function_body name in
  let matches =
    match Str.search_forward (Str.regexp pattern) body 0 with
    | _ -> true
    | exception Not_found -> false
  in
  if matches <> expected then
    failwith (Printf.sprintf "%s: expected pattern %S = %b" name pattern expected)

let () =
  let fused = "\\(%[^ ]+\\) =l csltl [^\n]*\njnz \\1, @" in
  check "select" fused true;
  check "count" fused true;
  check "separated" "jnz %cmp\\.[0-9]+," true;
  check "separated" " =l shl " false;
  check "select" " =l shl " false;
  check "saved" " =l shl " true;
  check "inc" " =l add [^,\n]+, 2\n" true;
  check "inc" " =l sub " false;
  check "dec" " =l sub [^,\n]+, 2\n" true;
  check "dec" " =l add " false;
  check "add_left" " =l add [^,\n]+, -14\n" true;
  check "sub_left" " =l sub 2, %" true;
  check "add_min" " =l add [^,\n]+, -9223372036854775808\n" true;
  check "scale" " =l sar " false;
  check "scale" " =l shl [^,\n]+, 2\n" true
