#!/bin/sh
set -eu

runner=$1
case "$runner" in /*) ;; *) runner="$PWD/$runner";; esac
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export OCPKG_CACHE="$scratch/cache"
export ARC_UNIX_TEST_ENV=parent
cd "$scratch"
"$runner" init arc-unix-test
"$runner" add arc-unix
printf 'c_source src/fixture.c\n' >> ocpkg.mod

cat > src/fixture.c <<'C'
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <sys/wait.h>
#include <unistd.h>

int64_t fd_is_cloexec(int64_t descriptor) {
    int flags = fcntl((int)(descriptor >> 1), F_GETFD);
    return flags >= 0 && (flags & FD_CLOEXEC) ? 3 : 1;
}

int64_t native_enoent(int64_t unit) {
    (void)unit;
    return (int64_t)ENOENT * 2 + 1;
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

int64_t make_symlink(int64_t target, int64_t link) {
    const char *name = (const char *)(uintptr_t)link;
    const char *destination = (const char *)(uintptr_t)target;
    return symlink(destination, name) == 0 ? 3 : 1;
}

int64_t start_lock_owner(int64_t file, int64_t parent, int64_t channel) {
    pid_t pid = fork();
    if (pid == 0) {
        int notify = (int)(channel >> 1);
        close((int)(parent >> 1));
        struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
        if (fcntl((int)(file >> 1), F_SETLK, &lock) < 0 || write(notify, "l", 1) != 1)
            _exit(1);
        char release;
        _exit(read(notify, &release, 1) == 1 ? 0 : 1);
    }
    return (int64_t)(((uint64_t)pid << 1) | 1);
}
C

cat > src/main.ml <<'ML'
external cloexec : Unix.file_descr -> bool = "fd_is_cloexec"
external enoent : unit -> int = "native_enoent"
external start_child : Unix.file_descr -> Unix.file_descr -> int = "start_child"
external clean_up_child : int -> unit = "clean_up_child"
external install_term_handler : unit -> bool = "install_term_handler"
external term_signals : unit -> int = "term_signals"
external symlink : string -> string -> bool = "make_symlink"
external start_lock_owner : Unix.file_descr -> Unix.file_descr -> Unix.file_descr -> int =
  "start_lock_owner"

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

let test_metadata () =
  let directory = "metadata-" ^ string_of_int (Unix.getpid ()) in
  Unix.mkdir directory 0o700;
  Unix.chmod directory 0o700;
  let info = Unix.lstat directory in
  assert (info.Unix.st_kind = Unix.S_DIR);
  assert (info.st_uid = Unix.getuid () && info.st_perm = 0o700);
  let first = Filename.concat directory "before" in
  let second = Filename.concat directory "after" in
  let link = Filename.concat directory "link" in
  let fd = Unix.openfile first [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_CLOEXEC] 0o600 in
  Unix.fchmod fd 0o600;
  assert (Unix.write fd (Bytes.of_string "data") 0 4 = 4);
  let opened = Unix.fstat fd in
  Unix.close fd;
  assert (opened.st_size = 4 && opened.st_mtime > 0.);
  assert (opened.st_kind = Unix.S_REG && opened.st_perm = 0o600);
  Unix.rename first second;
  assert (symlink "after" link);
  assert ((Unix.lstat link).st_kind = Unix.S_LNK);
  let followed = Unix.stat link in
  assert (followed.st_ino = opened.st_ino && followed.st_size = 4);
  assert (Filename.basename (Unix.realpath link) = "after");
  Unix.access second [Unix.R_OK; Unix.F_OK];
  Unix.unlink link;
  assert ((Unix.stat second).st_kind = Unix.S_REG);
  Unix.unlink second;
  assert (match Unix.stat second with
    | exception Unix.Unix_error (Unix.ENOENT, "stat", path) -> path = second
    | _ -> false);
  Unix.rmdir directory

let test_file_locking () =
  let path = "arc-unix-lock" in
  let fd = Unix.openfile path [Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC] 0o600 in
  Fun.protect ~finally:(fun () -> Unix.close fd; Unix.unlink path) (fun () ->
    assert (Unix.write fd (Bytes.of_string "abcd") 0 4 = 4);
    assert (Unix.lseek fd (-1) Unix.SEEK_END = 3);
    Unix.ftruncate fd 2;
    Unix.fsync fd;
    assert ((Unix.fstat fd).st_size = 2 && Unix.lseek fd 0 Unix.SEEK_CUR = 3);
    assert (Unix.lseek fd 0 Unix.SEEK_SET = 0);
    let parent, child = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    let owner = start_lock_owner fd parent child in
    Unix.close child;
    Fun.protect ~finally:(fun () -> Unix.close parent) (fun () ->
      assert (owner > 0);
      Fun.protect ~finally:(fun () -> clean_up_child owner) (fun () ->
        let ready = Bytes.create 1 in
        assert (Unix.read parent ready 0 1 = 1 && Bytes.get ready 0 = 'l');
        let locked command =
          match Unix.lockf fd command 0 with
          | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), "lockf", "") -> true
          | () -> false in
        assert (locked Unix.F_TEST && locked Unix.F_TLOCK && locked Unix.F_TRLOCK);
        assert (Unix.write parent (Bytes.of_string "x") 0 1 = 1);
        assert (Unix.waitpid [] owner = (owner, Unix.WEXITED 0))));
    Unix.lockf fd Unix.F_TEST 0;
    Unix.lockf fd Unix.F_LOCK 0;
    Unix.lockf fd Unix.F_ULOCK 0;
    Unix.lockf fd Unix.F_RLOCK 0;
    Unix.lockf fd Unix.F_ULOCK 0)

let with_socket domain f =
  let fd = Unix.socket ~cloexec:true domain Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    assert (cloexec fd);
    f fd)

let test_socket domain address =
  with_socket domain (fun listener ->
    Unix.setsockopt listener Unix.SO_REUSEADDR true;
    Unix.bind listener address;
    Unix.listen listener 8;
    let bound = Unix.getsockname listener in
    (match address, bound with
     | Unix.ADDR_UNIX path, Unix.ADDR_UNIX actual -> assert (actual = path)
     | Unix.ADDR_INET (ip, 0), Unix.ADDR_INET (actual, port) ->
         assert (actual = ip && port > 0);
         with_socket domain (fun other ->
           assert (match Unix.bind other bound with
             | exception Unix.Unix_error (Unix.EADDRINUSE, "bind", _) -> true
             | _ -> false))
     | _ -> assert false);
    Unix.set_nonblock listener;
    assert (match Unix.accept ~cloexec:true listener with
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), "accept", _) -> true
      | _ -> false);
    with_socket domain (fun client ->
      Unix.setsockopt_float client Unix.SO_RCVTIMEO 0.25;
      Unix.connect client bound;
      assert (Unix.getpeername client = bound);
      let fd = Unix.File_descr.to_int listener in
      assert (Fiber.fd_wait ~timeout_ms:1000 fd Fiber.Direction.Read = Fiber.Wait_result.Ready);
      let server, peer = Unix.accept ~cloexec:true listener in
      Fun.protect ~finally:(fun () -> Unix.close server) (fun () ->
        assert (cloexec server && Unix.getsockname server = bound);
        Unix.set_nonblock server;
        (match domain with
         | Unix.PF_INET -> assert (Unix.getsockname client = peer)
         | Unix.PF_UNIX -> assert (peer = Unix.ADDR_UNIX ""));
        assert (Unix.write client (Bytes.of_string "x") 0 1 = 1);
        Unix.shutdown client Unix.SHUTDOWN_SEND;
        let buffer = Bytes.create 1 in
        let read () =
          let fd = Unix.File_descr.to_int server in
          assert (Fiber.fd_wait ~timeout_ms:1000 fd Fiber.Direction.Read = Fiber.Wait_result.Ready);
          Unix.read server buffer 0 1
        in
        assert (read () = 1 && Bytes.get buffer 0 = 'x');
        assert (read () = 0))))

let test_sockets () =
  let path = "arc-unix.sock" in
  test_socket Unix.PF_UNIX (Unix.ADDR_UNIX path);
  Sys.remove path;
  if Sys.argv.(1) = "Linux" then
    test_socket Unix.PF_UNIX (Unix.ADDR_UNIX ("\000arc\000unix-" ^ string_of_int (Unix.getpid ())));
  let ip = Unix.inet_addr_of_string "127.0.0.1" in
  assert (ip = Unix.inet_addr_loopback && Unix.string_of_inet_addr ip = "127.0.0.1");
  test_socket Unix.PF_INET (Unix.ADDR_INET (ip, 0));
  let a, b = Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_DGRAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close a; Unix.close b) (fun () ->
    assert (cloexec a && cloexec b);
    Unix.setsockopt_int a Unix.SO_SNDBUF 4096;
    let buffer = Bytes.create 1 in
    assert (Unix.write a (Bytes.of_string "y") 0 1 = 1);
    assert (Unix.read b buffer 0 1 = 1 && Bytes.get buffer 0 = 'y'))

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

let test_supervisor () =
  let key = "ARC_UNIX_TEST_ENV" in
  assert (Array.exists ((=) (key ^ "=parent")) (Unix.environment ()));
  assert (Unix.Error.of_number (enoent ()) = Unix.ENOENT);
  let capture spawn =
    let input, send = Unix.pipe ~cloexec:true () in
    let receive, output = Unix.pipe ~cloexec:true () in
    let child =
      Fun.protect ~finally:(fun () -> Unix.close input; Unix.close output)
        (fun () -> spawn input output output)
    in
    Fun.protect ~finally:(fun () -> clean_up_child child) (fun () ->
      Fun.protect ~finally:(fun () -> Unix.close send) (fun () ->
        assert (Unix.write send (Bytes.of_string "input\n") 0 6 = 6));
      let output = Buffer.create 32 and bytes = Bytes.create 64 in
      Fun.protect ~finally:(fun () -> Unix.close receive) (fun () ->
        let rec read () =
          let count = Unix.read receive bytes 0 (Bytes.length bytes) in
          if count > 0 then begin
            Buffer.add_subbytes output bytes 0 count;
            read ()
          end
        in
        read ());
      assert (Unix.waitpid [] child = (child, Unix.WEXITED 0));
      Buffer.contents output)
  in
  let argv = [|"sh"; "-c";
    "IFS= read -r line && printf '%s:%s' \"$ARC_UNIX_TEST_ENV\" \"$line\" && printf ':stderr' >&2"|] in
  assert (capture (Unix.create_process "sh" argv) = "parent:input:stderr");
  assert (capture (Unix.create_process_env "sh" argv [|key ^ "=child"|]) = "child:input:stderr");
  assert (Sys.getenv key = "parent");
  let absent = "./absent-executable" in
  assert (match Unix.create_process absent [|"absent"|] Unix.stdin Unix.stdout Unix.stderr with
    | exception Unix.Unix_error (Unix.ENOENT, "create_process", path) -> path = absent
    | _ -> false);
  assert (match Unix.execv absent [|"absent"|] with
    | exception Unix.Unix_error (Unix.ENOENT, "execv", path) -> path = absent
    | _ -> false);
  match Unix.fork () with
  | 0 ->
      (try
         assert (Unix.setsid () = Unix.getpid ());
         Unix.execv "/bin/sh" [|"sh"; "-c"; "exit 23"|]
       with _ -> exit 1)
  | child -> assert (Unix.waitpid [] child = (child, Unix.WEXITED 23))

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
  test_metadata ();
  print_endline "ARC Unix file metadata: PASS";
  test_file_locking ();
  print_endline "ARC Unix file locking: PASS";
  test_sockets ();
  print_endline "ARC Unix sockets: PASS";
  test_children ();
  print_endline "ARC Unix child status: PASS";
  test_supervisor ();
  print_endline "ARC Unix subprocesses: PASS";
  test_signal_events ()
ML
system=$(uname -s)
"$runner" run -- "$system"
"$runner" run --single-thread-rc -- "$system"
