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
mkdir -p src pkg_a pkg_b pkg_c

printf 'let a = 10\n' > pkg_a/a.ml
printf 'let b = 20\n' > pkg_b/b.ml
printf 'let c = A.a + B.b + 12\n' > pkg_c/c.ml

python3 - <<'PY'
import hashlib, json, os, pathlib

def tree_hash(root):
    root = pathlib.Path(root)
    files = sorted(p for p in root.rglob("*") if p.is_file())
    rows = []
    for p in files:
        rel = p.relative_to(root).as_posix()
        exe = bool(p.stat().st_mode & 0o111)
        h = hashlib.sha256(p.read_bytes()).hexdigest()
        rows.append([rel, exe, h])
    payload = json.dumps(rows, separators=(",", ":"), ensure_ascii=True).encode()
    return hashlib.sha256(payload).hexdigest()

for name in ("pkg_a", "pkg_b", "pkg_c"):
    pathlib.Path(f"{name}.tree").write_text(tree_hash(name))
PY

cat > local.snap <<SNAP
schema 1
pkg alpha 1
  local pkg_a
  tree $(cat pkg_a.tree)
  file a.ml <= a.ml
pkg beta 1
  local pkg_b
  tree $(cat pkg_b.tree)
  file b.ml <= b.ml
pkg gamma 1
  dep alpha
  dep beta
  local pkg_c
  tree $(cat pkg_c.tree)
  file c.ml <= c.ml
SNAP

cat > ocpkg.mod <<'MOD'
module parallel-demo
kind exe
entry src/main.ml
source src
snapshot local.snap
require (
  gamma 1
)
c_source src/c1.c
c_source src/c2.c
MOD

cat > src/u1.ml <<'ML'
let v = 1
ML
cat > src/u2.ml <<'ML'
let v = 2
ML
cat > src/c1.c <<'C'
#include <stdint.h>
int64_t c1_val(int64_t u) { (void)u; return 3 * 2 + 1; }
C
cat > src/c2.c <<'C'
#include <stdint.h>
int64_t c2_val(int64_t u) { (void)u; return 5 * 2 + 1; }
C
cat > src/main.ml <<'ML'
external c1_val : unit -> int = "c1_val"
external c2_val : unit -> int = "c2_val"
let () = Printf.printf "%d\n" (C.c + U1.v + U2.v + c1_val () + c2_val ())
ML

"$runner" tidy
"$runner" vendor --offline

# 1. Parallel cold build reports progress on stderr and keeps stdout clean.
"$runner" build -j 4 -o app > build.out 2> build.err
test "$(cat build.out)" = "$scratch/app"
test "$(./app)" = 53
grep -q '\[deps .*/3\] Built alpha' build.err
grep -q '\[deps .*/3\] Built beta' build.err
grep -q '\[deps .*/3\] Built gamma' build.err
grep -q 'Compiled src/main.ml' build.err
grep -q '\[link\] app' build.err
# Non-TTY progress must not emit CR or ANSI escapes.
if grep -q "$(printf '\r')" build.err; then
    echo 'unexpected CR in non-TTY progress output' >&2
    exit 1
fi

# 2. Warm incremental build caches all 3 OCaml units (only C sources recompile).
"$runner" build -j 4 -o app > warm.out 2> warm.err
if grep -q 'Compiled src/.*\.ml' warm.err; then
    cat warm.err >&2
    exit 1
fi
grep -q '2 compiled, 3 cached' warm.err

# 3. Incremental rebuild changing u1.ml recompiles u1.ml and main.ml, keeping u2.ml cached.
printf 'let v = 11\n' > src/u1.ml
"$runner" build --jobs=2 -o app > inc.out 2> inc.err
test "$(./app)" = 63
grep -q 'Compiled src/u1.ml' inc.err
grep -q 'Compiled src/main.ml' inc.err
if grep -q 'Compiled src/u2.ml' inc.err; then
    cat inc.err >&2
    exit 1
fi

# 4. --no-progress suppresses stderr progress while keeping run stdout exact.
printf 'let v = 12\n' > src/u2.ml
"$runner" run -j1 --no-progress > run.out 2> run.err
test "$(cat run.out)" = 73
test ! -s run.err

# 5. Invalid -j values are rejected cleanly.
if "$runner" build -j 0 > /dev/null 2> badj.err; then
    exit 1
fi
grep -q 'invalid job count' badj.err

echo 'parallel build and progress reporting: PASS'
