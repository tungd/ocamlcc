module Error = struct
  type t =
    | EACCES | EAGAIN | EBADF | EBUSY | ECHILD | EINTR | EEXIST | EINVAL | EIO | EMFILE
    | ENFILE | ENOENT | ENOMEM | ENOSYS | EPERM | EPIPE | ESRCH | ETIMEDOUT
    | EWOULDBLOCK | EUNKNOWNERR of int

  external number : string -> int = "arc_unix_errno"
  external native_message : int -> string = "arc_unix_error_message"

  let codes =
    List.map (fun (name, error) -> number name, error)
      [ "EACCES", EACCES; "EAGAIN", EAGAIN; "EBADF", EBADF; "EBUSY", EBUSY; "ECHILD", ECHILD;
        "EINTR", EINTR; "EEXIST", EEXIST; "EINVAL", EINVAL; "EIO", EIO; "EMFILE", EMFILE;
        "ENFILE", ENFILE; "ENOENT", ENOENT; "ENOMEM", ENOMEM; "ENOSYS", ENOSYS;
        "EPERM", EPERM; "EPIPE", EPIPE; "ESRCH", ESRCH; "ETIMEDOUT", ETIMEDOUT;
        "EWOULDBLOCK", EWOULDBLOCK ]

  let of_number code =
    Option.value (List.assoc_opt code codes) ~default:(EUNKNOWNERR code)

  let message = function
    | EUNKNOWNERR code -> native_message code
    | error ->
        match List.find_opt (fun (_, known) -> known = error) codes with
        | Some (code, _) -> native_message code
        | None -> "Unknown Unix error"
end

type error = Error.t =
  | EACCES | EAGAIN | EBADF | EBUSY | ECHILD | EINTR | EEXIST | EINVAL | EIO | EMFILE
  | ENFILE | ENOENT | ENOMEM | ENOSYS | EPERM | EPIPE | ESRCH | ETIMEDOUT
  | EWOULDBLOCK | EUNKNOWNERR of int

exception Unix_error of error * string * string

let error_message = Error.message

let raise_errno ?(argument = "") operation code =
  raise (Unix_error (Error.of_number code, operation, argument))

let check ?argument operation result =
  if result < 0 then raise_errno ?argument operation (-result) else result

let get operation = function Ok value -> value | Error code -> raise_errno operation code

module File_descr = struct
  type t = int

  let to_int fd = fd

  external probe : int -> int = "arc_unix_check_fd"

  let adopt fd = check "adopt" (probe fd)
end

type file_descr = File_descr.t

module Open_flag = struct
  type t =
    | O_RDONLY | O_WRONLY | O_RDWR | O_NONBLOCK | O_APPEND | O_CREAT
    | O_TRUNC | O_EXCL | O_NOCTTY | O_CLOEXEC | O_KEEPEXEC

  let encode flags =
    List.fold_left (fun mask flag ->
      let bit = match flag with
        | O_RDONLY -> 0 | O_WRONLY -> 1 | O_RDWR -> 2
        | O_NONBLOCK -> 4 | O_APPEND -> 8 | O_CREAT -> 16 | O_TRUNC -> 32
        | O_EXCL -> 64 | O_NOCTTY -> 128 | O_CLOEXEC -> 256 | O_KEEPEXEC -> 512 in
      mask lor bit) 0 flags
end

type open_flag = Open_flag.t =
  | O_RDONLY | O_WRONLY | O_RDWR | O_NONBLOCK | O_APPEND | O_CREAT
  | O_TRUNC | O_EXCL | O_NOCTTY | O_CLOEXEC | O_KEEPEXEC

module Wait_flag = struct
  type t = WNOHANG | WUNTRACED
end

module Process_status = struct
  type t = WEXITED of int | WSIGNALED of int | WSTOPPED of int
end

type wait_flag = Wait_flag.t = WNOHANG | WUNTRACED
type process_status = Process_status.t =
  | WEXITED of int | WSIGNALED of int | WSTOPPED of int

module Native = struct
  external pipe : bool -> (file_descr * file_descr, int) result = "arc_unix_pipe"
  external close : file_descr -> int = "arc_unix_close"
  external openfile : string -> int -> int -> int = "arc_unix_openfile"
  external dup : file_descr -> bool -> int = "arc_unix_dup"
  external set_cloexec : file_descr -> bool -> int = "arc_unix_set_cloexec"
  external set_nonblock : file_descr -> bool -> int = "arc_unix_set_nonblock"
  external read : file_descr -> bytes -> int -> int -> int = "arc_unix_read"
  external write : file_descr -> bytes -> int -> int -> int = "arc_unix_write"
  external gettimeofday : unit -> (float, int) result = "arc_unix_gettimeofday"
  external kill : int -> int -> int = "arc_unix_kill"
  external waitpid : int -> bool -> bool -> (int * Process_status.t, int) result =
    "arc_unix_waitpid"
end

let stdin = 0
let stdout = 1
let stderr = 2
let pipe ?(cloexec = false) () = get "pipe" (Native.pipe cloexec)
let close fd = ignore (check "close" (Native.close fd))
let dup ?(cloexec = false) fd = check "dup" (Native.dup fd cloexec)
let set_close_on_exec fd = ignore (check "set_close_on_exec" (Native.set_cloexec fd true))
let clear_close_on_exec fd = ignore (check "clear_close_on_exec" (Native.set_cloexec fd false))

let openfile path flags permissions =
  if String.contains path '\000' then raise (Unix_error (EINVAL, "open", path));
  check ~argument:path "open" (Native.openfile path (Open_flag.encode flags) permissions)

let set_nonblock fd = ignore (check "set_nonblock" (Native.set_nonblock fd true))
let clear_nonblock fd = ignore (check "clear_nonblock" (Native.set_nonblock fd false))

let transfer name call fd buffer pos len =
  if pos < 0 || len < 0 || pos > Bytes.length buffer - len then
    invalid_arg ("Unix." ^ name);
  check name (call fd buffer pos len)

let read = transfer "read" Native.read
let write = transfer "write" Native.write
let gettimeofday () = get "gettimeofday" (Native.gettimeofday ())

external getpid : unit -> int = "arc_unix_getpid"

let kill pid signal = ignore (check "kill" (Native.kill pid signal))

let waitpid flags pid =
  get "waitpid"
    (Native.waitpid pid (List.mem Wait_flag.WNOHANG flags)
       (List.mem Wait_flag.WUNTRACED flags))

module Signal_events = struct
  module Event = struct
    type t = Interrupt | Terminate | Child_exit
  end

  type t = { mutable fd : File_descr.t option }

  external open_queue : unit -> (File_descr.t, int) result =
    "arc_unix_signal_queue_open"

  external close_queue : File_descr.t -> int = "arc_unix_signal_queue_close"

  external next_event : File_descr.t -> (Event.t option, int) result =
    "arc_unix_signal_queue_next"

  let descriptor scope =
    match scope.fd with
    | Some fd -> fd
    | None -> invalid_arg "Unix.Signal_events: scope closed"

  let next scope = get "Signal_events.next" (next_event (descriptor scope))

  let with_events f =
    let fd = get "Signal_events.with_events" (open_queue ()) in
    let scope = { fd = Some fd } in
    Fun.protect ~finally:(fun () ->
      scope.fd <- None;
      ignore (check "Signal_events.close" (close_queue fd)))
      (fun () -> f scope)
end
