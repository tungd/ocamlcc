(** POSIX descriptors, process status and clock operations for ARC. *)

module File_descr : sig
  type t
  val to_int : t -> int
  (** Borrow the descriptor number. Ownership remains with the caller. *)

  val adopt : int -> t
  (** Take ownership of an open native descriptor without duplicating it. *)
end

type file_descr = File_descr.t

type error =
  | EACCES | EAGAIN | EBADF | EBUSY | ECHILD | EINTR | EEXIST | EINVAL | EIO | EMFILE
  | ENFILE | ENOENT | ENOMEM | ENOSYS | EPERM | EPIPE | ESRCH | ETIMEDOUT
  | EADDRINUSE | EADDRNOTAVAIL | EAFNOSUPPORT | EALREADY | ECONNREFUSED
  | ECONNRESET | EINPROGRESS | EISCONN | ENAMETOOLONG | ENOTCONN | ENOTSOCK
  | EPROTONOSUPPORT
  | EWOULDBLOCK | EUNKNOWNERR of int

exception Unix_error of error * string * string

module Error : sig
  type t = error
  val message : t -> string
end

val error_message : error -> string
val stdin : file_descr
val stdout : file_descr
val stderr : file_descr
val pipe : ?cloexec:bool -> unit -> file_descr * file_descr
val close : file_descr -> unit
val dup : ?cloexec:bool -> file_descr -> file_descr
val set_close_on_exec : file_descr -> unit
val clear_close_on_exec : file_descr -> unit
val set_nonblock : file_descr -> unit
val clear_nonblock : file_descr -> unit
val read : file_descr -> bytes -> int -> int -> int
val write : file_descr -> bytes -> int -> int -> int
val gettimeofday : unit -> float

module Open_flag : sig
  type t =
    | O_RDONLY | O_WRONLY | O_RDWR | O_NONBLOCK | O_APPEND | O_CREAT
    | O_TRUNC | O_EXCL | O_NOCTTY | O_CLOEXEC | O_KEEPEXEC
end

type open_flag = Open_flag.t =
  | O_RDONLY | O_WRONLY | O_RDWR | O_NONBLOCK | O_APPEND | O_CREAT
  | O_TRUNC | O_EXCL | O_NOCTTY | O_CLOEXEC | O_KEEPEXEC

val openfile : string -> Open_flag.t list -> int -> File_descr.t

module Socket_domain : sig
  type t = PF_UNIX | PF_INET
end

module Socket_type : sig
  type t = SOCK_STREAM | SOCK_DGRAM
end

module Inet_addr : sig
  type t
  val any : t
  val loopback : t
  val of_string : string -> t
  val to_string : t -> string
end

module Sockaddr : sig
  type t = ADDR_UNIX of string | ADDR_INET of Inet_addr.t * int
end

module Shutdown_command : sig
  type t = SHUTDOWN_RECEIVE | SHUTDOWN_SEND | SHUTDOWN_ALL
end

module Socket_bool_option : sig
  type t = SO_REUSEADDR
end

module Socket_int_option : sig
  type t = SO_SNDBUF | SO_RCVBUF
end

module Socket_float_option : sig
  type t = SO_RCVTIMEO | SO_SNDTIMEO
end

type socket_domain = Socket_domain.t = PF_UNIX | PF_INET
type socket_type = Socket_type.t = SOCK_STREAM | SOCK_DGRAM
type inet_addr = Inet_addr.t
type sockaddr = Sockaddr.t = ADDR_UNIX of string | ADDR_INET of inet_addr * int
type shutdown_command = Shutdown_command.t = SHUTDOWN_RECEIVE | SHUTDOWN_SEND | SHUTDOWN_ALL
type socket_bool_option = Socket_bool_option.t = SO_REUSEADDR
type socket_int_option = Socket_int_option.t = SO_SNDBUF | SO_RCVBUF
type socket_float_option = Socket_float_option.t = SO_RCVTIMEO | SO_SNDTIMEO

val inet_addr_any : inet_addr
val inet_addr_loopback : inet_addr
val inet_addr_of_string : string -> inet_addr
val string_of_inet_addr : inet_addr -> string
val socket : ?cloexec:bool -> Socket_domain.t -> Socket_type.t -> int -> File_descr.t
val socketpair :
  ?cloexec:bool -> Socket_domain.t -> Socket_type.t -> int -> File_descr.t * File_descr.t
val bind : File_descr.t -> Sockaddr.t -> unit
val connect : File_descr.t -> Sockaddr.t -> unit
val listen : File_descr.t -> int -> unit
val accept : ?cloexec:bool -> File_descr.t -> File_descr.t * Sockaddr.t
val getsockname : File_descr.t -> Sockaddr.t
val getpeername : File_descr.t -> Sockaddr.t
val shutdown : File_descr.t -> Shutdown_command.t -> unit
val setsockopt : File_descr.t -> Socket_bool_option.t -> bool -> unit
val setsockopt_int : File_descr.t -> Socket_int_option.t -> int -> unit
val setsockopt_float : File_descr.t -> Socket_float_option.t -> float -> unit

module Wait_flag : sig
  type t = WNOHANG | WUNTRACED
end

module Process_status : sig
  type t = WEXITED of int | WSIGNALED of int | WSTOPPED of int
end

type wait_flag = Wait_flag.t = WNOHANG | WUNTRACED
type process_status = Process_status.t =
  | WEXITED of int | WSIGNALED of int | WSTOPPED of int

val getpid : unit -> int
val kill : int -> int -> unit
(** Send a signal given as a [Sys.sig*] constant or native signal number. *)

val waitpid : Wait_flag.t list -> int -> int * Process_status.t
(** With [WNOHANG], [(0, WEXITED 0)] means no child status is ready. *)

module Signal_events : sig
  module Event : sig
    type t = Interrupt | Terminate | Child_exit
  end

  type t

  val with_events : (t -> 'a) -> 'a
  (** On Darwin, route SIGINT, SIGTERM and SIGCHLD to a kqueue within the
      callback and restore the process's previous signal actions on exit.
      Use from a single OS thread with one active scope per process. Raises
      [Unix_error (EBUSY, _, _)] for a nested scope and [ENOSYS] elsewhere. *)

  val descriptor : t -> File_descr.t
  (** Borrow the active scope's descriptor for [Fiber.fd_wait]. *)

  val next : t -> Event.t option
  (** Read one pending event without blocking. Signals can coalesce.
      On [Child_exit], drain [waitpid [WNOHANG] (-1)] until no child is ready. *)
end
