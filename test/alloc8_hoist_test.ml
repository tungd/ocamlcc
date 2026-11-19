(* Regression test: fixed-size Alloc8 instructions (MutLet, MakeArray Pgenarray,
   and >4-arg closure calls) must be hoisted to @start so loops and
   tail-recursive functions do not grow the stack via dynamic alloca. *)

let compile_qbe src =
  match
    Frontend.compile_implementation ~filename:"alloc8_hoist.ml"
      ~modname:"Alloc8_hoist" src
  with
  | Error { Frontend.msg } ->
      prerr_endline msg;
      None
  | Ok lam -> (
      match Anf.of_lambda lam with
      | Error msg ->
          prerr_endline msg;
          None
      | Ok prog ->
          let prog = Arc_pass.run prog in
          Some (Codegen.compile_program prog))

let count_non_start_alloc8 (prog : Qbe_il.module_) =
  let non_start = ref 0 in
  let in_start = ref 0 in
  let check_inst label = function
    | Qbe_il.Alloc8 _ ->
        if String.equal label "start" then incr in_start else incr non_start
    | _ -> ()
  in
  List.iter
    (fun (fn : Qbe_il.func) ->
      List.iter
        (fun (blk : Qbe_il.block) ->
          List.iter (check_inst blk.label) blk.insts)
        fn.blocks)
    prog.funcs;
  (!in_start, !non_start)

let () =
  let src =
    {|
let rec loop_gen x y n =
  if n <= 0 then 0
  else
    let _ = [| x; y |] in
    loop_gen x y (n - 1)

let loop_apply5 f n acc =
  let r = ref acc in
  for i = 1 to n do
    r := !r + f i 1 2 3 4
  done;
  !r
|}
  in
  match compile_qbe src with
  | None -> exit 2
  | Some qbe ->
      let in_start, non_start = count_non_start_alloc8 qbe in
      Printf.printf "in_start=%d non_start=%d\n"
        (if in_start >= 2 then 1 else 0)
        non_start
