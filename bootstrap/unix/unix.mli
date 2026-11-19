(** Minimal Unix compatibility shim for self-hosted ocamlcc.
    Covers only the Unix surface used by [lib/driver.ml]; linked solely into
    the bootstrap compiler binary so host Dune builds remain unchanged. *)

type error =
  | ENOENT
  | EUNKNOWNERR of int

exception Unix_error of error * string * string

val error_message : error -> string

type file_descr

val stdin : file_descr
val stdout : file_descr
val stderr : file_descr

type file_kind =
  | S_REG
  | S_DIR
  | S_CHR
  | S_BLK
  | S_LNK
  | S_FIFO
  | S_SOCK

type stats = { st_kind : file_kind }

val lstat : string -> stats
val rmdir : string -> unit
val unlink : string -> unit

type open_flag =
  | O_RDONLY
  | O_WRONLY
  | O_RDWR
  | O_CREAT
  | O_TRUNC
  | O_APPEND
  | O_CLOEXEC

val openfile : string -> open_flag list -> int -> file_descr
val close : file_descr -> unit
val pipe : ?cloexec:bool -> unit -> file_descr * file_descr
val in_channel_of_descr : file_descr -> in_channel

type process_status =
  | WEXITED of int
  | WSIGNALED of int
  | WSTOPPED of int

val create_process :
  string -> string array -> file_descr -> file_descr -> file_descr -> int

val waitpid : unit list -> int -> int * process_status
