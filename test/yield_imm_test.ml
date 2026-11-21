(* Regression test: non-yielding pure integer functions must not emit
   ShadowPush/ShadowPop or Retain/Release/DropReuse on tagged immediates. *)

let compile src =
  match
    Frontend.compile_implementation ~filename:"yield_imm_fib.ml"
      ~modname:"Yield_imm_fib" src
  with
  | Error { Frontend.msg } ->
      prerr_endline msg;
      None
  | Ok lam -> (
      match Anf.of_lambda lam with
      | Error msg ->
          prerr_endline msg;
          None
      | Ok prog -> Some (Arc_pass.run prog))

let count_ops (e : Anf.aexpr) =
  let pushes = ref 0 in
  let pops = ref 0 in
  let arc_ops = ref 0 in
  let rec go = function
    | Anf.ShadowPush (_, _, _, cont) ->
        incr pushes;
        go cont
    | Anf.ShadowPop (_, _, cont) ->
        incr pops;
        go cont
    | Anf.Retain (_, cont) | Anf.Release (_, cont) | Anf.ReleaseMut (_, cont) ->
        incr arc_ops;
        go cont
    | Anf.DropReuse (_, _, cont) ->
        incr arc_ops;
        go cont
    | Anf.FreeReuse (_, cont) -> go cont
    | Anf.Halt _ | Anf.HaltScalar _ | Anf.Raise _ | Anf.Unwind | Anf.StaticRaise _ -> ()
    | Anf.Let (_, ce, body) | Anf.MutLet (_, ce, body) ->
        go_ce ce;
        go body
    | Anf.LetJoin (_, rhs, body) ->
        go rhs;
        go body
    | Anf.LetRec (bindings, body) ->
        List.iter (fun rb -> go rb.Anf.def.Anf.body) bindings;
        go body
    | Anf.If (_, th, el) | Anf.ScalarIf (_, _, th, el) | Anf.While (th, el)
    | Anf.CheckExn (_, th, el) ->
        go th;
        go el
    | Anf.Switch (_, sw) ->
        List.iter (fun (_, a) -> go a) sw.Anf.consts;
        List.iter (fun (_, a) -> go a) sw.Anf.blocks;
        Option.iter go sw.Anf.fail
    | Anf.StringSwitch (_, cases, fail) ->
        List.iter (fun (_, a) -> go a) cases;
        Option.iter go fail
    | Anf.StaticCatch (body, _, _, handler, _) ->
        go body;
        go handler
    | Anf.For (_, _, _, _, body) -> go body
    | Anf.TryWith (body, _, handler) ->
        go body;
        go handler
  and go_ce = function
    | Anf.Fun lf -> go lf.Anf.body
    | _ -> ()
  in
  go e;
  (!pushes, !pops, !arc_ops)

let () =
  let src =
    {|
let rec fib n =
  if n <= 1 then n else fib (n - 1) + fib (n - 2)

let _ = fib 10
|}
  in
  match compile src with
  | None -> exit 2
  | Some anf ->
      let pushes, pops, arc_ops = count_ops anf.Anf.code in
      Printf.printf "pushes=%d pops=%d arc_ops=%d\n" pushes pops arc_ops
