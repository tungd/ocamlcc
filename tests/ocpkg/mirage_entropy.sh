#!/bin/sh
set -eu

runner=$1
case "$runner" in /*) ;; *) runner="$PWD/$runner";; esac
upstream=${2:?Expected an unpacked mirage-crypto 2.4.1 source directory}
case "$upstream" in /*) ;; *) upstream="$PWD/$upstream";; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export OCPKG_CACHE="$work/cache"
cd "$work"
"$runner" init mirage-entropy
"$runner" add arc-unix

cp "$upstream/src/native/mirage_crypto.h" "$upstream/src/native/bitfn.h" src/
cp "$upstream/rng/unix/mc_getrandom_stubs.c" src/mc_getrandom_body.h
cat >> ocpkg.mod <<'MOD'
cflag -DOCAMLCC_CAML_LEAF
c_source src/entropy.c
MOD

cat > src/entropy.c <<'C'
#include <errno.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>

#ifdef OCAMLCC_CAML_LEAF
#define mc_getrandom mirage_getrandom_body
#endif
#include "mc_getrandom_body.h"
#ifdef OCAMLCC_CAML_LEAF
#undef mc_getrandom
CAMLprim value mc_getrandom(value buffer, value offset, value length)
{
    return arc_unix_call_leaf3(mirage_getrandom_body, buffer, offset, length);
}
#endif

static value fail_leaf(value a, value b, value c)
{
    (void)a;
    (void)b;
    (void)c;
    errno = EIO;
    uerror("fixture_entropy", Nothing);
}

CAMLprim value force_entropy_error(value unit)
{
#ifdef OCAMLCC_CAML_LEAF
    return arc_unix_call_leaf3(fail_leaf, unit, unit, unit);
#else
    return fail_leaf(unit, unit, unit);
#endif
}
C

cat > src/main.ml <<'ML'
external entropy : bytes -> int -> int -> unit = "mc_getrandom"
external force_error : unit -> unit = "force_entropy_error"

let () =
  let buffer = Bytes.make 608 'Z' in
  entropy buffer 4 600;
  assert (Bytes.sub_string buffer 0 4 = "ZZZZ");
  assert (Bytes.sub_string buffer 604 4 = "ZZZZ");
  assert (Bytes.sub_string buffer 4 600 <> String.make 600 'Z');
  assert (match force_error () with
    | exception Unix.Unix_error (Unix.EIO, "fixture_entropy", "") -> true
    | () -> false);
  entropy buffer 4 600;
  print_endline "Unix entropy buffer and error propagation: PASS"
ML

stock_include=$(ocamlopt -where)
cc -O2 -I "$stock_include" -c src/entropy.c -o entropy.o
cp src/main.ml stock_fixture.ml
ocamlopt -I +unix -o stock unix.cmxa stock_fixture.ml entropy.o
./stock > stock.out
"$runner" run > arc.out
cmp stock.out arc.out
"$runner" run --single-thread-rc > single.out
cmp stock.out single.out
cat stock.out
