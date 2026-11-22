#!/bin/sh
set -eu

case $# in 0|1|2) ;; *) echo 'Usage: install.sh [release-tag] [prefix]' >&2; exit 2;; esac
release=${1:-latest}
prefix=${2:-"${HOME:?HOME must be set}/.local/occ"}
case "$release" in
    *[!a-zA-Z0-9._-]*|.|..) echo 'Invalid release tag' >&2; exit 2 ;;
esac
case "$(uname -sm)" in
    'Darwin arm64') platform=darwin-arm64 ;;
    'Linux x86_64') platform=linux-x86_64 ;;
    'Linux aarch64'|'Linux arm64') platform=linux-arm64 ;;
    *) echo 'No occ release for this host' >&2; exit 2 ;;
esac

case "$prefix" in /*) ;; *) prefix="$PWD/$prefix";; esac
if [ -e "$prefix" ] || [ -L "$prefix" ]; then
    printf 'Install directory already exists: %s\n' "$prefix" >&2
    exit 1
fi
parent=$(dirname "$prefix")
mkdir -p "$parent"
stage=$(mktemp -d "$parent/.occ-install.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
asset="occ-$platform.tar.gz"
base=https://github.com/tungd/ocamlcc/releases
case "$release" in
    latest) download="$base/latest/download" ;;
    *) download="$base/download/$release" ;;
esac
fetch() {
    curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location \
        --connect-timeout 15 --max-time 120 -o "$stage/$1" "$download/$1"
}
fetch SHA256SUMS
fetch "$asset"
(
    cd "$stage"
    awk -v name="$asset" '$2 == name && length($1) == 64 && $1 ~ /^[0-9a-f]+$/ { print; count++ } END { exit count != 1 }' \
        SHA256SUMS > checksum
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c checksum
    else
        shasum -a 256 -c checksum
    fi
)
mkdir "$stage/prefix"
tar -C "$stage/prefix" -xzf "$stage/$asset"
test -x "$stage/prefix/bin/occ"
test -x "$stage/prefix/bin/ocpkg"
if [ -e "$prefix" ] || [ -L "$prefix" ]; then
    printf 'Install directory already exists: %s\n' "$prefix" >&2
    exit 1
fi
mv "$stage/prefix" "$prefix"
printf 'Installed in %s\n' "$prefix"
