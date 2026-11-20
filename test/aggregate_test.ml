let () =
  let il =
    match Pipeline.compile_source ~filename:"aggregates.ml" ~modname:"Aggregates" {|
      external observe : int -> int = "probe_observe"
      let tuple a b =
        let pair = (observe a, observe b) in
        observe (fst pair) + snd pair
      let option a =
        let value = Some (observe a) in
        match value with Some n -> n + 5 | None -> 0
      let result a =
        let value = Ok (observe a) in
        match value with Ok n -> n + 5 | Error _ -> 0
      let select_pair flag a =
        let pair =
          if flag then (observe a, observe 2) else (observe 3, observe 4)
        in
        fst pair + snd pair
      let select_result flag a =
        let result = if flag then Ok (observe a) else Ok (observe 7) in
        match result with Ok n -> n + 5 | Error _ -> 0
      let match_pair mode a =
        let pair = match mode with
          | 0 -> (observe a, observe 2)
          | 1 -> (observe 3, observe 4)
          | _ -> (observe 5, observe 6)
        in
        fst pair + snd pair
      let escape a = Some (observe a)
      let capture a =
        let value = (observe a, observe 10) in
        fun () -> fst value + snd value
    |} with
    | Ok il -> il
    | Error error -> failwith error
  in
  let check name allocates =
    let find value pos = Str.search_forward (Str.regexp_string value) il pos in
    let start = find ("function l $ocamlcc_Aggregates_" ^ name ^ "(") 0 in
    let finish = find "\n}" start in
    let has_alloc =
      match find "call extern $arc_alloc(" start with
      | index -> index < finish
      | exception Not_found -> false
    in
    if has_alloc <> allocates then failwith (name ^ ": unexpected allocation state")
  in
  check "tuple" false;
  check "option" false;
  check "result" false;
  check "select_pair" false;
  check "select_result" false;
  check "match_pair" false;
  check "escape" true;
  check "capture" true
