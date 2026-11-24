open Ocpkg_format

let require = function Ok value -> value | Error msg -> failwith msg
let expect_error = function Error _ -> () | Ok _ -> failwith "expected an error"

let manifest = {|
# Editable description
module app
kind exe
entry "src/my main.ml"
source src
snapshot default
require (
  zed 1
  cmdliner 1.3.0
)
c_source glue.c
cflag "-DHELLO=\"a b\""
ldflag "-Wl,#example"
public_mli api.mli
single_thread_rc true
replace cmdliner => ../cmdliner
test main test/main.ml test
|}

let digest = String.make 64 '0'

let catalog =
  Printf.sprintf {|
schema 1

pkg zed 1
  dep cmdliner
  local ports/zed
  tree %s
  wrapped Zed
  export Zed
  file util.ml <= src/util.ml

pkg cmdliner 1.3.0
  url https://example.com/cmdliner.tar.gz
  sha256 %s
  root cmdliner-1.3.0
  tree %s
  wrapped false
  license ISC
  export Cmdliner
  file cmdliner.ml <= src/cmdliner.ml
|} digest digest digest

let () =
  let modfile = require (parse_manifest manifest) in
  let canonical = print_manifest modfile in
  assert (canonical = print_manifest (require (parse_manifest canonical)));
  assert (List.map (fun (item : requirement) -> Package_name.to_string item.name)
            modfile.requirements = ["cmdliner"; "zed"]);
  assert (modfile.cflags = ["-DHELLO=\"a b\""]);
  assert (modfile.ldflags = ["-Wl,#example"]);
  expect_error (parse_manifest "module app\nsource ../outside\n");
  expect_error (parse_manifest "module app\nentry a.ml\nentry b.ml\n");
  expect_error (parse_manifest "module app\nrequire (\n  zed 1\n");
  let packages = require (parse_snapshot catalog) in
  let text = print_snapshot packages in
  assert (text = print_snapshot (require (parse_snapshot text)));
  let lock = { catalog = require (Rel_path.of_string "default");
               digest = require (Sha256.of_hex digest); packages } in
  let lock_text = print_lock lock in
  assert (lock_text = print_lock (require (parse_lock lock_text)));
  expect_error (parse_snapshot (catalog ^ "\npkg zed 2\n  local other\n  tree " ^ digest));
  let invalid_paths = ["../other.ml"; "/tmp/other.ml"; "src\\other.ml"; "a\nother.ml"] in
  List.iter (fun path -> expect_error (Rel_path.of_string path)) invalid_paths;
  expect_error (Comp_input.create ~name:"bin/main.ml" ~source:"other.ml");
  expect_error (Comp_input.create ~name:"main.cs" ~source:"other.ml");
  expect_error (Package_name.of_string "org/app")

let () =
  if Array.length Sys.argv = 2 then begin
    let catalog = In_channel.with_open_bin Sys.argv.(1) In_channel.input_all in
    let packages = require (parse_snapshot catalog) in
    let names = List.map (fun package -> Package_name.to_string package.package.name) packages in
    assert (names = ["arc-unix"; "astring"; "base64"; "bytesrw"; "cmdliner"; "crunch"; "crunch-unix";
                     "fmt"; "jsonm"; "jsont"; "logs"; "ptime"; "re"; "tyxml"; "uutf"])
  end
