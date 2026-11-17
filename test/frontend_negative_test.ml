(* Negative diagnostic tests for Frontend (parse, type, interface errors). *)

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

let check_impl_err name source expect_sub =
  match
    Frontend.compile_implementation ~nopervasives:true ~nostdlib:true
      ~filename:(name ^ ".ml") ~modname:"Test" source
  with
  | Ok _ ->
      Printf.printf "%s: FAIL expected Error\n" name;
      false
  | Error { msg } ->
      if has_substr ~sub:expect_sub msg then begin
        Printf.printf "%s: PASS\n" name;
        true
      end
      else begin
        Printf.printf "%s: FAIL missing %S in %S\n" name expect_sub msg;
        false
      end

let check_intf_err name source expect_sub =
  match
    Frontend.compile_interface ~nopervasives:true ~nostdlib:true
      ~filename:(name ^ ".mli") ~modname:"Test" source
  with
  | Ok path ->
      Printf.printf "%s: FAIL expected Error, got %s\n" name path;
      false
  | Error { msg } ->
      if has_substr ~sub:expect_sub msg then begin
        Printf.printf "%s: PASS\n" name;
        true
      end
      else begin
        Printf.printf "%s: FAIL missing %S in %S\n" name expect_sub msg;
        false
      end

let () =
  let checks =
    [ (fun () -> check_impl_err "syntax_error" "let x =" "Syntax error");
      (fun () -> check_impl_err "type_error" "let x : int = \"hello\"" "string");
      (fun () ->
        check_impl_err "unbound_value" "let x = missing_ident" "Unbound value");
      (fun () ->
        check_impl_err "unbound_module" "let x = No_such_mod.v" "Unbound module");
      (fun () ->
        check_intf_err "intf_unbound_type" "val x : Missing_type.t" "Unbound")
    ]
  in
  let results = List.map (fun f -> f ()) checks in
  exit (if List.for_all Fun.id results then 0 else 1)
