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
  require (function_body unsafe "twice") "call $ocamlcc_Borrow_params_use_borrowed(";
  forbid (function_body unsafe "use_borrowed") "arc_release"

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


let () =
  let il = compile {|
    external length : string -> int = "%string_length"
    external ( + ) : int -> int -> int = "%addint"
    external use_owned : int -> string -> int = "foreign_native" "foreign_native"
    let[@inline never] consume x = (x, x)
    let[@inline never] route keep x =
      let result = consume x in
      length keep + use_owned 0 (match result with y, _ -> y)
    let call keep x = route keep x + length keep
  |} in
  require (function_body il "call") "call $ocamlcc_Borrow_params_route_borrowed(";
  let worker = function_body il "route_borrowed" in
  require worker "call extern $ocamlcc_Borrow_params_consume("

let () =
  let il = compile {|
    external ( + ) : int -> int -> int = "%addint"
    type cursor = { row : int; col : int }
    type state = { mutable cursor : cursor }
    let read state = state.cursor.row + state.cursor.col
    let save state replacement =
      let old = state.cursor in
      state.cursor <- replacement;
      old.row
    let read_and_allocate state =
      let row = state.cursor.row in
      let col = state.cursor.col in
      (col, row)
  |} in
  forbid (function_body il "read") "arc_retain";
  forbid (function_body il "read_and_allocate") "arc_retain";
  require (function_body il "save") "call extern $arc_retain("

let () =
  let il = compile {|
    external put : bytes -> int -> char -> unit = "%bytes_unsafe_set"
    external length : bytes -> int = "%bytes_length"
    type row = { mutable content : bytes option }
    let[@inline never] write buffer = put buffer 0 'a'
    let[@inline never] replace row next = row.content <- next
    let write_then_length buffer = write buffer; length buffer
    let replace_then_read row next = replace row next; row.content
  |} in
  require (function_body il "write_then_length")
    "call $ocamlcc_Borrow_params_write_borrowed(";
  forbid (function_body il "write_borrowed") "arc_release";
  require (function_body il "replace_then_read")
    "call $ocamlcc_Borrow_params_replace_borrowed(";
  forbid (function_body il "replace_borrowed") "arc_retain"

let () =
  let dir = Filename.temp_dir "ocamlcc_borrow_import" "" in
  let prefix = Filename.concat dir "provider" in
  let exports = ref [] in
  let compile = function Ok il -> il | Error message -> failwith message in
  let provider = compile (Pipeline.compile_source ~nostdlib:true ~nopervasives:true
    ~filename:(prefix ^ ".ml") ~modname:"Provider" ~output_prefix:prefix
    ~emit_cmi:true ~seal_exports:true ~on_exports:(fun values -> exports := values) {|
      external put : bytes -> int -> char -> unit = "%bytes_unsafe_set"
      let[@inline never] write buffer index = put buffer index 'a'
  |}) in
  let obj = prefix ^ ".o" in
  Out_channel.with_open_bin obj (fun out -> output_string out provider);
  Export_summary.publish_object ~unit_name:"Provider" ~cmi:(prefix ^ ".cmi") ~obj !exports;
  let consumer = compile (Pipeline.compile_source ~nostdlib:true ~nopervasives:true
    ~include_dirs:[dir] ~load_exports:(Export_summary.loader ())
    ~filename:"borrow_params.ml" ~modname:"Borrow_params" {|
      external length : bytes -> int = "%bytes_length"
      let use buffer index = Provider.write buffer index; length buffer
  |}) in
  require provider "export function l $ocamlcc_Provider_write_borrowed__";
  let use = function_body consumer "use" in
  require use "call extern $ocamlcc_Provider_write_borrowed__";
  forbid use "arc_retain"
