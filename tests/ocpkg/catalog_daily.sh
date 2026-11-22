#!/bin/sh
set -eu
runner=$1
case "$runner" in /*) ;; *) runner="$PWD/$runner";; esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OCPKG_CACHE="${OCPKG_CACHE:-$scratch/cache}"
cd "$scratch"
"$runner" init daily
"$runner" add astring base64 bytesrw fmt jsonm logs re uutf
"$runner" vendor --offline
"$runner" verify
cat > src/check.ml <<'ML'
let run () =
  assert (Astring.String.trim " a " = "a");
  assert (Base64.decode_exn (Base64.encode_string "hello") = "hello");
  assert (Bytesrw.Bytes.Reader.to_string (Bytesrw.Bytes.Reader.of_string "bytes") = "bytes");
  assert (Fmt.str "%02d" 3 = "03");
  let decoder = Jsonm.decoder (`String "[1]") in
  assert (Jsonm.decode decoder = `Lexeme `As);
  assert (Jsonm.decode decoder = `Lexeme (`Float 1.));
  Logs.set_level (Some Logs.Info);
  assert (Logs.level () = Some Logs.Info);
  assert (Re.execp (Re.Perl.compile_pat "ab+c") "xxabbbc");
  let count = Uutf.String.fold_utf_8 (fun count _ _ -> count + 1) 0 "aé" in
  assert (count = 2)
ML
cat > src/main.ml <<'ML'
let () = Check.run (); print_endline "daily catalog: PASS"
ML
mkdir -p test
cat > test/core.ml <<'ML'
let () = Check.run ()
ML
printf '\ntest core test/core.ml test\n' >> ocpkg.mod
"$runner" build
"$runner" run | grep -Fx 'daily catalog: PASS'
"$runner" test | grep -Fx '1 passed, 0 failed (1 tests)'
