(* Negative diagnostic tests for ANF unsupported constructs & primitives. *)

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

let check_unsupported name source expect_sub =
  match
    Pipeline.compile_source ~nopervasives:true ~nostdlib:true
      ~filename:(name ^ ".ml") ~modname:"Test" source
  with
  | Ok _ ->
      Printf.printf "%s: FAIL expected Error\n" name;
      false
  | Error msg ->
      if has_substr ~sub:"unsupported:" msg && has_substr ~sub:expect_sub msg
      then begin
        Printf.printf "%s: PASS\n" name;
        true
      end
      else begin
        Printf.printf "%s: FAIL got %S expected %S\n" name msg expect_sub;
        false
      end

let check_missing_file () =
  match
    Pipeline.compile_file ~filename:"/nonexistent/ocamlcc_missing.ml"
      ~modname:"Missing" ()
  with
  | Ok _ ->
      Printf.printf "missing_file: FAIL expected Error\n";
      false
  | Error _ ->
      Printf.printf "missing_file: PASS\n";
      true

let () =
  let checks =
    [ (fun () ->
        check_unsupported "method_send" "let f o = o#m" "method call");
      (fun () ->
        check_unsupported "unknown_caml_prim"
          "external bad : int -> int = \"caml_unknown_prim\"\nlet _ = bad 1"
          "caml_unknown_prim");
      (fun () ->
        check_unsupported "wrong_arity_caml_prim"
          "external bad : int -> int = \"caml_compare\"\nlet _ = bad 1"
          "1 arguments");
      (fun () ->
        check_unsupported "too_many_c_args"
          "external f7 : int -> int -> int -> int -> int -> int -> int -> int = \"c_f7\"\nlet _ = f7 1 2 3 4 5 6 7"
          "c_f7");
      check_missing_file
    ]
  in
  let results = List.map (fun f -> f ()) checks in
  exit (if List.for_all Fun.id results then 0 else 1)
