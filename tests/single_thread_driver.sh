#!/bin/sh
set -eu
compiler=$1
stdlib=$2
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check() {
    "$compiler" build --single-thread-rc --stdlib-dir "$stdlib" "$@" \
      examples/cycle_collect.ml -o "$work/cycle_collect"
    "$work/cycle_collect" > "$work/result"
    diff -u tests/cycle_collect.expected "$work/result"
}

check
check --cc cc
echo 'single-thread driver: PASS'
