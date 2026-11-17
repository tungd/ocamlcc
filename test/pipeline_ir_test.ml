(* End-to-end Pipeline -> QBE IL unit/IR tests. *)

let has_substr ~sub s =
  let sl = String.length sub in
  let n = String.length s in
  if sl = 0 then true
  else if sl > n then false
  else
    let rec go i =
      if i > n - sl then false
      else if String.sub s i sl = sub then true
      else go (i + 1)
    in
    go 0

let compile ?(emit_entry = true) name src =
  Pipeline.compile_source ~nopervasives:true ~nostdlib:true ~emit_entry
    ~filename:(name ^ ".ml") ~modname:(String.capitalize_ascii name) src

let check_il name ?emit_entry src needles =
  match compile ?emit_entry name src with
  | Error msg ->
      Printf.printf "%s: FAIL compile error: %s\n" name msg;
      false
  | Ok il ->
      let missing = List.filter (fun n -> not (has_substr ~sub:n il)) needles in
      if missing = [] then begin
        Printf.printf "%s: PASS\n" name;
        true
      end
      else begin
        Printf.printf "%s: FAIL missing [%s]\n" name
          (String.concat "; " missing);
        false
      end

let () =
  let ok1 =
    check_il "tail_loop_and_entry"
      "external ( + ) : int -> int -> int = \"%addint\"\n\
       external ( - ) : int -> int -> int = \"%subint\"\n\
       external ( <= ) : 'a -> 'a -> bool = \"%lessequal\"\n\
       let rec sum acc n = if n <= 0 then acc else sum (acc + n) (n - 1)\n\
       let res = sum 0 10"
      [ "export function $ocamlcc_module_init()";
        "export function $ocamlcc_init_Tail_loop_and_entry()";
        "@loop";
        "phi " ]
  in
  let ok2 =
    check_il "mod_no_entry" ~emit_entry:false
      "let id x = x"
      [ "export function $ocamlcc_init_Mod_no_entry()";
        "export data $ocamlcc_global_Mod_no_entry" ]
  in
  let ok2_no_main =
    match compile ~emit_entry:false "mod_no_entry2" "let id x = x" with
    | Ok il when not (has_substr ~sub:"ocamlcc_module_init" il) ->
        Printf.printf "mod_no_entry_omits_init: PASS\n";
        true
    | _ ->
        Printf.printf "mod_no_entry_omits_init: FAIL\n";
        false
  in
  let ok3 =
    check_il "closure_arc_and_exn"
      "external ( + ) : int -> int -> int = \"%addint\"\n\
       external raise : exn -> 'a = \"%raise\"\n\
       exception Boom of int\n\
       let make_adder x = fun y -> x + y\n\
       let f = make_adder 5\n\
       let v = try raise (Boom 1) with Boom n -> f n"
      [ "call extern $arc_alloc(";
        "call extern $arc_release_val(";
        "call extern $ocamlcc_apply1(" ]
  in
  exit (if ok1 && ok2 && ok2_no_main && ok3 then 0 else 1)
