#!/bin/sh
# Run from the checkout with the compatibility archive built.
set -eu
out=build/bigarray_bindgen
mkdir -p "$out"
case $(uname -s) in
    Darwin) lib="$out/libvectors.dylib" ;;
    *) lib="$out/libvectors.so" ;;
esac
build/bin/ocamlcc build --shared --stdlib-dir build/stdlib_compat/out \
    --emit-header "$out/vectors.h" tests/bigarray_bindgen/vectors.mli \
    tests/bigarray_bindgen/vectors.ml -o "$lib"
cc -std=c99 -Wall -Wextra -Werror -I"$out" tests/bigarray_bindgen/host.c "$lib" -o "$out/host"
"$out/host"
