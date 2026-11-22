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
    "$runner" build --target host "--$flavor" -o "$library"
    cc -I "$PWD" host.c "$PWD/$library" -lm -pthread -o "$flavor-host"
    test "$("./$flavor-host")" = 42
    "$runner" build --target host "--$flavor" -v -o "$library" > "$flavor.out" 2> "$flavor.log"
    if grep -q '^+ ' "$flavor.log"; then
        cat "$flavor.log" >&2
        exit 1
    fi
done
echo 'native ocpkg library outputs: PASS'
