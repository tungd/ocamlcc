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
