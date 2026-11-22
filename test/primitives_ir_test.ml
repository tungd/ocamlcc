(* Unit/IR test for float, float array, boxed integers (int32/int64/nativeint). *)

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

let check name src needles =
  match
    Pipeline.compile_source
      { (Pipeline.Request.create ~filename:(name ^ ".ml") ~modname:(String.capitalize_ascii name)) with
        nopervasives = true; nostdlib = true } src
  with
  | Error msg ->
      Printf.printf "%s: FAIL (%s)\n" name msg;
      false
  | Ok { Pipeline.Output.ssa = il; _ } ->
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
  let r1 =
    check "float_ops"
      "external ( +. ) : float -> float -> float = \"%addfloat\"\n\
       external ( -. ) : float -> float -> float = \"%subfloat\"\n\
       external ( *. ) : float -> float -> float = \"%mulfloat\"\n\
       external ( /. ) : float -> float -> float = \"%divfloat\"\n\
       external ( ~-. ) : float -> float = \"%negfloat\"\n\
       external abs_float : float -> float = \"%absfloat\"\n\
       external float_of_int : int -> float = \"%floatofint\"\n\
       external int_of_float : float -> int = \"%intoffloat\"\n\
       external ( < ) : 'a -> 'a -> bool = \"%lessthan\"\n\
       let calc a b n =\n\
         let c = (a +. b *. 2.5) -. (a /. 3.0) in\n\
         let d = -. (abs_float c) +. float_of_int n in\n\
         if d < 10.0 then int_of_float d else 0"
      [ "loadd"; "sltof"; "dtosi"; "ocamlcc_alloc_float"; "cltd" ]
  in
  let r2 =
    check "float_array_rec"
      "type ip = { a : float; b : float }\n\
       type pt = { x : float; mutable y : float }\n\
       external ( +. ) : float -> float -> float = \"%addfloat\"\n\
       external get : float array -> int -> float = \"%array_safe_get\"\n\
       external set : float array -> int -> float -> unit = \"%array_safe_set\"\n\
       let imm = { a = 1.0; b = 2.0 }\n\
       let test z =\n\
         let p = { x = 1.5; y = z } in\n\
         p.y <- p.x +. 0.5;\n\
         let arr = [| 1.5; 2.5; z |] in\n\
         set arr 0 (get arr 1); (imm, arr)"
      [ "h 254"; "l 254,"; "loadd"; "stored"; "ocamlcc_raise_invalid_arg_oob" ]
  in
  let r3 =
    check "boxed_ints"
      "external i32_add : int32 -> int32 -> int32 = \"%int32_add\"\n\
       external i32_div : int32 -> int32 -> int32 = \"%int32_div\"\n\
       external i32_of_int : int -> int32 = \"%int32_of_int\"\n\
       external i32_to_int : int32 -> int = \"%int32_to_int\"\n\
       external i64_add : int64 -> int64 -> int64 = \"%int64_add\"\n\
       external i64_of_i32 : int32 -> int64 = \"%int64_of_int32\"\n\
       external nat_mul : nativeint -> nativeint -> nativeint = \"%nativeint_mul\"\n\
       external ( < ) : 'a -> 'a -> bool = \"%lessthan\"\n\
       let work n =\n\
         let a = i32_add (i32_of_int n) 10l in\n\
         let b = i32_div a 2l in\n\
         let c = i64_add (i64_of_i32 b) 100L in\n\
         let d = nat_mul 3n 4n in\n\
         if d < 20n then (i32_to_int b, c) else (0, 0L)"
      [ "h 255"; "ocamlcc_alloc_custom"; "ocamlcc_global_Division_by_zero"; "extsw" ]
  in
  exit (if r1 && r2 && r3 then 0 else 1)
