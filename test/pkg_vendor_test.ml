open Ocpkg_format

let require = function Ok value -> value | Error msg -> failwith msg
let containing text needle =
  let rec at i =
    i + String.length needle <= String.length text
    && (String.sub text i (String.length needle) = needle || at (i + 1))
  in
  at 0

let reject needle = function
  | Ok _ -> failwith ("expected rejection containing " ^ needle)
  | Error msg when containing msg needle -> ()
  | Error msg -> failwith (Printf.sprintf "expected %s, got %s" needle msg)

let name value = Package_name.of_string value |> require
let rel value = Rel_path.of_string value |> require
let never_fetch ~url:_ ~destination:_ = failwith "unexpected network request"

let specimen name_ tree =
  { package = {name = name name_; version = "1"};
    dependencies = []; source = Local (rel "source"); tree; wrapping = Flat;
    files = [require (Comp_input.create ~name:"main.ml" ~source:"main.ml")];
    exports = []; executable = None; license = None; cflags = []; ldflags = [] }

let archive_file path members =
  let make_header (path, kind, body, size) =
    let block = Bytes.make 512 '\000' in
    let put i str = Bytes.blit_string str 0 block i (String.length str) in
    put 0 path;
    put 100 "0000644\000";
    put 124 (Printf.sprintf "%011o" size);
    put 148 "        ";
    Bytes.set block 156 kind;
    put 257 "ustar\00000";
    let sum = Bytes.fold_left (fun sum byte -> sum + Char.code byte) 0 block in
    put 148 (Printf.sprintf "%06o\000 " sum);
    let pad = (512 - String.length body mod 512) mod 512 in
    Bytes.to_string block ^ body ^ String.make pad '\000'
  in
  Sys_util.write_file path (String.concat "" (List.map make_header members) ^ String.make 1024 '\000')

let member path contents = (path, '0', contents, String.length contents)

let with_directory f =
  let root = Filename.temp_dir "ocpkg-test-" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf root) (fun () -> f root)

let test label f =
  with_directory f;
  Printf.printf "PASS %s\n%!" label

