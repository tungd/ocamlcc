#!/bin/sh
set -eu

runner=$1
source=$2
case "$runner" in /*) ;; *) runner="$PWD/$runner";; esac
case "$source" in /*) ;; *) source="$PWD/$source";; esac
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OCPKG_CACHE="$scratch/cache"
cd "$scratch"
mkdir src
cp "$here/zarith_public.ml" src/main.ml
cat >> src/main.ml <<'ML'

external live_objects : unit -> int = "ocamlcc_arc_live"

let exercise () =
  let a = wide () in
  let b = Z.succ a in
  assert (Z.equal (Z.sub b a) Z.one);
  let quotient, remainder = Z.div_rem b (Z.of_int 3) in
  assert (Z.sign quotient = 1 && Z.equal remainder (Z.of_int 2));
  assert (match Z.to_int b with exception Z.Overflow -> true | _ -> false)

let () =
  exercise ();
  let before = live_objects () in
  for _ = 1 to 1000 do exercise () done;
  let after = live_objects () in
  if before <> after then
    failwith (Printf.sprintf "Zarith live objects changed from %d to %d" before after);
  print_endline "Zarith temporary ARC allocations: PASS"
ML

cat > ocpkg.mod <<'OCPKG'
module zarith-test
kind exe
entry src/main.ml
source src
snapshot fixture.snap
require (
  zarith 1.14
)
OCPKG

printf 'schema 1\n' > fixture.snap
python3 "$here/../../tools/stage-zarith.py" "$source" upstream >> fixture.snap

"$runner" tidy
"$runner" vendor --offline
cmp "$source/caml_z.c" vendor/zarith/caml_z.c
cmp "$source/z.ml" vendor/zarith/z.ml
"$runner" run
"$runner" run --single-thread-rc
