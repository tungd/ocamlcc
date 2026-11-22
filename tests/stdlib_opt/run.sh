#!/bin/sh
set -eu
compiler=build/bin/occ
stdlib=build/stdlib
main=tests/stdlib_opt/main.ml
work=build/stdlib_opt_test
mkdir -p "$work"

"$compiler" compile --nostdlib -I "$stdlib" --stdlib-dir "$stdlib" "$main" -o "$work/with-opt.ssa"
grep -Eq 'call extern \$ocamlcc_(direct_)?Stdlib__option_' "$work/with-opt.ssa"
grep -Eq 'call extern \$ocamlcc_(direct_)?Stdlib__result_' "$work/with-opt.ssa"
grep -Eq 'call extern \$ocamlcc_(direct_)?Stdlib__list_' "$work/with-opt.ssa"

# Exercise loading without loose object files.
pack="$work/pack"
mkdir -p "$pack"
cp "$stdlib/"*.cmi "$stdlib/libocamlstdlib.a" "$stdlib/libocamlstdlib.a.opt" "$pack"
"$compiler" build --work-dir "$work/driver" --stdlib-dir "$pack" "$main" -o "$work/run"
grep -Eq 'call extern \$ocamlcc_(direct_)?Stdlib__option_' "$work/driver/main.ssa"
"$work/run"

"$compiler" build -c --work-dir "$work/object" --stdlib-dir "$pack" "$main" -o "$work/main.o"
grep -Eq 'call extern \$ocamlcc_(direct_)?Stdlib__option_' "$work/object/main.ssa"

# Loose object packs can use their per-unit summaries without an archive.
loose="$work/loose"
mkdir -p "$loose"
cp "$stdlib/"*.cmi "$stdlib/"*.o "$stdlib/"*.exports "$loose"
"$compiler" build --work-dir "$work/loose-build" --stdlib-dir "$loose" "$main" -o "$work/run"
grep -Eq 'call extern \$ocamlcc_(direct_)?Stdlib__option_' "$work/loose-build/main.ssa"
"$work/run"

# Old packs can be linked without optimization metadata.
rm "$pack/libocamlstdlib.a.opt"
"$compiler" build --work-dir "$work/fallback" --stdlib-dir "$pack" "$main" -o "$work/run"
if grep -Eq 'call extern \$ocamlcc_(direct_)?Stdlib__option_' "$work/fallback/main.ssa"; then
    exit 1
fi
"$work/run"

# Other units still benefit when one CMI no longer matches.
cp "$stdlib/libocamlstdlib.a.opt" "$pack"
printf '\n' >> "$pack/stdlib__option.cmi"
"$compiler" compile --nostdlib --stdlib-dir "$pack" "$main" -o "$work/stale-cmi.ssa"
if grep -Eq 'call extern \$ocamlcc_(direct_)?Stdlib__option_' "$work/stale-cmi.ssa"; then
    exit 1
fi
grep -Eq 'call extern \$ocamlcc_(direct_)?Stdlib__result_' "$work/stale-cmi.ssa"

# A valid summary for a different archive must be ignored.
cp "$stdlib/libocamlstdlib.a.opt" "$pack"
printf '\n' >> "$pack/libocamlstdlib.a"
"$compiler" compile --nostdlib -I "$pack" --stdlib-dir "$pack" "$main" -o "$work/stale.ssa"
if grep -Eq 'call extern \$ocamlcc_(direct_)?Stdlib__option_' "$work/stale.ssa"; then
    exit 1
fi
echo 'stdlib export summaries: PASS'
