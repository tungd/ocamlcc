(* QBE 1.3 PIC IL emission test: external and exported symbols inside
   function bodies must be emitted with [extern $sym] so QBE emits GOT/PLT
   relocations for shared libraries, while local non-exported data/functions
   stay direct PC-relative [$sym]. *)

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

let () =
  let src =
    "external ( + ) : int -> int -> int = \"%addint\"\n\
     external c_fn : int -> int = \"my_c_ffi\"\n\
     let s = \"hello\"\n\
     let make_adder x = fun y -> x + y\n\
     let r = c_fn (make_adder 1 2)"
  in
  match
    Pipeline.compile_source
      { (Pipeline.Request.create ~filename:"pic_sample.ml" ~modname:"Pic_sample") with
        nopervasives = true; nostdlib = true } src
  with
  | Error msg ->
      Printf.printf "compile error: %s\n" msg;
      exit 1
  | Ok { Pipeline.Output.ssa = il; _ } ->
      let check name ok =
        Printf.printf "%s: %s\n" name (if ok then "PASS" else "FAIL");
        ok
      in
      let ok1 =
        check "extern_runtime_call" (has_substr ~sub:"call extern $arc_alloc(" il)
      in
      let ok2 =
        check "extern_ffi_call" (has_substr ~sub:"call extern $my_c_ffi(" il)
      in
      let ok3 =
        check "extern_exn_slot"
          (has_substr ~sub:"call extern $ocamlcc_get_exn()" il)
      in
      let ok4 =
        check "local_str_not_extern"
          (has_substr ~sub:"$str.0" il
          && not (has_substr ~sub:"extern $str.0" il))
      in
      let ok5 =
        check "extern_exported_global"
          (has_substr ~sub:"extern $ocamlcc_global_Pic_sample" il)
      in
      exit (if ok1 && ok2 && ok3 && ok4 && ok5 then 0 else 1)
