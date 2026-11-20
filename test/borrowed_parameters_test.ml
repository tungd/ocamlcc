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
  forbid (function_body il "twice") "arc_retain";
  forbid (function_body il "width_borrowed") "arc_release";
  forbid il "export function l $ocamlcc_Borrow_params_width_borrowed";
  require (function_body il "width") "call extern $arc_release(";
  let unsafe = compile {|
    external opaque : string -> int = "opaque_observer"
    external ( + ) : int -> int -> int = "%addint"
    let use x = opaque x
    let twice x = use x + use x
  |} in
  forbid unsafe "use_borrowed"

let () =
  let il = compile {|
    external length : string -> int = "%string_length"
    external ( + ) : int -> int -> int = "%addint"
    external ( - ) : int -> int -> int = "%subint"
    external ( = ) : int -> int -> bool = "%eq"
    let[@inline never] width text = length text
    let[@inline never] forward text = width text
    let[@inline never] use_forward text = forward text + length text
    let rec scan text n =
      if n = 0 then width text else scan text (n - 1)
    let use_scan text n = scan text n + length text
  |} in
  let borrowed name = "call $ocamlcc_Borrow_params_" ^ name ^ "_borrowed(" in
  require (function_body il "use_forward") (borrowed "forward");
  require (function_body il "forward_borrowed") (borrowed "width");
  require (function_body il "use_scan") (borrowed "scan");
  let worker = function_body il "scan_borrowed" in
  require worker (borrowed "width");
  forbid worker "call extern $arc_retain(";
  forbid worker "call extern $arc_release(";
  forbid il "export function l $ocamlcc_Borrow_params_scan_borrowed"

let () =
  let il = compile {|
    external length : string -> int = "%string_length"
    external ( + ) : int -> int -> int = "%addint"
    external ( - ) : int -> int -> int = "%subint"
    external ( = ) : int -> int -> bool = "%eq"
    let rec left text n = if n = 0 then length text else right text (n - 1)
    and right text n = if n = 0 then length text + 1 else left text (n - 1)
    let bridge text n = left text n + length text
    let rec keep text n = if n = 0 then text else alias text (n - 1)
    and alias text n = if n = 0 then text else keep text (n - 1)
    let use_keep text n = keep text n, length text
  |} in
  require il "left_borrowed_entry";
  require il "right_borrowed_entry";
  forbid il "keep_borrowed";
  forbid il "alias_borrowed"
