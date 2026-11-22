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
"$runner" init mirage-leaf

cp "$upstream/src/native/mirage_crypto.h" "$upstream/src/native/bitfn.h" src/
cp "$upstream/ec/native/"p256_*.h "$upstream/ec/native/"np256_*.h \
  "$upstream/ec/native/point_operations.h" "$upstream/ec/native/inversion_template.h" \
  "$upstream/ec/native/p256_stubs.c" "$upstream/ec/native/np256_stubs.c" src/
cat >> ocpkg.mod <<'MOD'
cflag -DOCAMLCC_CAML_LEAF
c_source src/p256_stubs.c
c_source src/np256_stubs.c
MOD

cat > src/main.ml <<'ML'
external decode : bytes -> string -> unit = "mc_p256_from_bytes" [@@noalloc]
external encode : bytes -> string -> unit = "mc_p256_to_bytes" [@@noalloc]
external scalar_one : bytes -> unit = "mc_np256_one" [@@noalloc]
external base : bytes * bytes * bytes -> string -> unit =
  "mc_p256_scalar_mult_base" [@@noalloc]

let () =
  let input = "\001" ^ String.make 31 '\000' in
  let field = Bytes.create 32 and output = Bytes.create 32 in
  decode field input;
  encode output (Bytes.unsafe_to_string field);
  assert (Bytes.to_string output = input);
  let scalar = Bytes.create 32 in
  scalar_one scalar;
  let x = Bytes.create 32 and y = Bytes.create 32 and z = Bytes.create 32 in
  base (x, y, z) input;
  List.iter (output_bytes stdout) [scalar; x; y; z]
ML

stock_include=$(ocamlopt -where)
for stub in p256_stubs np256_stubs; do
  cc -O2 -I "$stock_include" -c "src/$stub.c" -o "$stub.o"
done
cp src/main.ml stock_fixture.ml
ocamlopt -o stock stock_fixture.ml p256_stubs.o np256_stubs.o
./stock > stock.out
"$runner" run > arc.out
cmp stock.out arc.out
"$runner" run --single-thread-rc > single.out
cmp stock.out single.out
printf '%s\n' 'Unchanged Mirage P-256 stubs match stock OCaml'
