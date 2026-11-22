#!/bin/sh
set -eu
compiler=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/main.ml" <<'ML'
module Table = Map.Make (Int)
let () = Printf.printf "%d\n" (Table.find 1 (Table.singleton 1 42))
ML
check() {
    "$compiler" build "$@" "$work/main.ml" -o "$work/app"
    test "$("$work/app")" = 42
}
check
check --cc cc
echo 'default stdlib: PASS'
