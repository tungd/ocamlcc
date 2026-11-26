(* Regression test: calls at the tail of non-tail join branches ([If],
   [Switch], [LetJoin] rhs) must not suppress [CheckExn] / [ShadowPush].
   Specifically, [typecore.ml] has [let body = if ... then ... else
   type_expect ... in body.exp_type] where [type_expect] sits at the tail of
   the [If] else-branch but NOT in function return position; suppressing
   [CheckExn] causes raised exceptions to continue into [body.exp_type] with
   the dummy [1] return value and crash. *)

let count_substring ~sub s =
  let sl = String.length s and nl = String.length sub in
  let rec loop i acc =
    if i + nl > sl then acc
    else if String.sub s i nl = sub then loop (i + nl) (acc + 1)
    else loop (i + 1) acc
  in
  if nl = 0 then 0 else loop 0 0

let extract_func ~name ssa =
  let marker = "function l $" ^ name ^ "(" in
  let sl = String.length ssa and ml = String.length marker in
  let rec find i =
    if i + ml > sl then failwith ("missing function " ^ name)
    else if String.sub ssa i ml = marker then i
    else find (i + 1)
  in
  let start = find 0 in
  let stop = String.index_from ssa start '}' in
  String.sub ssa start (stop - start + 1)

let () =
  let source =
    {|
      external ( = ) : 'a -> 'a -> bool = "%equal"
      external raise : exn -> 'a = "%raise"
      exception E

      let may_raise x = if x = 0 then raise E else (x, 1, 2, 3)

      let join_else flag x =
        let blk =
          if flag then (x, 1, 2, 3) else may_raise x
        in
        match blk with (a, _, _, _) -> a

      let true_tail x = may_raise x

      external ( + ) : int -> int -> int = "%addint"
      external get : 'a array -> int -> 'a = "%array_safe_get"
      external set : 'a array -> int -> 'a -> unit = "%array_safe_set"

      let[@inline never] increment x = x + 1
      let known_pure x = increment x + 1
      let index (a : int array) i = get a i + 1
      let generic a i = get a i
      let store a i v = set a i v; 3
    |}
  in
  match
    Pipeline.compile_source
      { (Pipeline.Request.create ~filename:"checkexn_join.ml" ~modname:"Checkexn_join") with
        nostdlib = true; nopervasives = true } source
  with
  | Error msg -> failwith ("Pipeline failed: " ^ msg)
  | Ok { Pipeline.Output.ssa = ssa; _ } ->
      let fn_ssa = extract_func ~name:"ocamlcc_Checkexn_join.join_else" ssa in
      assert (count_substring ~sub:"$ocamlcc_Checkexn_join.may_raise" fn_ssa = 1);
      (* One get_exn from entry finalizer poll + one from CheckExn on may_raise. *)
      assert (count_substring ~sub:"$ocamlcc_get_exn()" fn_ssa = 2);
      let tail_ssa = extract_func ~name:"ocamlcc_Checkexn_join.true_tail" ssa in
      (* True tail call elides post-call CheckExn (only entry poll remains). *)
      assert (count_substring ~sub:"$ocamlcc_get_exn()" tail_ssa = 1);
      List.iter (fun name ->
        let body = extract_func ~name:("ocamlcc_Checkexn_join." ^ name) ssa in
        let checks = count_substring ~sub:"$ocamlcc_get_exn()" body in
        if checks <> 1 then failwith (Printf.sprintf "%s: expected only the poll check, got %d" name checks);
        if name <> "known_pure" then
          assert (count_substring ~sub:"$ocamlcc_raise_invalid_arg_oob()" body = 1))
        ["index"; "generic"; "store"; "known_pure"]
