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
#include <signal.h>
#include <stdint.h>
#include <sys/wait.h>
#include <unistd.h>

int64_t fd_is_cloexec(int64_t descriptor) {
    int flags = fcntl((int)(descriptor >> 1), F_GETFD);
    return flags >= 0 && (flags & FD_CLOEXEC) ? 3 : 1;
}

int64_t start_child(int64_t reader, int64_t writer) {
    pid_t pid = fork();
    if (pid == 0) {
        char byte;
        close((int)(writer >> 1));
        _exit(read((int)(reader >> 1), &byte, 1) == 1 ? 23 : 1);
    }
    return (int64_t)(((uint64_t)pid << 1) | 1);
}

int64_t clean_up_child(int64_t child) {
    pid_t pid = (pid_t)(child >> 1);
    if (waitpid(pid, NULL, WNOHANG) == 0) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
    }
    return 1;
}
C

cat > src/main.ml <<'ML'
external cloexec : Unix.file_descr -> bool = "fd_is_cloexec"
external start_child : Unix.file_descr -> Unix.file_descr -> int = "start_child"
external clean_up_child : int -> unit = "clean_up_child"

let with_child f =
  let reader, writer = Unix.pipe ~cloexec:true () in
  let pid = start_child reader writer in
  Unix.close reader;
  Fun.protect ~finally:(fun () -> Unix.close writer) (fun () ->
    assert (pid > 0);
    Fun.protect ~finally:(fun () -> clean_up_child pid) (fun () -> f pid writer))

let test_children () =
  assert (Unix.getpid () > 0);
  Unix.kill (Unix.getpid ()) 0;
  with_child (fun pid writer ->
    assert (Unix.waitpid [Unix.WNOHANG] pid = (0, Unix.WEXITED 0));
    assert (Unix.write writer (Bytes.of_string "x") 0 1 = 1);
    assert (Unix.waitpid [] pid = (pid, Unix.WEXITED 23));
    assert (match Unix.waitpid [Unix.WNOHANG] pid with
      | exception Unix.Unix_error (Unix.ECHILD, "waitpid", "") -> true
      | _ -> false));
  with_child (fun pid _ ->
    Unix.kill pid Sys.sigstop;
    assert (Unix.waitpid [Unix.WUNTRACED] pid = (pid, Unix.WSTOPPED Sys.sigstop));
    Unix.kill pid Sys.sigkill;
    assert (Unix.waitpid [] pid = (pid, Unix.WSIGNALED Sys.sigkill)));
  with_child (fun pid _ ->
    Unix.kill pid Sys.sigterm;
    assert (Unix.waitpid [] pid = (pid, Unix.WSIGNALED Sys.sigterm)))

let () =
  let reader, writer = Unix.pipe ~cloexec:true () in
  assert (cloexec reader && cloexec writer);
  assert (Unix.File_descr.to_int reader <> Unix.File_descr.to_int writer);
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
  assert (Unix.Error.message Unix.EBADF = Unix.error_message Unix.EBADF);
  assert (Unix.gettimeofday () > 0.);
  print_endline "ARC Unix descriptors: PASS";
  test_children ();
  print_endline "ARC Unix child status: PASS"
ML
"$runner" run
