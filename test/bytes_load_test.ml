let compile source =
  let request = Pipeline.Request.create ~filename:"bytes_load.ml" ~modname:"Bytes_load" in
  match Pipeline.compile_source request source with
  | Ok output -> output.ssa
  | Error message -> failwith message

let contains s text =
  match Str.search_forward (Str.regexp_string text) s 0 with
  | _ -> true
  | exception Not_found -> false

let unboxed_load source opcode =
  let il = compile source in
  if contains il "ocamlcc_alloc_custom" || contains il "ocamlcc_global_Stdlib__Bytes"
  then failwith ("checked Bytes word load retains a boxed intermediate in " ^ source);
  assert (contains il opcode && contains il "ocamlcc_raise_invalid_arg_oob")

let () =
  unboxed_load "let read b i = Int32.to_int (Bytes.get_int32_ne b i)" "=w loadw %bgptr.";
  unboxed_load "let read b i = Int64.to_int (Bytes.get_int64_ne b i)" "=l loadl %bgptr.";
  if not Sys.big_endian then begin
    unboxed_load "let read b i = Int32.to_int (Bytes.get_int32_le b i)" "=w loadw %bgptr.";
    unboxed_load "let read b i = Int64.to_int (Bytes.get_int64_le b i)" "=l loadl %bgptr.";
    let escaping = compile "let read b i = Bytes.get_int64_le b i" in
    assert (contains escaping "=l loadl %bgptr." && contains escaping "ocamlcc_alloc_custom");
    let out_of_line = compile
      "let read b i = Int32.to_int ((Bytes.get_int32_le [@inlined never]) b i)"
    in
    assert (contains out_of_line "ocamlcc_global_Stdlib__Bytes")
  end
