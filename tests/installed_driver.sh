#!/bin/sh
# Exercise the public executable without checkout-relative tool discovery.
set -eu
driver=$1
shift
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unset OCAMLCC_QBE OCAMLCC_RUNTIME_DIR OCAMLCC_STDLIB_DIR
cd "$work"
if [ "$#" -eq 0 ]; then
    cat > registry.ml <<'ML'
let entries : (string * int) list ref = ref []
let register key value = entries := (key, value) :: !entries
let lookup key = List.assoc key !entries
ML
else
    cat > registry.ml <<'ML'
module Entries = Map.Make(String)
let entries : int Entries.t ref = ref Entries.empty
let register key value = entries := Entries.add key value !entries
let lookup key = Entries.find key !entries
ML
fi
cat > plugin.ml <<'ML'
let () = Registry.register "answer" 42
ML
cat > main.ml <<'ML'
let () = print_endline (string_of_int (Registry.lookup "answer"))
ML
"$driver" build "$@" registry.ml plugin.ml main.ml -o app
./app > actual
printf '42\n' > expected
diff -u expected actual
