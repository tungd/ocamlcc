#!/bin/sh
# Run from the checkout with the compatibility archive built.
set -eu
out=build/bigarray_bindgen
mkdir -p "$out"
case $(uname -s) in
    Darwin) ext=dylib ;;
    *) ext=so ;;
esac
build/bin/occ build --shared --stdlib-dir build/stdlib \
    --emit-header "$out/vectors.h" tests/bigarray_bindgen/vectors.mli \
    tests/bigarray_bindgen/vectors.ml tests/bigarray_bindgen/native.c -o "$out/libvectors.$ext"
# Compile the same interface into a second library with its own ARC heap.
cp tests/bigarray_bindgen/vectors.ml "$out/peer.ml"
cp tests/bigarray_bindgen/vectors.mli "$out/peer.mli"
build/bin/occ build --shared --stdlib-dir build/stdlib \
    --emit-header "$out/peer.h" "$out/peer.mli" "$out/peer.ml" -o "$out/libpeer.$ext"
cc -std=c99 -Wall -Wextra -Werror -I"$out" tests/bigarray_bindgen/host.c \
    "$out/libvectors.$ext" "$out/libpeer.$ext" -o "$out/host"
"$out/host"
