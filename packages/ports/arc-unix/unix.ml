type file_descr = int

type error =
  | EACCES | EAGAIN | EBADF | ECHILD | EINTR | EINVAL | EIO | EMFILE
  | ENFILE | ENOENT | ENOMEM | ENOSYS | EPERM | EPIPE | ESRCH | ETIMEDOUT
  | EWOULDBLOCK | EUNKNOWNERR of int

exception Unix_error of error * string * string

module Native = struct
  external errno : string -> int = "arc_unix_errno"
  external message : int -> string = "arc_unix_error_message"
  external pipe : bool -> (file_descr * file_descr, int) result = "arc_unix_pipe"
  external close : file_descr -> int = "arc_unix_close"
  external set_nonblock : file_descr -> bool -> int = "arc_unix_set_nonblock"
  external read : file_descr -> bytes -> int -> int -> int = "arc_unix_read"
  external write : file_descr -> bytes -> int -> int -> int = "arc_unix_write"
  external gettimeofday : unit -> (float, int) result = "arc_unix_gettimeofday"
end

let error_codes =
  List.map (fun (name, error) -> Native.errno name, error)
    [ "EACCES", EACCES; "EAGAIN", EAGAIN; "EBADF", EBADF; "ECHILD", ECHILD;
      "EINTR", EINTR; "EINVAL", EINVAL; "EIO", EIO; "EMFILE", EMFILE;
      "ENFILE", ENFILE; "ENOENT", ENOENT; "ENOMEM", ENOMEM; "ENOSYS", ENOSYS;
      "EPERM", EPERM; "EPIPE", EPIPE; "ESRCH", ESRCH; "ETIMEDOUT", ETIMEDOUT;
      "EWOULDBLOCK", EWOULDBLOCK ]

let error_of_number code =
  Option.value (List.assoc_opt code error_codes) ~default:(EUNKNOWNERR code)

let error_message error =
  let number =
    match error with
    | EUNKNOWNERR number -> number
    | error -> fst (List.find (fun (_, known) -> known = error) error_codes)
  in
  Native.message number

let raise_errno operation code = raise (Unix_error (error_of_number code, operation, ""))

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
