let source = {|
  external observe : 'a -> unit = "probe_observe"
  let duplicate v = v, v
  let discard v = observe v
|}

let () =
  let il =
    match Pipeline.compile_source ~nopervasives:true ~nostdlib:true
      ~filename:"arc_inline.ml" ~modname:"Arc_inline" source with
    | Ok il -> il
    | Error error -> failwith error
  in
  let require fragment =
    let pattern = Str.regexp_string fragment in
    try ignore (Str.search_forward pattern il 0)
    with Not_found -> failwith ("missing in generated QBE: " ^ fragment)
  in
  List.iter require
    ["call extern $arc_retain("; "call extern $arc_release("; " =l and "; " =l ceql "]

let () =
  let il =
    match Pipeline.compile_source ~nopervasives:true ~nostdlib:true
      ~filename:"arc_fields.ml" ~modname:"Arc_fields" {|
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
    | Ok il -> il
    | Error error -> failwith error
  in
  let check name instruction expected =
    let find text start =
      Str.search_forward (Str.regexp_string text) il start
    in
    let start = find ("function l $ocamlcc_Arc_fields_" ^ name ^ "(") 0 in
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
