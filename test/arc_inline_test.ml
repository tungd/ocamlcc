let source = {|
  external observe : 'a -> unit = "probe_observe"
  let duplicate v = v, v
  let discard v = observe v
|}

let () =
  let il =
    match Pipeline.compile_source
      { (Pipeline.Request.create ~filename:"arc_inline.ml" ~modname:"Arc_inline") with
        nopervasives = true; nostdlib = true } source with
    | Ok { Pipeline.Output.ssa = il; _ } -> il
    | Error error -> failwith error
  in
  let require fragment =
    let pattern = Str.regexp_string fragment in
    try ignore (Str.search_forward pattern il 0)
    with Not_found -> failwith ("missing in generated QBE: " ^ fragment)
  in
  List.iter require
    ["call extern $arc_retain("; "call extern $arc_release("; " =l and "; " =l cultl "]

let () =
  let il =
    match Pipeline.compile_source
      { (Pipeline.Request.create ~filename:"arc_inline.ml" ~modname:"Arc_inline") with
        nopervasives = true; nostdlib = true; inline_single_thread_rc = true } source with
    | Ok { Pipeline.Output.ssa = il; _ } -> il
    | Error error -> failwith error
  in
  let contains text =
    match Str.search_forward (Str.regexp_string text) il 0 with
    | _ -> true
    | exception Not_found -> false
  in
  List.iter (fun text -> if not (contains text) then
    failwith ("missing in single-thread QBE: " ^ text))
    ["call extern $ocamlcc_arc_enter_single_thread("; " =w loadw ";
     " =w add %rc_count."; " =w sub %rc_count."; "storew %rc_next.";
     "@rc_release_slow."; "call extern $arc_release("];
  if contains "call extern $arc_retain(" then
    failwith "single-thread retains must update the refcount directly"

let () =
  let il =
    match Pipeline.compile_source
      { (Pipeline.Request.create ~filename:"arc_fields.ml" ~modname:"Arc_fields") with
        nopervasives = true; nostdlib = true } {|
      external get : 'a array -> int -> 'a = "%array_safe_get"
      external set : 'a array -> int -> 'a -> unit = "%array_safe_set"
      type t = { mutable count : int; mutable item : string option }
      let int_store r count = r.count <- count
      let no_item r = r.item <- None
      let item r = r.item
      let get_pointer (a : string option array) i = get a i
      let set_pointer (a : string option array) i value = set a i value
      let set_int (a : int array) i value = set a i value
    |} with
    | Ok { Pipeline.Output.ssa = il; _ } -> il
    | Error error -> failwith error
  in
  let check name instruction expected =
    let find text start =
      Str.search_forward (Str.regexp_string text) il start
    in
    let start = find ("function l $ocamlcc_Arc_fields." ^ name ^ "(") 0 in
    let stop = find "\n}" start in
    let present =
      match find instruction start with
      | index -> index < stop
      | exception Not_found -> false
    in
    if present <> expected then
      failwith (Printf.sprintf "%s: expected %S = %b" name instruction expected)
  in
  check "int_store" "%oldf" false;
  check "int_store" "storel " true;
  check "no_item" "%oldf" true;
  List.iter (fun name -> check name "arc_release_val" false)
    ["int_store"; "no_item"; "set_pointer"; "set_int"];
  List.iter (fun name ->
    check name "arc_retain_val" false;
    check name "call extern $arc_retain(" true)
    ["item"; "get_pointer"]

