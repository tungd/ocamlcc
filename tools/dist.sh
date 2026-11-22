#!/bin/sh
set -eu

build_dir=build
dist="$build_dir/dist"
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$arch" in aarch64) arch=arm64 ;; esac
output="$dist/occ-$os-$arch.tar.gz"
if [ "${1:-}" = --path ]; then
    printf '%s\n' "$output"
    exit 0
fi
mkdir -p "$dist"
stage=$(mktemp -d "$dist/.stage.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
prefix="$stage/prefix"
lib="$prefix/lib/occ"
mkdir -p "$prefix/bin" "$lib/rt" "$lib/rt-src" "$lib/stdlib" "$lib/stdlib-src" "$lib/snapshots" "$lib/ports"
install -m 755 "$build_dir/bin/occ" "$build_dir/bin/ocpkg" "$prefix/bin/"
install -m 755 "$build_dir/qbe/qbe" "$lib/qbe"
install -m 644 "$build_dir/rt/libocamlrt.a" "$build_dir/rt-single/libocamlrt_st.a" "$lib/rt/"
install -m 644 runtime/*.c runtime/*.h runtime/*.S runtime/*.inc "$lib/rt-src/"
install -m 644 "$build_dir/stdlib/"*.cmi "$build_dir/stdlib/"*.o "$build_dir/stdlib/"*.exports \
  "$build_dir/stdlib/libocamlstdlib.a" "$build_dir/stdlib/libocamlstdlib.a.opt" "$lib/stdlib/"
install -m 644 "$build_dir/stdlib.sources" "$lib/stdlib-src/stdlib.sources"
install -m 644 packages/snapshots/default.snap "$lib/snapshots/default.snap"
cp -R packages/ports/arc-unix packages/ports/crunch-unix "$lib/ports/"
mkdir -p "$prefix/share/doc/occ"
install -m 644 vendor/qbe/LICENSE "$prefix/share/doc/occ/qbe-LICENSE"
install -m 644 vendor/ocaml-stdlib/LICENSE "$prefix/share/doc/occ/ocaml-LICENSE"
(
    cd "$prefix"
    if command -v sha256sum >/dev/null 2>&1; then
        find bin lib/occ -type f -exec sha256sum {} +
    else
        find bin lib/occ -type f -exec shasum -a 256 {} +
    fi
) > "$stage/toolchain.sha256"
mv "$stage/toolchain.sha256" "$lib/toolchain.sha256"
COPYFILE_DISABLE=1 tar -C "$prefix" -czf "$stage/bundle.tar.gz" .
mv "$stage/bundle.tar.gz" "$output"
printf '%s\n' "$output"
