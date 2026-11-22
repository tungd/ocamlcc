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
cd "$scratch"
mkdir src
cat > ocpkg.mod <<'MOD'
module counter
kind shared
source src
snapshot fixture.snap
public_mli src/counter.mli
MOD
echo 'schema 1' > fixture.snap
printf 'val inc : int -> int\n' > src/counter.mli
printf 'let inc n = n + 1\n' > src/counter.ml
cat > host.c <<'C'
#include "libcounter.h"
#include <stdio.h>
int main(void) {
    ocamlcc_error_t error = {0};
    counter_init();
    printf("%lld\n", (long long) counter_inc(41, &error));
    return 0;
}
C
"$runner" tidy
case "$(uname -s)" in Darwin) shared=libcounter.dylib;; *) shared=libcounter.so;; esac
for flavor in shared static; do
    case "$flavor" in shared) library=$shared;; static) library=libcounter.a;; esac
    "$runner" build --target host "--$flavor" --emit-header "public headers/libcounter.h" -o "$library"
    cc -I "$PWD/public headers" host.c "$PWD/$library" -lm -pthread -o "$flavor-host"
    test "$("./$flavor-host")" = 42
    "$runner" build --target host "--$flavor" --emit-header "public headers/libcounter.h" -v -o "$library" > "$flavor.out" 2> "$flavor.log"
    if grep -q '^+ ' "$flavor.log"; then
        cat "$flavor.log" >&2
        exit 1
    fi
done
printf 'val twice : int -> int\n' > src/other.mli
printf 'let twice n = n * 2\n' > src/other.ml
printf 'public_mli src/other.mli\n' >> ocpkg.mod
"$runner" build --static --emit-header 'public headers/bindings.hpp' -o libboth.a
printf '#include "bindings.hpp"\n' | cc -x c -I 'public headers' -fsyntax-only -
if "$runner" build --static --emit-header collide.a -o ./collide.a > collision.out 2> collision.log; then
    exit 1
fi
grep -q 'need distinct paths' collision.log
test ! -e collide.a
echo 'native ocpkg library outputs: PASS'

mkdir -p native support src-bin
printf 'external value : unit -> int = "fixture_value"\n' > native/fixture.ml
printf 'int support_value(void);\n' > native/fixture.h
cat > native/fixture.c <<'C'
#include <stdint.h>
#include <fixture.h>
int64_t fixture_value(int64_t arg) {
    (void)arg;
    return (support_value() + OFFSET) * 2 + 1;
}
C
printf 'int support_value(void) { return 41; }\n' > support/value.c
cc -c support/value.c -o support/value.o
ar rcs support/libocpkgfixture.a support/value.o
cat >> fixture.snap <<'SNAP'
pkg fixture 1
  local native
  tree 31810d40246d18c6925da30b33116ff703522e1407587337c7370c23509946f1
  file fixture.ml <= fixture.ml
  file fixture.c <= fixture.c
  file fixture.h <= fixture.h
  cflag -DOFFSET=1
  ldflag -L./support
  ldflag -locpkgfixture
SNAP
cat > ocpkg.mod <<'MOD'
module native
entry src-bin/main.ml
source src-bin
snapshot fixture.snap
MOD
printf 'let () = print_int (Fixture.value ())\n' > src-bin/main.ml
"$runner" add fixture
mv fixture.snap fixture.old.snap
test "$("$runner" run)" = 42
printf 'int support_value(void) { return 49; }\n' > support/value.c
cc -c support/value.c -o support/value.o
ar rcs support/libocpkgfixture.a support/value.o
test "$("$runner" run)" = 50
echo 'native ocpkg recipe C and linker flags: PASS'
