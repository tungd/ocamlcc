let function_body il name =
  let start = Str.search_forward (Str.regexp ("function l \\$ocamlcc_Lambda_inline_" ^ name ^ "(")) il 0 in
  let stop = Str.search_forward (Str.regexp_string "\n}") il start in
  String.sub il start (stop - start)

let compile source =
  match Pipeline.compile_source ~filename:"lambda_inline.ml" ~modname:"Lambda_inline" source with
  | Ok il -> il
  | Error error -> failwith error

let contains text fragment =
  try ignore (Str.search_forward (Str.regexp_string fragment) text 0); true
  with Not_found -> false

let require body fragment =
  if not (contains body fragment) then failwith ("missing from caller: " ^ fragment)

let forbid body fragment =
  if contains body fragment then failwith ("unexpected in caller: " ^ fragment)

let () =
  let il = compile {|
    external observe : int -> unit = "probe_observe"
    let[@inline] step a b = observe (a + b)
    let run a = step a 1
  |} in
  let run = function_body il "run" in
  require run "call extern $probe_observe(";
  forbid run "call extern $ocamlcc_Lambda_inline_step("

let () =
  let step = String.concat ";\n" (List.init 24 (fun _ -> "observe y")) in
  let il = compile (Printf.sprintf {|
    external observe : int -> unit = "probe_observe"
    let[@inline never] opaque x = x + 1
    let apply n iter =
      let adjust x = opaque (x + n) in
      iter (fun x -> let y = adjust x in %s)
    let run n =
      apply n (fun step -> for i = 0 to n - 1 do step i done)
  |} step) in
  let run = function_body il "run" in
  require run "call extern $probe_observe(";
  require run "call extern $ocamlcc_Lambda_inline_opaque(";
  forbid run "call extern $ocamlcc_Lambda_inline_apply(";
  forbid run "call extern $ocamlcc_apply";
  forbid run "call extern $arc_alloc("
