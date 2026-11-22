#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/bootstrap_test"
mkdir -p "$OUT"

ZSTD_CFLAGS="$(pkg-config --cflags libzstd 2>/dev/null || echo '-I/opt/local/include')"
ZSTD_LIBS="$(pkg-config --libs libzstd 2>/dev/null || echo '-L/opt/local/lib -lzstd')"

HOST_CMI="$ROOT/build/stdlib/stdlib.cmi"
if [ ! -f "$HOST_CMI" ]; then
  HOST_CMI="$(ocamlopt -where)/stdlib.cmi"
fi

# 1. Native + ASan test of bootstrap/stubs/compiler_stubs.c
cc -std=c11 -O2 -g -Wall -Wextra -Werror -I"$ROOT/runtime" $ZSTD_CFLAGS \
  "$ROOT/tests/bootstrap_stubs_test.c" \
  "$ROOT/bootstrap/stubs/compiler_stubs.c" \
  "$ROOT/build/rt/libocamlrt.a" \
  $ZSTD_LIBS -lm -pthread -o "$OUT/compiler_stubs_test"
"$OUT/compiler_stubs_test" "$HOST_CMI"

cc -std=c11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
  -Wall -Wextra -Werror -I"$ROOT/runtime" $ZSTD_CFLAGS \
  "$ROOT/tests/bootstrap_stubs_test.c" \
  "$ROOT/bootstrap/stubs/compiler_stubs.c" \
  "$ROOT/build/asan/rt/libocamlrt.a" \
  $ZSTD_LIBS -lm -pthread -o "$OUT/compiler_stubs_test_asan"
"$OUT/compiler_stubs_test_asan" "$HOST_CMI"

# 2. Native + ASan test of bootstrap/unix/ compiled by ocamlcc against stdlib_compat
STDLIB_DIR="$ROOT/build/stdlib"
"$ROOT/build/bin/occ" compile-mli --nostdlib -I "$STDLIB_DIR" \
  "$ROOT/bootstrap/unix/unix.mli" -o "$OUT/unix.cmi"
"$ROOT/build/bin/occ" compile --nostdlib --mod -I "$STDLIB_DIR" -I "$OUT" \
  "$ROOT/bootstrap/unix/unix.ml" -o "$OUT/unix.ssa"
"$ROOT/build/qbe/qbe" "$OUT/unix.ssa" > "$OUT/unix.s"
cc -c "$OUT/unix.s" -o "$OUT/unix.o"
cc -std=c11 -O2 -g -Wall -Wextra -Werror -I"$ROOT/runtime" \
  -c "$ROOT/bootstrap/unix/unix_stubs.c" -o "$OUT/unix_stubs.o"

"$ROOT/build/bin/occ" compile-mli --nostdlib -I "$STDLIB_DIR" -I "$OUT" \
  "$ROOT/lib/sys_util.mli" -o "$OUT/sys_util.cmi"
"$ROOT/build/bin/occ" compile --nostdlib --mod -I "$STDLIB_DIR" -I "$OUT" \
  "$ROOT/lib/sys_util.ml" -o "$OUT/sys_util.ssa"
"$ROOT/build/qbe/qbe" "$OUT/sys_util.ssa" > "$OUT/sys_util.s"
cc -c "$OUT/sys_util.s" -o "$OUT/sys_util.o"

"$ROOT/build/bin/occ" compile --nostdlib -I "$STDLIB_DIR" -I "$OUT" \
  "$ROOT/tests/bootstrap_unix_test.ml" -o "$OUT/bootstrap_unix_test.ssa"
"$ROOT/build/qbe/qbe" "$OUT/bootstrap_unix_test.ssa" > "$OUT/bootstrap_unix_test.s"
cc -c "$OUT/bootstrap_unix_test.s" -o "$OUT/bootstrap_unix_test.o"

cc "$OUT/bootstrap_unix_test.o" "$OUT/sys_util.o" "$OUT/unix.o" "$OUT/unix_stubs.o" \
  "$STDLIB_DIR/libocamlstdlib.a" "$ROOT/build/rt/libocamlrt.a" \
  -lm -pthread -o "$OUT/bootstrap_unix_test"
"$OUT/bootstrap_unix_test"

cc -std=c11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
  -Wall -Wextra -Werror -I"$ROOT/runtime" \
  -c "$ROOT/bootstrap/unix/unix_stubs.c" -o "$OUT/unix_stubs_asan.o"
cc -fsanitize=address,undefined -fno-sanitize-recover=all \
  "$OUT/bootstrap_unix_test.o" "$OUT/sys_util.o" "$OUT/unix.o" "$OUT/unix_stubs_asan.o" \
  "$STDLIB_DIR/libocamlstdlib.a" "$ROOT/build/asan/rt/libocamlrt.a" \
  -lm -pthread -o "$OUT/bootstrap_unix_test_asan"
"$OUT/bootstrap_unix_test_asan"
