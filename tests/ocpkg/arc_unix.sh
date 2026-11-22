#!/bin/sh
set -eu

runner=$1
case "$runner" in /*) ;; *) runner="$PWD/$runner";; esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OCPKG_CACHE="$scratch/cache"
cd "$scratch"
"$runner" init arc-unix-test
"$runner" add arc-unix
printf 'c_source src/fixture.c\n' >> ocpkg.mod

cat > src/fixture.c <<'C'
#include <fcntl.h>
#include <stdint.h>
int64_t fd_is_cloexec(int64_t descriptor) {
    int flags = fcntl((int)(descriptor >> 1), F_GETFD);
    return flags >= 0 && (flags & FD_CLOEXEC) ? 3 : 1;
}
C

cat > src/main.ml <<'ML'
external cloexec : Unix.file_descr -> bool = "fd_is_cloexec"

let () =
  let reader, writer = Unix.pipe ~cloexec:true () in
  assert (cloexec reader && cloexec writer);
  Unix.set_nonblock reader;
  let buffer = Bytes.make 5 '.' in
  assert (match Unix.read reader buffer 1 3 with
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), "read", "") -> true
    | _ -> false);
  assert (Unix.write writer (Bytes.of_string "_abc_") 1 3 = 3);
  assert (Unix.read reader buffer 1 3 = 3 && Bytes.to_string buffer = ".abc.");
  assert (match Unix.read reader buffer 4 2 with
    | exception Invalid_argument _ -> true
    | _ -> false);
  Unix.close writer;
  assert (Unix.read reader buffer 0 5 = 0);
  Unix.close reader;
  assert (match Unix.close reader with
    | exception Unix.Unix_error (Unix.EBADF, "close", "") -> true
    | _ -> false);
  assert (Unix.gettimeofday () > 0.);
  print_endline "ARC Unix descriptors: PASS"
ML
"$runner" run
