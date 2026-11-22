let compile source =
  let request = Pipeline.Request.create ~filename:"bytes_store.ml" ~modname:"Bytes_store" in
  match Pipeline.compile_source request source with
  | Ok output -> output.ssa
  | Error message -> failwith message

let contains s text =
  match Str.search_forward (Str.regexp_string text) s 0 with
  | _ -> true
  | exception Not_found -> false

let unboxed_store source opcode =
  let il = compile source in
  if not (contains il opcode && contains il "ocamlcc_raise_invalid_arg_oob")
  then failwith ("missing checked store in " ^ source);
  if contains il "ocamlcc_alloc_custom" then failwith ("boxed store in " ^ source)

let () =
  unboxed_store
    "let write b i n = Bytes.set_int32_ne b i (Int32.of_int n)" "storew";
  if not Sys.big_endian then begin
    unboxed_store
      "let write b i n = Bytes.set_int32_le b i (Int32.of_int n)" "storew";
    unboxed_store
      "let write b i n = Bytes.set_int64_le b i (Int64.of_int n)" "storel";
    let escaping = compile
      "let write b i n = let x = Int32.of_int n in Bytes.set_int32_le b i x; x"
    in
    assert (contains escaping "storew" && contains escaping "ocamlcc_alloc_custom");
    let out_of_line = compile
      "let write b i n = (Bytes.set_int32_le [@inlined never]) b i (Int32.of_int n)"
    in
    assert (contains out_of_line "ocamlcc_global_Stdlib__Bytes");
    assert (contains out_of_line "ocamlcc_alloc_custom")
  end
