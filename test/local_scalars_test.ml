let () =
  let il =
    match Pipeline.compile_source ~filename:"local_scalars.ml" ~modname:"Local_scalars" {|
      let array (a : float array) i =
        let x = a.(i) in
        let y = x +. 2. in
        a.(i) <- y *. 3.
      let arithmetic (x : float) =
        let y = x +. 2. in
        y *. 3.
      let to_int x =
        let x = float_of_int x in
        int_of_float (abs_float (-.x *. 2.))
      let compare (x : float) =
        let y = x +. 2. in y < 0.
      let boxed_int x =
        let y = Int32.of_int x in
        let z = Int32.add y 1l in
        Int32.mul z 2l
    |} with
    | Ok il -> il
    | Error error -> failwith error
  in
  let count name symbol expected =
    let find value pos = Str.search_forward (Str.regexp_string value) il pos in
    let start = find ("function l $ocamlcc_Local_scalars_" ^ name ^ "(") 0 in
    let finish = find "\n}" start in
    let rec loop count pos =
      match find ("call extern $" ^ symbol ^ "(") pos with
      | index when index < finish -> loop (count + 1) (index + 1)
      | _ | exception Not_found -> count
    in
    let actual = loop 0 start in
    if actual <> expected then
      failwith (Printf.sprintf "%s: %s count %d, expected %d" name symbol actual expected)
  in
  count "array" "ocamlcc_alloc_float" 0;
  count "arithmetic" "ocamlcc_alloc_float" 1;
  count "to_int" "ocamlcc_alloc_float" 0;
  count "compare" "ocamlcc_alloc_float" 0;
  count "boxed_int" "ocamlcc_alloc_custom" 1
