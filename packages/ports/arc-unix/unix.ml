module File_descr = struct
  type t = int

  let to_int fd = fd
end

type file_descr = File_descr.t

module Error = struct
  type t =
    | EACCES | EAGAIN | EBADF | EBUSY | ECHILD | EINTR | EINVAL | EIO | EMFILE
    | ENFILE | ENOENT | ENOMEM | ENOSYS | EPERM | EPIPE | ESRCH | ETIMEDOUT
    | EWOULDBLOCK | EUNKNOWNERR of int

  external number : string -> int = "arc_unix_errno"
  external native_message : int -> string = "arc_unix_error_message"

  let codes =
    List.map (fun (name, error) -> number name, error)
      [ "EACCES", EACCES; "EAGAIN", EAGAIN; "EBADF", EBADF; "EBUSY", EBUSY; "ECHILD", ECHILD;
        "EINTR", EINTR; "EINVAL", EINVAL; "EIO", EIO; "EMFILE", EMFILE;
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
  | EACCES | EAGAIN | EBADF | EBUSY | ECHILD | EINTR | EINVAL | EIO | EMFILE
  | ENFILE | ENOENT | ENOMEM | ENOSYS | EPERM | EPIPE | ESRCH | ETIMEDOUT
  | EWOULDBLOCK | EUNKNOWNERR of int

exception Unix_error of error * string * string

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
  external set_nonblock : file_descr -> bool -> int = "arc_unix_set_nonblock"
  external read : file_descr -> bytes -> int -> int -> int = "arc_unix_read"
  external write : file_descr -> bytes -> int -> int -> int = "arc_unix_write"
  external gettimeofday : unit -> (float, int) result = "arc_unix_gettimeofday"
  external kill : int -> int -> int = "arc_unix_kill"
  external waitpid : int -> bool -> bool -> (int * Process_status.t, int) result =
    "arc_unix_waitpid"
end

let error_message = Error.message

let raise_errno operation code =
  raise (Unix_error (Error.of_number code, operation, ""))

let check operation result =
  if result < 0 then raise_errno operation (-result) else result

let get operation = function Ok value -> value | Error code -> raise_errno operation code

let stdin = 0
let stdout = 1
let stderr = 2
let pipe ?(cloexec = false) () = get "pipe" (Native.pipe cloexec)
let close fd = ignore (check "close" (Native.close fd))

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
