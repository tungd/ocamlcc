let source = {|
open Bigarray
type vector = (float, float64_elt, c_layout) Array1.t
let scale (src : vector) (dst : vector) factor =
  for i = 0 to Array1.dim src - 1 do dst.{i} <- src.{i} *. factor done
let get a i = Array1.unsafe_get a i
let write (a : (int32, int32_elt, fortran_layout) Array2.t) i j v =
  Array2.unsafe_set a i j v
let cell (a : (float, float32_elt, 'layout) Array3.t) i j k = a.{i,j,k}
|}

(* Follow the loop, control-flow and ARC continuations in the fixture. *)
let rec accesses = function
  | Anf.Let (_, ce, rest) | MutLet (_, ce, rest) ->
      (match ce with
       | BigarrayAccess (access, _) | Float64Load (access, _, _)
       | Float64Store (access, _, _, _) -> access :: accesses rest
       | _ -> accesses rest)
  | LetJoin (_, a, b) | If (_, a, b) | FloatIf (_, a, b) | CheckExn (a, b) ->
      accesses a @ accesses b
  | For (_, _, _, _, b) | Retain (_, b) | Release (_, b)
  | ShadowPush (_, _, _, b) | ShadowPop (_, _, b) -> accesses b
  | Halt _ | HaltFloat _ | Unwind -> []
  | _ -> failwith "unexpected control flow in Bigarray fixture"

let () =
  let lambda =
    match Frontend.compile_implementation ~filename:"access.ml" ~modname:"Access" source with
    | Ok p -> p | Error e -> failwith e.msg
  in
  let anf = Result.get_ok (Anf.of_lambda ~use_builtins:false lambda) in
  let expected : (string * Anf.bigarray_access list) list =
    let read : Anf.bigarray_access =
      { operation = `Get; rank = 1; kind = Pbigarray_float64;
        layout = Pbigarray_c_layout; checked = true }
    in
    [ "scale", [read; { read with operation = `Set }];
      "get", [{ read with kind = Pbigarray_unknown; layout = Pbigarray_unknown_layout;
                          checked = false }];
      "write", [{ operation = `Set; rank = 2; kind = Pbigarray_int32;
                  layout = Pbigarray_fortran_layout; checked = false }];
      "cell", [{ read with rank = 3; kind = Pbigarray_float32;
                           layout = Pbigarray_unknown_layout }] ]
  in
  let check p =
    let functions =
      List.map (fun (id, fn) -> Ident.name id, accesses fn.Anf.body)
        (Anf.pure_defs p.Anf.code)
    in
    List.iter (fun (name, want) ->
      if List.assoc_opt name functions <> Some want then
        failwith ("incorrect Bigarray access metadata in " ^ name)) expected
  in
  check anf;
  check (Arc_pass.run anf)
