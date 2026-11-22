let require = function Ok value -> value | Error msg -> failwith msg

let () =
  let root = Filename.temp_dir "ocpkg-cache-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf root) (fun () ->
    let cache = Filename.concat root "cache" in
    let toolchain = Filename.concat root "toolchain" in
    let input = Filename.concat root "runtime" in
    Sys_util.write_file toolchain "compiler";
    Sys_util.write_file input "runtime";
    let key () =
      Build_cache.fingerprints [toolchain; input] |> require |> Build_cache.key
    in
    let builds = ref 0 in
    let build destination =
      incr builds;
      Sys_util.write_file (Filename.concat destination "unit.o") "object";
      Ok ()
    in
    let ensure () = Build_cache.ensure ~store:cache ~key:(key ()) build |> require in
    let first = ensure () in
    assert (not first.hit && !builds = 1);
    assert ((ensure ()).hit && !builds = 1);
    Sys_util.write_file input "edited runtime";
    let runtime_change = ensure () in
    assert (not runtime_change.hit && !builds = 2);
    Sys_util.write_file (Filename.concat runtime_change.directory "unit.o") "tampered object";
    assert (not (ensure ()).hit && !builds = 3);
    assert ((ensure ()).hit && !builds = 3);
    let broken = Build_cache.key ["broken", "1"] in
    let interrupted path =
      Sys_util.write_file (Filename.concat path "partial.o") "partial";
      Error "simulated compiler failure"
    in
    assert (Result.is_error (Build_cache.ensure ~store:cache ~key:broken interrupted));
    assert (not (Build_cache.ensure ~store:cache ~key:broken build |> require).hit))

let () =
  let root = Filename.temp_dir "ocpkg-stat-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf root) (fun () ->
    let input = Filename.concat root "source" in
    Sys_util.write_file input "original";
    let stat = Unix.stat input in
    let digest ~verify =
      Digest_index.with_index ~cache:root ~workspace:root ~verify
        (fun index -> Digest_index.file index input |> require)
    in
    let original = digest ~verify:false in
    assert (Sha256.equal original (digest ~verify:false));
    Sys_util.write_file input "modified";
    Unix.utimes input stat.st_atime stat.st_mtime;
    let modified = digest ~verify:false in
    assert (not (Sha256.equal original modified));
    assert (Sha256.equal modified (digest ~verify:true)))
