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
  let exports = ref [] in
  let provider = {|
    external ( + ) : int -> int -> int = "%addint"
    let step x = x + 1
    let pair choose x carry = if choose then x, carry else step x, None
  |} in
  let compile = function Ok il -> il | Error error -> failwith error in
  ignore (compile (Pipeline.compile_source ~nopervasives:true ~nostdlib:true
    ~filename:(prefix ^ ".ml") ~modname:"Inline_provider" ~output_prefix:prefix
    ~emit_cmi:true ~on_exports:(fun values -> exports := values) provider));
  let il = compile (Pipeline.compile_source ~nopervasives:true ~nostdlib:true
    ~include_dirs:[dir] ~imports:["Inline_provider", !exports]
    ~filename:"lambda_inline.ml" ~modname:"Lambda_inline" {|
    let first choose x carry =
      let n, _ = Inline_provider.pair choose x carry in n
    let opaque choose x carry =
      let n, _ = (Inline_provider.pair [@inlined never]) choose x carry in n
  |}) in
  let first = function_body il "first" in
  forbid first "ocamlcc_Inline_provider_pair";
  forbid first "call extern $arc_alloc(";
  require il "call extern $ocamlcc_init_Inline_provider(";
  require (function_body il "opaque") "ocamlcc_Inline_provider_pair"
