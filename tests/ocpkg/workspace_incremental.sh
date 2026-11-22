#!/bin/sh
set -eu
runner=$1
case "$runner" in /*) ;; *) runner="$PWD/$runner";; esac
if [ "$#" -gt 1 ]; then
    OCAMLCC_QBE=$2
    case "$OCAMLCC_QBE" in /*) ;; *) OCAMLCC_QBE="$PWD/$OCAMLCC_QBE";; esac
    export OCAMLCC_QBE
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OCPKG_CACHE="$scratch/cache"
project="$scratch/project space"
mkdir -p "$project/src" "$project/test"
cd "$project"
cat > ocpkg.mod <<'MOD'
module fixture
kind exe
entry src/main.ml
source src
snapshot fixture.snap
test checks test/checks.ml test
MOD
echo 'schema 1' > fixture.snap
cat > src/answer.mli <<'MLI'
val answer : int
MLI
cat > src/answer.ml <<'ML'
let answer = 41
ML
cat > src/main.ml <<'ML'
let () = Printf.printf "%d\n" (Answer.answer + 1)
ML
cat > test/checks.ml <<'ML'
let () = assert (Answer.answer = 41); assert (Sys.argv.(1) = "--forwarded"); print_endline "test passed"
ML
"$runner" tidy
"$runner" vendor --offline
"$runner" build -v -o 'app output' > first.out 2> first.log || { cat first.log >&2; exit 1; }
test "$(grep -c '^compile ' first.log)" -eq 3
test "$("./app output")" = 42
"$runner" build -v -o 'app output' > repeat.out 2> repeat.log || { cat repeat.log >&2; exit 1; }
test "$(grep -c '^compile ' repeat.log || :)" -eq 0
if grep -q '^+ ' repeat.log; then
    cat repeat.log >&2
    exit 1
fi
chmod a-x 'app output'
"$runner" build -o 'app output'
test "$("./app output")" = 42
if "$runner" build --shared --static > ambiguous.out 2> ambiguous.log; then
    exit 1
fi
grep -q 'conflicting output modes' ambiguous.log
cat > src/main.ml <<'ML'
let () = Printf.printf "%d\n" (Answer.answer + 2)
ML
"$runner" build -v -o 'app output' > changed.out 2> changed.log || { cat changed.log >&2; exit 1; }
test "$(grep -c '^compile ' changed.log)" -eq 1
grep -q 'src/main.ml$' changed.log
test "$("./app output")" = 43
test "$("$runner" run)" = 43
"$runner" test checks -- --forwarded > checks.out
grep -Fx 'test passed' checks.out
grep -Fx 'PASS checks' checks.out
grep -Fx '1 passed, 0 failed (1 tests)' checks.out
mkdir -p native/include
cat > native/value.c <<'C'
#include <stdint.h>
#include "include/value.h"
int64_t native_value(int64_t unit) {
    (void)unit;
    return VALUE * 2 + 1;
}
C
printf '#define VALUE 42\n' > native/include/value.h
printf 'c_source native/value.c\n' >> ocpkg.mod
cat > src/main.ml <<'ML'
external value : unit -> int = "native_value"
let () = print_int (value ())
ML
test "$("$runner" run)" = 42
printf '#define VALUE 43\n' > native/include/value.h
test "$("$runner" run)" = 43
echo 'workspace incremental compilation: PASS'
