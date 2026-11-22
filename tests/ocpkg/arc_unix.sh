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
#define _POSIX_C_SOURCE 200809L
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

static volatile sig_atomic_t term_count;

static void on_term(int signal) {
    (void)signal;
    term_count++;
}

int64_t install_term_handler(int64_t unit) {
    (void)unit;
    struct sigaction action = {.sa_handler = on_term};
    sigemptyset(&action.sa_mask);
    return sigaction(SIGTERM, &action, NULL) == 0 ? 3 : 1;
}

int64_t term_signals(int64_t unit) {
    (void)unit;
    return (int64_t)term_count * 2 + 1;
}
C

cat > src/main.ml <<'ML'
external cloexec : Unix.file_descr -> bool = "fd_is_cloexec"
external start_child : Unix.file_descr -> Unix.file_descr -> int = "start_child"
external clean_up_child : int -> unit = "clean_up_child"
external install_term_handler : unit -> bool = "install_term_handler"
external term_signals : unit -> int = "term_signals"

let test_files () =
  let path = "arc-unix-file" in
  let fd = Unix.openfile path
      [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC] 0o600 in
  let adopted = Unix.File_descr.adopt (Unix.File_descr.to_int fd) in
  assert (cloexec adopted);
  let duplicate = Unix.dup ~cloexec:true adopted in
  Unix.close adopted;
  assert (cloexec duplicate);
  Unix.clear_close_on_exec duplicate;
  assert (not (cloexec duplicate));
  Unix.set_close_on_exec duplicate;
  assert (cloexec duplicate);
  assert (Unix.write duplicate (Bytes.of_string "ab") 0 2 = 2);
  Unix.close duplicate;
  assert (match Unix.File_descr.adopt (Unix.File_descr.to_int duplicate) with
    | exception Unix.Unix_error (Unix.EBADF, "adopt", "") -> true
    | _ -> false);
  assert (match Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL] 0o600 with
    | exception Unix.Unix_error (Unix.EEXIST, "open", found) -> found = path
    | _ -> false);
  let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_APPEND] 0 in
  assert (not (cloexec fd));
  assert (Unix.write fd (Bytes.of_string "c") 0 1 = 1);
  Unix.close fd;
  let fd = Unix.openfile path [Unix.O_RDONLY] 0 in
  let buffer = Bytes.make 3 '.' in
  assert (Unix.read fd buffer 0 3 = 3 && Bytes.to_string buffer = "abc");
  Unix.close fd;
  Sys.remove path

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

let test_signal_events () =
  let module Signals = Unix.Signal_events in
  let test_darwin () =
    assert (install_term_handler ());
    let events, fd = Signals.with_events (fun events ->
      let fd = Signals.descriptor events in
      assert (cloexec fd && Signals.next events = None);
      assert (match Signals.with_events ignore with
        | exception Unix.Unix_error (Unix.EBUSY, _, _) -> true
        | () -> false);
      let await expected trigger =
        let watcher = Fiber.spawn (fun () ->
          let ready = Fiber.fd_wait ~timeout_ms:3000
              (Unix.File_descr.to_int fd) Fiber.Direction.Read in
          assert (ready = Fiber.Wait_result.Ready);
          Signals.next events) in
        let sender = Fiber.spawn trigger in
        Fiber.await sender;
        assert (Fiber.await watcher = Some expected)
      in
      with_child (fun pid writer ->
        await Signals.Event.Child_exit (fun () ->
          assert (Unix.write writer (Bytes.of_string "x") 0 1 = 1));
        assert (Unix.waitpid [Unix.WNOHANG] pid = (pid, Unix.WEXITED 23)));
      await Signals.Event.Interrupt (fun () -> Unix.kill (Unix.getpid ()) Sys.sigint);
      await Signals.Event.Terminate (fun () -> Unix.kill (Unix.getpid ()) Sys.sigterm);
      assert (term_signals () = 0);
      events, fd) in
    assert (not (cloexec fd));
    assert (match Signals.next events with
      | exception Invalid_argument _ -> true
      | _ -> false);
    let exception Exit_scope in
    assert (match Signals.with_events (fun _ -> raise Exit_scope) with
      | exception Exit_scope -> true
      | _ -> false);
    Unix.kill (Unix.getpid ()) Sys.sigterm;
    assert (term_signals () = 1);
    print_endline "ARC Unix signal readiness: PASS"
  in
  if Sys.argv.(1) = "Darwin" then test_darwin ()
  else
    assert (match Signals.with_events ignore with
      | exception Unix.Unix_error (Unix.ENOSYS, _, _) -> true
      | () -> false)

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
  test_files ();
  print_endline "ARC Unix file descriptors: PASS";
  test_children ();
  print_endline "ARC Unix child status: PASS";
  test_signal_events ()
ML
system=$(uname -s)
"$runner" run -- "$system"
"$runner" run --single-thread-rc -- "$system"
