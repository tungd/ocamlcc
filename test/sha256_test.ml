let expect_digest label expected actual =
  let digest = Sha256.to_hex actual in
  if digest <> expected then
    failwith (Printf.sprintf "%s: expected %s, got %s" label expected digest)

let require = function Ok value -> value | Error msg -> failwith msg
let expect_error = function Error _ -> () | Ok _ -> failwith "expected an error"

let () =
  [
    "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    String.make 56 'a', "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a";
    String.make 1_000_000 'a', "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0";
  ]
  |> List.iter (fun (text, expected) -> expect_digest "string" expected (Sha256.string text));
  expect_error (Sha256.of_hex (String.make 64 'G'));
  expect_error (Sha256.of_hex "a");
  let fixture = Filename.temp_dir "ocpkg_digest_" "" in
  Fun.protect ~finally:(fun () -> Sys_util.rm_rf fixture) (fun () ->
    let file = Filename.concat fixture "binary" in
    Sys_util.write_file file (String.init (256 * 1024) (fun n -> Char.chr (n mod 256)));
    expect_digest "streamed file" "2312394bd99545d9de131c24efb781e765ac1aec243f2ed9347597a793a415e9"
      (require (Sha256.file file));
    Sys.remove file;
    Sys_util.mkdir_p (Filename.concat fixture "a");
    Sys_util.write_file (Filename.concat fixture "a/é.ml") "a\000b\n";
    let executable = Filename.concat fixture "a-x" in
    Sys_util.write_file executable "hello\n";
    Unix.chmod executable 0o755;
    Sys_util.write_file (Filename.concat fixture "z \"quoted\"") "";
    let original = require (Sha256.tree_hash fixture) in
    expect_digest "Python-compatible tree" "f0894c7bcb5537cb42de14068bb69e3965c78a244aaf6ae72761435e46d9cfac" original;
    Unix.chmod executable 0o644;
    let changed = require (Sha256.tree_hash fixture) in
    assert (not (Sha256.equal original changed));
    Unix.symlink executable (Filename.concat fixture "link");
    expect_error (Sha256.tree_hash fixture))