let () =
  let tree = Sha256.string "unused" in
  test "topological dependency closure" (fun _ ->
    let lib = specimen "lib" tree in
    let app = {(specimen "app" tree) with dependencies = [name "lib"]} in
    let resolved = require (Pkg_vendor.resolve ~catalog:[app; lib] [app.package]) in
    assert (List.map (fun recipe -> recipe.package.name) resolved = [name "lib"; name "app"]);
    let lib = {lib with dependencies = [name "app"]} in
    reject "dependency cycle" (Pkg_vendor.resolve ~catalog:[app; lib] [app.package]);
    reject "missing package" (Pkg_vendor.resolve ~catalog:[app] [app.package]);
    reject "duplicate package" (Pkg_vendor.resolve ~catalog:[app; app] [app.package]));
  test "offline lock survives catalog revisions" (fun root ->
    let source = Filename.concat root "source" in
    Unix.mkdir source 0o755;
    Sys_util.write_file (Filename.concat source "main.ml") "let () = ()\n";
    let app = specimen "app" (Sha256.tree_hash source |> require) in
    let manifest =
      { (project (name "demo")) with snapshot = rel "test.snap"; requirements = [app.package] }
    in
    let workspace : Pkg_project.t = {root; manifest} in
    let snapshot = Filename.concat root "test.snap" in
    Sys_util.write_file snapshot (print_snapshot [app]);
    let catalog = Pkg_project.catalog workspace |> require in
    let lock = Pkg_project.make_lock workspace catalog |> require in
    let other = {app with package = {app.package with version = "2"}} in
    Pkg_project.write_lock workspace lock |> require;
    let contents = Sys_util.read_file (Filename.concat root "ocpkg.lock") in
    assert (contents = print_lock (Pkg_project.read_lock workspace |> require));
    Pkg_project.write_lock workspace {lock with packages = [other]} |> require;
    reject "pinned at 2" (Pkg_project.read_lock workspace);
    Pkg_project.write_lock workspace lock |> require;
    Sys_util.write_file snapshot ((print_snapshot [app]) ^ "\n");
    assert (contents = print_lock (Pkg_project.read_lock workspace |> require));
    Sys.remove snapshot;
    assert (contents = print_lock (Pkg_project.read_lock workspace |> require)));
  test "vendored edits, extra files and changed local recipe" (fun root ->
    let source = Filename.concat root "source" in
    Unix.mkdir source 0o755;
    let original = Filename.concat source "main.ml" in
    Sys_util.write_file original "let () = ()\n";
    let recipe = specimen "demo" (Sha256.tree_hash source |> require) in
    let vendor = Filename.concat root "vendor" in
    let cache = Filename.concat root "archives" in
    let acquire () =
      Pkg_vendor.vendor ~fetch:never_fetch ~offline:true ~cache ~vendor
        ~project_root:root ~catalog_root:root [recipe] in
    acquire () |> require;
    let edited = Filename.concat vendor "demo/main.ml" in
    Sys_util.write_file edited "local edit";
    reject "refusing to overwrite" (acquire ());
    assert (Sys_util.read_file edited = "local edit");
    Sys_util.write_file edited (Sys_util.read_file original);
    Sys_util.write_file (Filename.concat vendor "demo/extra.ml") "";
    reject "vendored source changed" (Pkg_vendor.verify ~vendor [recipe]);
    Sys_util.write_file original "changed local recipe";
    reject "local recipe source changed"
      (Pkg_vendor.pin ~project_root:root ~catalog_root:root ~replacements:[] [recipe]));
  test "archive entry safety" (fun root ->
    let archive = Filename.concat root "payload.tar" in
    let dest = Filename.concat root "unpack" in
    Unix.mkdir dest 0o700;
    let check needle members =
      archive_file archive members;
      reject needle (Pkg_archive.unpack ~archive ~root:(rel "pkg") ~into:dest);
      assert (Array.length (Sys.readdir dest) = 0)
    in
    check "relative path" [member "pkg/../../escape" "bad"];
    check "relative path" [member "/absolute" "bad"];
    check "unexpected archive root" [member "other/main.ml" ""];
    check "unsupported archive entry" ["pkg/link", '2', "", 0];
    check "unsupported archive entry" ["pkg/hard", '1', "", 0];
    check "unsupported archive entry" ["pkg/device", '4', "", 0];
    check "duplicate archive entry" [member "pkg/name" "a"; member "pkg/./name" "b"];
    check "tar parent is a file" [member "pkg/item" ""; member "pkg/item/child" ""];
    check "256 MiB" ["pkg/large", '0', "", 256 * 1024 * 1024 + 1];
    assert (not (Sys.file_exists (Filename.concat root "escape"))));
  test "digest mismatch, file cap and offline cache miss" (fun root ->
    let archive = { url = "https://example.test/pkg.tar"; digest = tree; root = rel "pkg" } in
    let cache = Filename.concat root "archives" in
    let cached = Filename.concat cache (Sha256.to_hex tree) in
    let cached_archive ~offline ~fetch =
      Pkg_vendor.archive ~cache ~offline ~fetch archive
    in
    reject "offline cache" (cached_archive ~offline:true ~fetch:never_fetch);
    let wrong ~url:_ ~destination = Sys_util.write_file destination "wrong bytes"; Ok () in
    reject "digest mismatch" (cached_archive ~offline:false ~fetch:wrong);
    assert (Array.length (Sys.readdir cache) = 0);
    let too_big ~url:_ ~destination =
      Unix.truncate destination (64 * 1024 * 1024 + 1);
      Ok ()
    in
    reject "64 MiB" (cached_archive ~offline:false ~fetch:too_big);
    assert (Array.length (Sys.readdir cache) = 0);
    Sys_util.write_file cached "wrong bytes";
    reject "digest mismatch" (cached_archive ~offline:true ~fetch:never_fetch);
    reject "require HTTPS"
      (Pkg_vendor.archive ~cache ~offline:false ~fetch:never_fetch
         {archive with digest = Sha256.string "other"; url = "http://example.test/x"}));
  test "verified offline archive round trip" (fun root ->
    let source = Filename.concat root "reference" in
    Unix.mkdir source 0o755;
    let contents = "let x = 1\n" in
    Sys_util.write_file (Filename.concat source "main.ml") contents;
    let archive = Filename.concat root "payload.tar" in
    archive_file archive [member "pkg/main.ml" contents];
    let digest = Sha256.file archive |> require in
    let cache = Filename.concat root "archives" in
    Unix.mkdir cache 0o755;
    Sys_util.write_file (Filename.concat cache (Sha256.to_hex digest)) (Sys_util.read_file archive);
    let tree = Sha256.tree_hash source |> require in
    let recipe = {(specimen "app" tree) with
      source = Archive { url = "https://example.test/archive"; digest; root = rel "pkg" }} in
    let vendor = Filename.concat root "vendor" in
    Pkg_vendor.vendor ~cache ~vendor ~project_root:root ~catalog_root:root
      ~offline:true ~fetch:never_fetch [recipe] |> require;
    Pkg_vendor.verify ~vendor [recipe] |> require)

let () =
  test "vendor root symlinks are refused" (fun root ->
    let outside = Filename.concat root "elsewhere" in
    Unix.mkdir outside 0o750;
    let vendor = Filename.concat root "vendor" in
    Unix.symlink outside vendor;
    let cache = Filename.concat root "archives" in
    reject "vendor must be a directory"
      (Pkg_vendor.vendor ~cache ~vendor ~project_root:root ~catalog_root:root
         ~offline:true ~fetch:never_fetch []);
    assert (Array.length (Sys.readdir outside) = 0))
