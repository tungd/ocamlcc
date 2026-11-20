let compile ?(include_dirs = []) ?(nostdlib = false) ?stdlib_dir source =
  match Pipeline.compile_source ~include_dirs ~nostdlib ?stdlib_dir
    ~filename:"int_selection.ml" ~modname:"Int_selection" source with
  | Ok il -> il
  | Error message -> failwith message

let contains il text =
  try
    ignore (Str.search_forward (Str.regexp_string text) il 0);
    true
  with Not_found -> false

let require il text =
  if not (contains il text) then failwith ("missing in generated QBE: " ^ text)

let forbid il text =
  if contains il text then failwith ("unexpected in generated QBE: " ^ text)

let saturated_source = "let f lo hi x = Int.max lo (Stdlib.Int.min hi x)"

let test_competing_interface () =
  let dir = Filename.temp_dir "ocamlcc_int_selection" "" in
  let prefix = Filename.concat dir "stdlib__Int" in
  let ml = prefix ^ ".mli" and cmi = prefix ^ ".cmi" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists ml then Sys.remove ml;
      if Sys.file_exists cmi then Sys.remove cmi;
      Sys.rmdir dir)
    (fun () ->
      Out_channel.with_open_text ml (fun oc ->
          output_string oc "val min : int -> int -> int
");
      (match Pipeline.compile_interface_file ~nostdlib:true ~nopervasives:true
        ~output_prefix:prefix ~filename:ml ~modname:"Stdlib__Int" () with
      | Ok _ -> ()
      | Error message -> failwith message);
      let custom = compile ~include_dirs:[dir] "let f a b = Stdlib__Int.min a b" in
      require custom "ocamlcc_global_Stdlib__Int";
      forbid custom "cslel")

let () =
  let saturated = compile saturated_source in
  require saturated "cslel";
  require saturated "csgel";
  forbid saturated "ocamlcc_global_Stdlib__Int";
  let aliases = compile {|
    let min = Int.min
    let first = min
    let max = Stdlib.Int.max
    let clip lo hi x = max lo (first hi x)
  |} in
  require aliases "cslel";
  require aliases "csgel";
  forbid aliases "ocamlcc_apply2";
  let partial = compile "let f x = Int.min x" in
  require partial "ocamlcc_global_Stdlib__Int";
  let partial_alias = compile "let min = Int.min\nlet f x = min x" in
  require partial_alias "ocamlcc_apply1";
  forbid partial_alias "cslel";
  let shadowed = compile "module Int = struct let min a b = a + b end\nlet f a b = Int.min a b" in
  forbid shadowed "cslel";
  let stdlib_dir = Config.standard_library in
  let explicit = compile ~nostdlib:true ~include_dirs:[stdlib_dir] ~stdlib_dir saturated_source in
  forbid explicit "ocamlcc_global_Stdlib__Int";
  let disabled = compile ~nostdlib:true ~include_dirs:[stdlib_dir] saturated_source in
  require disabled "ocamlcc_global_Stdlib__Int";
  test_competing_interface ()
