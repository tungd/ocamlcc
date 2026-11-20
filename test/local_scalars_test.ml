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

let () =
  let il =
    match Pipeline.compile_source ~filename:"numeric_loops.ml" ~modname:"Numeric_loops" {|
      let rec float_loop n (acc : float) =
        if n <= 0 then acc else float_loop (n - 1) (acc +. 2.)
      let rec integer_loop n (acc : int64) =
        if n <= 0 then acc else integer_loop (n - 1) (Int64.add acc 2L)
      let rec word_loop n (acc : int32) =
        if n <= 0 then acc else word_loop (n - 1) (Int32.add acc 2l)
      external observe_box : float -> unit = "numeric_observe_box"
      let rec boxed_loop n (acc : float) =
        observe_box acc;
        if n <= 0 then acc else boxed_loop (n - 1) (acc +. 2.)
    |} with
    | Ok il -> il
    | Error error -> failwith error
  in
  let body name =
    let find text pos = Str.search_forward (Str.regexp_string text) il pos in
    let start = find ("function l $ocamlcc_Numeric_loops_" ^ name ^ "(") 0 in
    let finish = find "\n}" start in
    String.sub il start (finish - start)
  in
  let check name phi allocator expected =
    let il = body name in
    let find text pos = Str.search_forward (Str.regexp_string text) il pos in
    let rec count pos =
      match find ("call extern $" ^ allocator ^ "(") pos with
      | i -> 1 + count (i + 1)
      | exception Not_found -> 0
    in
    if count 0 <> expected then failwith (name ^ ": wrong number of boxes");
    match find phi 0 with
    | _ -> ()
    | exception Not_found -> failwith (name ^ ": expected " ^ phi)
  in
  check "float_loop" " =d phi " "ocamlcc_alloc_float" 1;
  check "integer_loop" " =l add " "ocamlcc_alloc_custom" 1;
  check "word_loop" " =w phi " "ocamlcc_alloc_custom" 1;
  check "boxed_loop" "call extern $numeric_observe_box(" "ocamlcc_alloc_float" 1
