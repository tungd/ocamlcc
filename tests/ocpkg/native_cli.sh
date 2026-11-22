#!/bin/sh
set -eu
runner=$1
case "$runner" in /*) ;; *) runner="$PWD/$runner";; esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OCPKG_CACHE="$scratch/archives"
cd "$scratch"
"$runner" init fixture
test -f src/main.ml
"$runner" verify
"$runner" query cmdliner | grep -q '^pkg cmdliner 1\.3\.0$'
"$runner" env | grep -Fq "OCPKG_CACHE=$OCPKG_CACHE"
"$runner" tidy
"$runner" vendor --offline
before=$(cat ocpkg.lock)
"$runner" vendor --offline
test "$before" = "$(cat ocpkg.lock)"
if "$runner" init fixture > init.out 2> init.err; then
    exit 1
fi
grep -q 'ocpkg.mod already exists' init.err
printf '# new snapshot bytes\n' >> local.snap
printf 'module fixture\nsnapshot local.snap\n' > ocpkg.mod
if "$runner" verify > stale.out 2> stale.err; then
    exit 1
fi
test -s stale.err
echo 'native ocpkg dependency commands: PASS'
