#!/bin/sh
set -eu
compiler=$1
stdlib=$2
fiber_object=$3
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check_fiber_tls() {
    nm -u "$1" > "$work/symbols"
    if grep -Eq 'pthread_(key_create|once|setspecific)|tlv_bootstrap|tls_get_addr' "$work/symbols"; then
        echo "single-thread Fiber uses thread-local storage: $1" >&2
        exit 1
    fi
}

check() {
    "$compiler" build --single-thread-rc --stdlib-dir "$stdlib" --work-dir "$work/build" "$@" \
      examples/cycle_collect.ml -o "$work/cycle_collect"
    "$work/cycle_collect" > "$work/result"
    diff -u tests/cycle_collect.expected "$work/result"
}

check_fiber_tls "$fiber_object"
check
check --cc cc
check_fiber_tls "$work/build/rt/fiber.o"
echo 'single-thread driver: PASS'
