#!/bin/sh
set -eu
runner=$1
case "$runner" in /*) ;; *) runner="$PWD/$runner";; esac
if [ "$#" -gt 1 ]; then
    OCAMLCC_QBE=$2
    case "$OCAMLCC_QBE" in /*) ;; *) OCAMLCC_QBE="$PWD/$OCAMLCC_QBE";; esac
    export OCAMLCC_QBE
fi
scratch=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
export OCPKG_CACHE="$scratch/cache"
export TERM=dumb
cd "$scratch"
mkdir -p src

cat > ocpkg.mod <<'MOD'
module mode-demo
kind exe
entry src/main.ml
source src
c_source src/cval.c
MOD

cat > src/cval.c <<'C'
#include <stdint.h>
int64_t c_mode_val(int64_t u) {
    (void)u;
#ifdef __OPTIMIZE__
    return (1L << 1) | 1L;
#else
    return (0L << 1) | 1L;
#endif
}
C

cat > src/main.ml <<'ML'
external c_mode_val : unit -> int = "c_mode_val"
let[@inline] f x = x + 41
let () = Printf.printf "opt=%d v=%d\n" (c_mode_val ()) (f 1)
ML

"$runner" tidy

# 1. Default build is Release (-O2 -> __OPTIMIZE__ defined -> opt=1)
"$runner" build -o app_rel > out.txt
test "$(cat out.txt)" = "$scratch/app_rel"
test "$(./app_rel)" = "opt=1 v=42"

# 2. Explicit --release hits cached OCaml unit from default build (C unit recompiles)
"$runner" build --release -v -o app_rel2 2> err_rel2.txt
test "$(./app_rel2)" = "opt=1 v=42"
grep -q "1 fresh units, 1 cached units" err_rel2.txt

# 3. Debug build (-O0 -g -> __OPTIMIZE__ undefined -> opt=0), separate cache entry
"$runner" build --debug -v -o app_dbg 2> err_dbg.txt
test "$(./app_dbg)" = "opt=0 v=42"
grep -q "2 fresh units, 0 cached units" err_dbg.txt
test -d "$OCPKG_CACHE/stdlib"
test -d "$OCPKG_CACHE/runtime"

# 4. Warm Debug build hits Debug cache; Release still hits Release cache
"$runner" build --debug -v -o app_dbg2 2> err_dbg2.txt
test "$(./app_dbg2)" = "opt=0 v=42"
grep -q "1 fresh units, 1 cached units" err_dbg2.txt
"$runner" build -v -o app_rel3 2> err_rel3.txt
test "$(./app_rel3)" = "opt=1 v=42"
grep -q "1 fresh units, 1 cached units" err_rel3.txt

# 5. clean --global removes shared occ/ocpkg cache stores cleanly
"$runner" clean --global
test ! -d "$OCPKG_CACHE/pkg"
test ! -d "$OCPKG_CACHE/stdlib"
test ! -d "$OCPKG_CACHE/runtime"
test ! -d "$OCPKG_CACHE/occ-unit"

echo "ocpkg debug/release mode and shared cache: PASS"
