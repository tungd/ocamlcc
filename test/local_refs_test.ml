let source = {|
  external escape : int ref -> unit = "probe_escape"

  let count n =
    let r = ref n in
    let alias = r in
    for i = 0 to n do
      incr alias;
      r := !r + i
    done;
    !r

  let[@inline] make n = ref (n + 1)

  let from_helper n =
    let r = make n in
    incr r;
    !r

  let escaped n =
    let r = ref n in
    escape r;
    !r

  let captured n =
    let r = ref n in
    fun () -> incr r; !r
|}

let function_body il name =
  let start = Str.search_forward (Str.regexp ("function l \\$ocamlcc_Local_refs_" ^ name ^ "(")) il 0 in
  let stop = Str.search_forward (Str.regexp_string "\n}") il start in
  String.sub il start (stop - start)

let contains text fragment =
  try ignore (Str.search_forward (Str.regexp_string fragment) text 0); true
  with Not_found -> false

let () =
  let il =
    match Pipeline.compile_source (Pipeline.Request.create ~filename:"local_refs.ml" ~modname:"Local_refs") source with
    | Ok { Pipeline.Output.ssa = il; _ } -> il
    | Error error -> failwith error
  in
  let alloc = "call extern $arc_alloc(l 0, l 1, l 8)" in
  let count = function_body il "count" in
  if contains count alloc then failwith "non-escaping ref was allocated";
  List.iter (fun fragment ->
    if contains count fragment then failwith ("ARC on immediate slot: " ^ fragment))
    ["call extern $arc_release"; "call extern $arc_retain"; "call extern $arc_fiber_push"];
  if contains (function_body il "from_helper") "call extern $arc_alloc" then
    failwith "non-escaping ref returned by inlined helper was allocated";
  List.iter (fun name ->
    if not (contains (function_body il name) alloc) then
      failwith ("the ref's address escapes from " ^ name))
    ["escaped"; "captured"]
