let function_body il name =
  let start = Str.search_forward (Str.regexp ("function l \\$ocamlcc_Lambda_inline_" ^ name ^ "(")) il 0 in
  let stop = Str.search_forward (Str.regexp_string "\n}") il start in
  String.sub il start (stop - start)

let compile source =
  match Pipeline.compile_source (Pipeline.Request.create ~filename:"lambda_inline.ml" ~modname:"Lambda_inline") source with
  | Ok { Pipeline.Output.ssa = il; _ } -> il
  | Error error -> failwith error

let contains text fragment =
  try ignore (Str.search_forward (Str.regexp_string fragment) text 0); true
  with Not_found -> false

let require body fragment =
  if not (contains body fragment) then failwith ("missing from caller: " ^ fragment)

let forbid body fragment =
  if contains body fragment then failwith ("unexpected in caller: " ^ fragment)

let budget_pressure =
  let repeated text = String.concat ";\n" (List.init 48 (fun _ -> text)) in
  Printf.sprintf {|
    external observe : int -> unit = "probe_observe"
    external add : int -> int -> int = "%%addint"
    let[@inline] small x = add x 1
    let[@inline] large x = %s
    let spend_remaining x = %s
    let spend_budget x = %s
  |} (repeated "observe x") (repeated "observe (small x)") (repeated "large x")

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
  let il = compile ({|
    let[@inline] physical row = row + 1
    let[@inline] grid_row (rows : int array) row = rows.(physical row)
    let read rows row = grid_row rows row
    let keep_call rows row = (grid_row [@inlined never]) rows row
    let[@inline] offset n =
      let n = (n lxor 47) + 3 in
      let n = (n lxor 33) + 12 in
      ((n lxor 9) + 5) lxor 2
    let[@inline] wide_row (rows : int array) row = rows.(offset (offset row))
    let keep_wide rows row = wide_row rows row
  |} ^ budget_pressure) in
  let read = function_body il "read" in
  forbid read "$ocamlcc_Lambda_inline_grid_row";
  forbid read "$ocamlcc_Lambda_inline_physical";
  require read "ocamlcc_raise_invalid_arg_oob";
  require (function_body il "keep_call") "$ocamlcc_Lambda_inline_grid_row";
  require (function_body il "keep_wide") "$ocamlcc_Lambda_inline_wide_row"

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

let () =
  let il = compile {|
    let count = ref 0
    module Make (Order : sig val key : int -> int end) = struct
      let () = incr count
      let[@inline never] project x = Order.key x + !count
    end
    module Asc_order = struct let key x = x end
    module Desc_order = struct let key x = -x end
    module Asc = Make (Asc_order)
    module Desc = Make (Desc_order)
    let asc x = Asc.project x
    let desc x = Desc.project x
  |} in
  List.iter (fun name ->
    let body = function_body il name in
    require body "$ocamlcc_Lambda_inline_project";
    forbid body "call extern $ocamlcc_apply") ["asc"; "desc"]

let () =
  let il = compile {|
    external length : string -> int = "%string_length"
    external initial : unit -> string = "probe_initial"
    module Classifier = struct
      let slots = 256
      let[@inline never] classify cp = cp land (slots - 1)
    end
    let secret = initial ()
    let[@inline never] score text = length text + length secret
    let use text = score text + score text
    let local n =
      let[@inline never] add_local x = x + n in
      add_local
  |} in
  let classify = function_body il "classify" in
  forbid classify "%clos.";
  let score = function_body il "score" in
  forbid score "%clos.";
  require score "loadl $ocamlcc_modvar_Lambda_inline_secret";
  let use = function_body il "use" in
  require use "call $ocamlcc_Lambda_inline_score_borrowed(";
  forbid use "call extern $ocamlcc_apply";
  require (function_body il "add_local") "%clos."

let () =
  let dir = Filename.temp_dir "ocamlcc_inline_provider" "" in
  let prefix = Filename.concat dir "inline_provider" in
  let provider = {|
    external ( + ) : int -> int -> int = "%addint"
    external set : int array -> int -> int -> unit = "%array_safe_set"
    let step x = x + 1
    let pair choose x carry = if choose then x, carry else step x, None
    let write cells i v = set cells i v
  |} in
  let compile = function Ok output -> output | Error error -> failwith error in
  let request =
    { (Pipeline.Request.create ~filename:(prefix ^ ".ml") ~modname:"Inline_provider") with
      nopervasives = true; nostdlib = true; output_prefix = Some prefix;
      emit_cmi = true; export_policy = Collect }
  in
  let exports = (compile (Pipeline.compile_source request provider)).exports in
  let il = compile (Pipeline.compile_source
    { (Pipeline.Request.create ~filename:"lambda_inline.ml" ~modname:"Lambda_inline") with
      nopervasives = true; nostdlib = true; include_dirs = [dir];
      imports = ["Inline_provider", exports] } {|
    let first choose x carry =
      let n, _ = Inline_provider.pair choose x carry in n
    let opaque choose x carry =
      let n, _ = (Inline_provider.pair [@inlined never]) choose x carry in n
  |}) in
  let il = il.ssa in
  let first = function_body il "first" in
  forbid first "ocamlcc_Inline_provider_pair";
  forbid first "call extern $arc_alloc(";
  require il "call extern $ocamlcc_init_Inline_provider(";
  require (function_body il "opaque") "ocamlcc_Inline_provider_pair";
  let forwarded = compile (Pipeline.compile_source
    { (Pipeline.Request.create ~filename:"lambda_inline.ml" ~modname:"Lambda_inline") with
      nopervasives = true; nostdlib = true; include_dirs = [dir];
      imports = ["Inline_provider", exports] } ({|
    type row = { cells : int array }
    let write row i v =
      let forward row i v = Inline_provider.write row.cells i v in
      forward row i v
  |} ^ budget_pressure)) in
  let write = function_body forwarded.ssa "write" in
  forbid write "$ocamlcc_Lambda_inline_forward";
  require write "ocamlcc_Inline_provider_write";
  require write "ocamlcc_exn_active"
