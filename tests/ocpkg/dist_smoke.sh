#!/bin/sh
set -eu
timeout_cmd=$(command -v timeout || command -v gtimeout)
bundle=$1
case "$bundle" in /*) ;; *) bundle="$PWD/$bundle";; esac
work=$2
mkdir -p "$work"
cd "$work"
work="$PWD"
mkdir unpacked project
tar -C unpacked -xzf "$bundle"
mv unpacked 'relocated prefix'
prefix="$work/relocated prefix"
export OCPKG_CACHE="$work/cache"
export PATH="$prefix/bin:$PATH"
cd project

run() {
    stage=$1
    shift
    log="$work/$stage.log"
    result=0
    "$timeout_cmd" 180 "$@" > "$log" 2>&1 || result=$?
    printf '%s exit=%s log=%s\n' "$stage" "$result" "$log" | tee -a "$work/receipt.txt"
    if [ "$result" -ne 0 ]; then tail -30 "$log" >&2; exit "$result"; fi
}

(
    cd "$prefix"
    if command -v sha256sum >/dev/null 2>&1; then
        run toolchain-checksums sha256sum -c lib/occ/toolchain.sha256
    else
        run toolchain-checksums shasum -a 256 -c lib/occ/toolchain.sha256
    fi
)
run init ocpkg init sample
run add ocpkg add cmdliner
cat > src/main.ml <<'ML'
let run () = print_endline "standalone cmdliner"
let term = Cmdliner.Term.(const run $ const ())
let command = Cmdliner.Cmd.v (Cmdliner.Cmd.info "sample") term
let () = exit (Cmdliner.Cmd.eval command)
ML
run build ocpkg build -v
run run ocpkg run
grep -Fxq 'standalone cmdliner' "$work/run.log"
run verify ocpkg verify
run env ocpkg env
grep -Fxq "QBE=$prefix/lib/occ/qbe" "$work/env.log"
grep -Fxq "OCC_STDLIB=$prefix/lib/occ/stdlib" "$work/env.log"

cat > lowlevel.ml <<'ML'
module Tree = Map.Make (Int)
let () = Printf.printf "%d\n" (Tree.find 3 (Tree.singleton 3 42))
ML
run occ-single-thread occ build --single-thread-rc -v lowlevel.ml -o lowlevel
run lowlevel ./lowlevel
test "$(cat "$work/lowlevel.log")" = 42
grep -Fq "$prefix/lib/occ/rt/libocamlrt_st.a" "$work/occ-single-thread.log"
run source-build occ build --cc cc lowlevel.ml -o source
run source ./source
test "$(cat "$work/source.log")" = 42
printf 'status=passed bundle=%s receipt=%s\n' "$bundle" "$work/receipt.txt" | tee -a "$work/receipt.txt"
