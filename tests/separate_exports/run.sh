#!/bin/sh
set -eu
compiler=build/bin/occ
stdlib=build/stdlib
src=tests/separate_exports
work=build/separate_exports_test
mkdir -p "$work/units" "$work/replacement"

# The module name comes from its interface even if the object was renamed.
"$compiler" build -c --stdlib-dir "$stdlib" "$src/provider.mli" "$src/provider.ml" \
    -o "$work/units/implementation.o"
test -f "$work/units/provider.cmi"
test -f "$work/units/provider.exports"
"$compiler" build -c --stdlib-dir "$stdlib" -I "$work/units" --work-dir "$work/consumer" \
    "$src/consumer.ml" -o "$work/units/consumer.o"
grep -Eq 'call extern \$ocamlcc_Provider_add__' "$work/consumer/consumer.ssa"
exception_checks() {
    awk '/function l \$ocamlcc_Consumer_calculate__/,/^}/' "$1" |
        awk '/call extern \$ocamlcc_get_exn\(/ { n++ } END { print n + 0 }'
}
test "$(exception_checks "$work/consumer/consumer.ssa")" -eq 1
"$compiler" build --stdlib-dir "$stdlib" -I "$work/units" "$src/entry.ml" \
    "$work/units/consumer.o" "$work/units/implementation.o" -o "$work/run"
"$work/run"

mkdir -p "$work/legacy"
cp "$work/units/implementation.o" "$work/units/provider.cmi" "$work/legacy"
awk '
    NR == 1 { sub(/exports-v[0-9]+/, "exports-v1") }
    NR > 2 && NF { $6 = ($6 == "suspend=no" ? "false" : "true"); NF = 7 }
    { print }
' \
    "$work/units/provider.exports" > "$work/legacy/provider.exports"
"$compiler" build -c --stdlib-dir "$stdlib" -I "$work/legacy" --work-dir "$work/legacy-work" \
    "$src/consumer.ml" -o "$work/legacy/consumer.o"
grep -Eq 'call extern \$ocamlcc_Provider_add__' "$work/legacy-work/consumer.ssa"
test "$(exception_checks "$work/legacy-work/consumer.ssa")" -eq 2

sed 's/x + !bias/x + !bias + 1/' "$src/provider.ml" > "$work/replacement/provider.ml"
cp "$src/provider.mli" "$work/replacement/provider.mli"
"$compiler" build -c --stdlib-dir "$stdlib" "$work/replacement/provider.mli" \
    "$work/replacement/provider.ml" -o "$work/replacement/implementation.o"
"$compiler" build -c --stdlib-dir "$stdlib" -I "$work/units" -I "$work/replacement" \
    --work-dir "$work/shadow" "$src/consumer.ml" -o "$work/shadow.o"
grep -Eq 'call extern \$ocamlcc_Provider_add__' "$work/shadow/consumer.ssa"
sed 's/= 42/= 43/' "$src/entry.ml" > "$work/entry.ml"
"$compiler" build --stdlib-dir "$stdlib" -I "$work" -I "$work/replacement" "$work/entry.ml" \
    "$work/shadow.o" "$work/replacement/implementation.o" -o "$work/run"
"$work/run"
cp "$work/replacement/implementation.o" "$work/units/implementation.o"

# A precompiled consumer requires the exact implementation used for its direct call.
if "$compiler" build --stdlib-dir "$stdlib" -I "$work/units" "$src/entry.ml" \
    "$work/units/consumer.o" "$work/units/implementation.o" -o "$work/relinked" \
    > "$work/relink.log" 2>&1; then
    exit 1
fi
grep -q 'ocamlcc_Provider_add__' "$work/relink.log"

# New compilations can fall back to closure application with the replacement.
"$compiler" build -c --stdlib-dir "$stdlib" -I "$work/units" --work-dir "$work/fallback" \
    "$src/consumer.ml" -o "$work/units/consumer.o"
grep -Fq 'call extern $ocamlcc_apply1_raw(' "$work/fallback/consumer.ssa"
"$compiler" build --stdlib-dir "$stdlib" -I "$work/units" "$work/entry.ml" \
    "$work/units/consumer.o" "$work/units/implementation.o" -o "$work/run"
"$work/run"
echo 'separate export summaries: PASS'
