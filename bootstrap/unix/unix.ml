type error =
  | ENOENT
  | EUNKNOWNERR of int

exception Unix_error of error * string * string

type file_descr = int

let stdin = 0
let stdout = 1
let stderr = 2

type file_kind =
  | S_REG
  | S_DIR
  | S_CHR
  | S_BLK
  | S_LNK
  | S_FIFO
  | S_SOCK

type stats = { st_kind : file_kind }

type open_flag =
  | O_RDONLY
  | O_WRONLY
  | O_RDWR
  | O_CREAT
  | O_TRUNC
  | O_APPEND
  | O_CLOEXEC

type process_status =
  | WEXITED of int
  | WSIGNALED of int
  | WSTOPPED of int

external c_enoent : unit -> int = "ocamlcc_unix_enoent"
external c_error_message : int -> string = "ocamlcc_unix_error_message"
external c_lstat : string -> (int, int) result = "ocamlcc_unix_lstat"
external c_rmdir : string -> (unit, int) result = "ocamlcc_unix_rmdir"
external c_unlink : string -> (unit, int) result = "ocamlcc_unix_unlink"
external c_openfile : string -> int -> int -> (int, int) result = "ocamlcc_unix_openfile"
external c_close : int -> (unit, int) result = "ocamlcc_unix_close"
external c_pipe : bool -> (int * int, int) result = "ocamlcc_unix_pipe"
external c_in_channel_of_descr : int -> in_channel = "caml_ml_open_descriptor_in"
external c_create_process :
  string -> string array -> int -> int -> int -> (int, int) result
  = "ocamlcc_unix_create_process"
external c_waitpid : int -> (int * (int * int), int) result = "ocamlcc_unix_waitpid"

let enoent_code = c_enoent ()

let error_of_errno e =
  if e = enoent_code then ENOENT else EUNKNOWNERR e

let errno_of_error = function
  | ENOENT -> enoent_code
  | EUNKNOWNERR e -> e

let error_message err = c_error_message (errno_of_error err)

let unwrap fn arg = function
  | Ok v -> v
  | Error e -> raise (Unix_error (error_of_errno e, fn, arg))

let kind_of_int = function
  | 0 -> S_REG
  | 1 -> S_DIR
  | 2 -> S_CHR
  | 3 -> S_BLK
  | 4 -> S_LNK
  | 5 -> S_FIFO
  | _ -> S_SOCK

let lstat path =
  { st_kind = kind_of_int (unwrap "lstat" path (c_lstat path)) }

let rmdir path = unwrap "rmdir" path (c_rmdir path)
let unlink path = unwrap "unlink" path (c_unlink path)

let flag_bit = function
  | O_RDONLY -> 1
  | O_WRONLY -> 2
  | O_RDWR -> 4
  | O_CREAT -> 8
  | O_TRUNC -> 16
  | O_APPEND -> 32
  | O_CLOEXEC -> 64

let openfile path flags perm =
  let mask = List.fold_left (fun acc f -> acc lor flag_bit f) 0 flags in
  unwrap "openfile" path (c_openfile path mask perm)

let close fd = unwrap "close" "" (c_close fd)

let pipe ?(cloexec = false) () =
  unwrap "pipe" "" (c_pipe cloexec)

let in_channel_of_descr fd = c_in_channel_of_descr fd

let create_process prog args fd_in fd_out fd_err =
  unwrap "create_process" prog (c_create_process prog args fd_in fd_out fd_err)

let waitpid _flags pid =
  let wpid, (kind, code) = unwrap "waitpid" "" (c_waitpid pid) in
  let status =
    match kind with
    | 0 -> WEXITED code
    | 1 -> WSIGNALED code
    | _ -> WSTOPPED code
  in
  (wpid, status)
