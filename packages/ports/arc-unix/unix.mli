(** POSIX descriptors and clock operations for the ARC runtime. *)

type file_descr

type error =
  | EACCES | EAGAIN | EBADF | ECHILD | EINTR | EINVAL | EIO | EMFILE
  | ENFILE | ENOENT | ENOMEM | ENOSYS | EPERM | EPIPE | ESRCH | ETIMEDOUT
  | EWOULDBLOCK | EUNKNOWNERR of int

exception Unix_error of error * string * string

val error_message : error -> string
val stdin : file_descr
val stdout : file_descr
val stderr : file_descr
val pipe : ?cloexec:bool -> unit -> file_descr * file_descr
val close : file_descr -> unit
val set_nonblock : file_descr -> unit
val clear_nonblock : file_descr -> unit
val read : file_descr -> bytes -> int -> int -> int
val write : file_descr -> bytes -> int -> int -> int
val gettimeofday : unit -> float
