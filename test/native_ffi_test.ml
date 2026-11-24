let compile ?(include_dirs = []) source =
  match Pipeline.compile_source
    { (Pipeline.Request.create ~filename:"native_ffi.ml" ~modname:"Native_ffi") with
      include_dirs; emit_entry = false } source with
  | Ok { Pipeline.Output.ssa = il; _ } -> il
  | Error error -> failwith error

let contains il pattern =
  try ignore (Str.search_forward (Str.regexp pattern) il 0); true
  with Not_found -> false

let () =
  let il = compile {|
    external f : float -> float = "test_boxed" "test_double" [@@unboxed] [@@noalloc]
    let twice x = f (f x)
  |} in
  assert (contains il "=d call extern \\$test_double(d ");
  assert (not (contains il "call extern \\$test_boxed("));
  let call = Str.search_forward (Str.regexp_string "call extern $test_double(") il 0 in
  let after_call = String.sub il call (String.length il - call) in
  assert (not (contains after_call "call extern \\$ocamlcc_get_exn("))

let () =
  let il = compile {|
    external f : (int [@untagged]) -> float -> (int64 [@unboxed])
      = "test_mixed_boxed" "test_mixed"
    let call i fval = try f i fval with _ -> 42L
  |} in
  let find symbol pos = Str.search_forward (Str.regexp_string ("call extern $" ^ symbol ^ "(")) il pos in
  let native = find "test_mixed" 0 in
  let check = find "ocamlcc_get_exn" native in
  let boxing = find "ocamlcc_alloc_custom" check in
  assert (native < check && check < boxing)

let () =
  let audited = compile {|
    external write : bytes -> unit = "test_raw_write" [@@noalloc] [@@ocamlcc.nosuspend]
    let write_and_keep bytes keep = write bytes; keep
  |} in
  let has_shadow il = contains il "call extern \\$arc_fiber_push" in
  assert (contains audited "call extern \\$test_raw_write(");
  if has_shadow audited then failwith "audited native call still has suspension roots";
  let unknown = compile {|
    external write : bytes -> unit = "test_raw_write" [@@noalloc]
    let write_and_keep bytes keep = write bytes; keep
  |} in
  assert (has_shadow unknown);
  let registered = compile {|
    external pause : unit -> unit = "test_suspend_bytecode" "ocamlcc_fiber_suspend"
      [@@noalloc] [@@ocamlcc.nosuspend]
    let pause_and_keep keep = pause (); keep
  |} in
  assert (has_shadow registered)

let () =
  let dir = Filename.temp_dir "ocamlcc-native-contract-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf dir) (fun () ->
    let filename = Filename.concat dir "ffi_contract.mli" in
    Sys_util.write_file filename {|
      external write : bytes -> unit = "test_bytecode_write" "test_native_write"
        [@@noalloc] [@@ocamlcc.nosuspend]
    |};
    let request = Pipeline.Request.create ~filename ~modname:"Ffi_contract" in
    (match Pipeline.compile_interface_file request with
     | Ok _ -> ()
     | Error error -> failwith error);
    let il = compile ~include_dirs:[dir] {|
      let write_and_keep bytes keep = Ffi_contract.write bytes; keep
    |} in
    assert (contains il "call extern \\$test_native_write(");
    assert (not (contains il "call extern \\$arc_fiber_push")))