let () =
  let source = {|
    external observe : 'a -> unit = "probe_observe"
    external create : int -> bytes = "caml_create_bytes"
    external make : int -> int -> int array = "caml_array_make"
    external get : int array -> int -> int = "%array_safe_get"
    external to_float : int -> float = "%floatofint"
    external (+) : int -> int -> int = "%addint"
    type 'a choice = Empty | Filled of 'a

    let unknown v = observe v
    let fresh (v : int) = let live = (v, v) in observe live
    let duplicate_fresh (v : int) = let live = (v, v) in observe (live, live)
    let phi cond (a : int) (b : int) =
      let live = if cond then (a, a) else (b, b) in observe live
    let mixed cond v =
      let live = if cond then Filled v else Empty in observe live
    let allocated_bytes size = observe (create size)
    let allocated_array size = observe (make size 1)
    let boxed n = observe (to_float n)
    let captured n = let f x = x + n in observe f
    let dereferenced a i = let x = get a i in observe x; observe a
    let conditional flag a =
      (if flag then observe (get a 0) else ()); observe a
    let loop a n = for i = 0 to n do observe (get a i) done
  |} in
  let il =
    match Pipeline.compile_source
      { (Pipeline.Request.create ~filename:"heap_guards.ml" ~modname:"Heap_guards") with
        nopervasives = true; nostdlib = true } source with
    | Ok { Pipeline.Output.ssa = il; _ } -> il
    | Error error -> failwith error
  in
  let body name =
    let find text pos = Str.search_forward (Str.regexp_string text) il pos in
    let start = find ("function l $ocamlcc_Heap_guards." ^ name ^ "(") 0 in
    String.sub il start (find "\n}" start - start)
  in
  let contains text fragment =
    try ignore (Str.search_forward (Str.regexp_string fragment) text 0); true
    with Not_found -> false
  in
  List.iter (fun name ->
    if contains (body name) "@rc_check." then failwith (name ^ ": split tag and null guard");
    if not (contains (body name) " =l cultl 1, %rc_lowbit.") then
      failwith (name ^ ": missing nullable heap guard"))
    ["unknown"; "mixed"; "conditional"];
  let dereferenced = body "dereferenced" in
  let receiver_pattern = Str.regexp "=l sub \\(%[^ ,]+\\), 8" in
  let _ = Str.search_forward receiver_pattern dereferenced 0 in
  let receiver = Str.matched_group 1 dereferenced in
  let success = Str.search_forward (Str.regexp_string "\n@bnd_ok.") dereferenced 0 in
  let success = String.sub dereferenced success (String.length dereferenced - success) in
  if not (contains success ("call extern $arc_release(l " ^ receiver ^ ")")) then
    failwith "dereferenced: missing receiver release";
  if contains success ("=l neg " ^ receiver ^ "\n") then
    failwith "dereferenced: guarded receiver after bounds check";
  let loop = body "loop" in
  if not (contains loop "cultl %fori.") then
    failwith "loop: bounds check did not use raw induction variable";
  List.iter (fun (name, prefix) ->
    let text = body name in
    if not (contains text ("call extern $arc_release(l %" ^ prefix)) then
      failwith (name ^ ": missing release of allocated value");
    if contains text "%rc_lowbit." then
      failwith (name ^ ": redundant heap guard"))
    [ "fresh", "blk."; "phi", "if."; "allocated_bytes", "bytes.";
      "allocated_array", "arr."; "boxed", "fbox."; "captured", "clos." ];
  let duplicate = body "duplicate_fresh" in
  if not (contains duplicate "call extern $arc_retain(l %blk.") then
    failwith "duplicate_fresh: missing retain of allocated value";
  if contains duplicate "%rc_lowbit." then failwith "duplicate_fresh: redundant heap guard"

let () =
  let source = {|
    external risky : int -> int = "probe_risky"
    external ( + ) : int -> int -> int = "%addint"
    let use n = risky n + 1
  |} in
  let body ~inline_single_thread_rc =
    let il =
      match Pipeline.compile_source
        { (Pipeline.Request.create ~filename:"exn_fast.ml" ~modname:"Exn_fast") with
          nopervasives = true; nostdlib = true; inline_single_thread_rc } source with
      | Ok { Pipeline.Output.ssa = il; _ } -> il
      | Error error -> failwith error
    in
    let find text pos = Str.search_forward (Str.regexp_string text) il pos in
    let start = find "function l $ocamlcc_Exn_fast.use(" 0 in
    String.sub il start (find "\n}" start - start)
  in
  let contains text pattern =
    match Str.search_forward (Str.regexp_string pattern) text 0 with
    | _ -> true
    | exception Not_found -> false
  in
  let shared = body ~inline_single_thread_rc:false in
  if not (contains shared "loadw extern $ocamlcc_exn_active") then
    failwith "shared exception check has no process-wide fast path";
  if not (contains shared "call extern $ocamlcc_get_exn(") then
    failwith "shared exception check lost its TLS slow path";
  let single = body ~inline_single_thread_rc:true in
  if not (contains single "loadl extern $ocamlcc_exn_slot") then
    failwith "single-thread exception check does not load the slot";
  if contains single "call extern $ocamlcc_get_exn(" then
    failwith "single-thread exception check still calls the runtime"

let () =
  let source = {|
    external risky : int -> int = "probe_risky"
    external keep : string -> int = "probe_keep" [@@noalloc]
    external raise : exn -> 'a = "%raise"
    external ( + ) : int -> int -> int = "%addint"
    let call text n = let result = risky n in result + keep text
    let branch text e cond = if cond then raise e else keep text
  |} in
  let il =
    match Pipeline.compile_source
      { (Pipeline.Request.create ~filename:"arc_cold.ml" ~modname:"Arc_cold") with
        nopervasives = true; nostdlib = true; inline_single_thread_rc = true } source with
    | Ok { Pipeline.Output.ssa = il; _ } -> il
    | Error error -> failwith error
  in
  let find text pos = Str.search_forward (Str.regexp_string text) il pos in
  let contains text pattern =
    match Str.search_forward (Str.regexp_string pattern) text 0 with
    | _ -> true
    | exception Not_found -> false
  in
  let check fn first next =
    let start = find ("function l $ocamlcc_Arc_cold." ^ fn ^ "(") 0 in
    let error = find ("\n@" ^ first ^ ".") start in
    let success = find ("\n@" ^ next ^ ".") error in
    let cleanup = String.sub il error (success - error) in
    if not (contains cleanup "call extern $arc_release_val(") then
      failwith (fn ^ ": missing compact release in exception cleanup");
    if contains cleanup "%rc_count." then
      failwith (fn ^ ": inlined reference counts in exception cleanup");
    let normal = String.sub il success (find "\n}" success - success) in
    if not (contains normal "%rc_count.") then
      failwith (fn ^ ": lost inline reference counts on the normal path")
  in
  check "call" "exn_err" "exn_ok";
  check "branch" "then" "else"
