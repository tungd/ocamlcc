let compile request source =
  match Pipeline.compile_source request source with
  | Ok output -> output
  | Error error -> failwith error

let contains text part =
  match Str.search_forward (Str.regexp_string part) text 0 with
  | _ -> true
  | exception Not_found -> false

let () =
  let dir = Filename.temp_dir "ocamlcc-leaf-summary-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf dir) (fun () ->
    let prefix = Filename.concat dir "leaf_provider" in
    let obj = prefix ^ ".o" in
    let provider = compile
      { (Pipeline.Request.create ~filename:(prefix ^ ".ml") ~modname:"Leaf_provider") with
        output_prefix = Some prefix; emit_cmi = true; export_policy = Seal }
      {|
      type row = { cells : int array; length : int }
      let read row index =
        if index < row.length then row.cells.(index) else 0
      let[@inline never] read_out_of_line row index =
        if index < row.length then row.cells.(index) else 0
      |}
    in
    Sys_util.write_file obj "object";
    Export_summary.write_unit ~prefix provider.exports;
    Export_summary.write_unit_object (prefix ^ ".opt");
    let summaries = Export_summary.Loader.create () in
    let consume ?(summaries = summaries) source =
      compile { (Pipeline.Request.create ~filename:"leaf_consumer.ml" ~modname:"Leaf_consumer") with
                include_dirs = [dir]; summaries = Some summaries } source
    in
    let direct = "let read row index = Leaf_provider.read row index" in
    let consumer = consume direct in
    if contains consumer.ssa "call extern $ocamlcc_Leaf_provider_read__"
    then failwith "closed imported leaf was not inlined from its sidecar";
    assert (contains consumer.ssa "ocamlcc_raise_invalid_arg_oob");
    assert (contains consumer.ssa "call extern $ocamlcc_init_Leaf_provider__");
    let alias = consume {|
      let alias = Leaf_provider.read
      let read row index = alias row index
      |}
    in
    if not (contains alias.ssa "ocamlcc_raise_invalid_arg_oob") then
      failwith "imported leaf alias was not inlined";
    assert (contains alias.ssa "call extern $ocamlcc_init_Leaf_provider__");
    let explicit_call = consume {|
      let opt_out row index = (Leaf_provider.read [@inlined never]) row index
      let disabled row index = Leaf_provider.read_out_of_line row index
      |}
    in
    assert (contains explicit_call.ssa "call extern $ocamlcc_Leaf_provider_read__");
    assert (contains explicit_call.ssa "call extern $ocamlcc_Leaf_provider_read_out_of_line__");
    let unit_summary = prefix ^ ".opt" in
    let corrupt = Sys_util.read_file unit_summary
      |> Str.global_replace (Str.regexp "leaf=[^ \n]+") "leaf=i,v,i,var,999" in
    Sys_util.write_file unit_summary corrupt;
    Export_summary.write_unit_object unit_summary;
    let fallback = consume ~summaries:(Export_summary.Loader.create ()) direct in
    assert (contains fallback.ssa "call extern $ocamlcc_Leaf_provider_read__"))
