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
test -z "$("$runner" query)"
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

mkdir first second upgraded
printf 'let value = 1\n' > first/data.ml
printf 'let value = 2\n' > second/data.ml
printf 'let value = 3\n' > upgraded/data.ml
cat > local.snap <<'SNAP'
schema 1
pkg first 1
  local first
  tree 4ee035a4450787b68d3cc16e298a0e59412249fdc5a577414ded234e2e07cfd2
  file first.ml <= data.ml
pkg second 1
  local second
  tree 72859cc75b424c92322047a98a2d794aecf09c5df608c6bdfa33f39047330a29
  file second.ml <= data.ml
SNAP
"$runner" tidy
"$runner" add first first@1 second@1
test "$("$runner" query)" = "$(printf 'first 1\nsecond 1')"
test "$("$runner" test)" = '0 passed, 0 failed (0 tests)'
"$runner" version | grep -Eq '^ocpkg [0-9]'
sed -e 's/pkg first 1/pkg first 2/' -e 's/local first/local upgraded/' \
    -e 's/4ee035a4450787b68d3cc16e298a0e59412249fdc5a577414ded234e2e07cfd2/7469e6bcefa82be6f6632e00f9b30099fc6fdf60eaeb5645cb3457db4ebef0c8/' \
    local.snap > newer.snap
mv newer.snap local.snap
"$runner" verify
printf 'local work\n' > vendor/first/data.ml
if "$runner" upgrade first > upgrade.out 2> upgrade.err; then exit 1; fi
grep -q 'refusing to overwrite changed vendor' upgrade.err
test "$(cat vendor/first/data.ml)" = 'local work'
cp first/data.ml vendor/first/data.ml
"$runner" upgrade first
test "$(cat vendor/first/data.ml)" = 'let value = 3'
test "$("$runner" query)" = "$(printf 'first 2\nsecond 1')"
# A same-version recipe refresh must keep a previously vendored project usable.
sed -e 's/local upgraded/local first/' \
    -e 's/7469e6bcefa82be6f6632e00f9b30099fc6fdf60eaeb5645cb3457db4ebef0c8/4ee035a4450787b68d3cc16e298a0e59412249fdc5a577414ded234e2e07cfd2/' \
    local.snap > newer.snap
mv newer.snap local.snap
"$runner" tidy
"$runner" verify
test "$(cat vendor/first/data.ml)" = 'let value = 1'
rm -r vendor/second
"$runner" remove first
test ! -e vendor/first
test ! -e vendor/second
test "$("$runner" query)" = 'second 1'
"$runner" vendor --offline
mkdir -p .ocpkg/cache .ocpkg/bin "$OCPKG_CACHE/pkg"
"$runner" clean
"$runner" clean --global
test ! -e .ocpkg/cache
test ! -e .ocpkg/bin
test ! -e "$OCPKG_CACHE/pkg"
test -f ocpkg.lock
test -f vendor/second/data.ml
echo 'native ocpkg dependency lifecycle: PASS'
