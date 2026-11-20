let compile source =
  match
    Pipeline.compile_source ~nostdlib:true ~nopervasives:true
      ~filename:"borrow_params.ml" ~modname:"Borrow_params" source
  with
  | Ok il -> il
  | Error message -> failwith message

let contains ~sub s =
  try ignore (Str.search_forward (Str.regexp_string sub) s 0); true
  with Not_found -> false

let require il sub =
  if not (contains ~sub il) then failwith ("missing in generated QBE: " ^ sub)

let forbid il sub =
  if contains ~sub il then failwith ("unexpected in generated QBE: " ^ sub)

let function_body il name =
  let header = Str.regexp_string ("function l $ocamlcc_Borrow_params_" ^ name ^ "(") in
  let first = Str.search_forward header il 0 in
  let last = Str.search_forward (Str.regexp_string "\n}") il first in
  String.sub il first (last - first)

let () =
  let il = compile {|
    external length : string -> int = "%string_length"
    external ( + ) : int -> int -> int = "%addint"
    let width text = length text
    let twice text =
      let first = width text in
      let second = width text in
      first + second
  |} in
  require (function_body il "twice") "call $ocamlcc_Borrow_params_width_borrowed(";
  require (function_body il "twice") "call extern $ocamlcc_Borrow_params_width(";
  forbid (function_body il "twice") "arc_retain_val";
  forbid (function_body il "width_borrowed") "arc_release_val";
  forbid il "export function l $ocamlcc_Borrow_params_width_borrowed";
  require (function_body il "width") "arc_release_val";
  let unsafe = compile {|
    external opaque : string -> int = "opaque_observer"
    external ( + ) : int -> int -> int = "%addint"
    let use x = opaque x
    let twice x = use x + use x
  |} in
  forbid unsafe "use_borrowed"
