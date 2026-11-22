(**************************************************************************)
(*                                                                        *)
(*   Pure OCaml Callback named-value registry, Backtrace stubs, and Sys   *)
(*   configuration / warnings helpers (--nopervasives).                   *)
(*                                                                        *)
(**************************************************************************)

external raise : exn -> 'a = "%raise"
external ( = ) : 'a -> 'a -> bool = "%equal"
external ( <> ) : 'a -> 'a -> bool = "%notequal"
external ( > ) : 'a -> 'a -> bool = "%greaterthan"
external cast : 'a -> 'b = "%identity"

external array_length : 'a array -> int = "%array_length"
external array_get : 'a array -> int -> 'a = "%array_unsafe_get"
external array_make : int -> 'a -> 'a array = "caml_array_make"

type obj_t
type mutex_t

external mutex_new : unit -> mutex_t = "caml_ml_mutex_new"
external mutex_lock : mutex_t -> unit = "caml_ml_mutex_lock"
external mutex_unlock : mutex_t -> unit = "caml_ml_mutex_unlock"

external set_at_exit_fn : obj_t -> unit = "ocamlcc_set_at_exit_fn"
external sys_is_win32 : unit -> bool = "ocamlcc_sys_is_win32"
external sys_argv : unit -> string array = "caml_sys_argv"
external sys_getenv_opt : string -> string option = "caml_sys_getenv_opt"

type 'a mref = { mutable contents : 'a }

(* ---- Callback named-value table ---- *)

let named_lock = mutex_new ()
let named_table : (string * obj_t) list mref = { contents = [] }

let rec replace_binding k v acc = function
  | [] -> (k, v) :: acc
  | (k0, v0) :: rest ->
      if k0 = k then
        let rec rev_prepend l r =
          match l with [] -> r | x :: xs -> rev_prepend xs (x :: r)
        in
        rev_prepend acc ((k, v) :: rest)
      else
        replace_binding k v ((k0, v0) :: acc) rest

let register_named_value (name : string) (v : 'a) =
  let ov : obj_t = cast v in
  mutex_lock named_lock;
  named_table.contents <- replace_binding name ov [] named_table.contents;
  mutex_unlock named_lock;
  if name = "Pervasives.do_at_exit" then set_at_exit_fn ov

let lookup_named_value (name : string) : 'a option =
  mutex_lock named_lock;
  let rec find = function
    | [] -> None
    | (k, v) :: rest -> if k = name then Some (cast v) else find rest
  in
  let r = find named_table.contents in
  mutex_unlock named_lock;
  r

external install_named_value_lookup : (string -> obj_t option) -> unit =
  "ocamlcc_caml_install_lookup"

let () = install_named_value_lookup lookup_named_value

(* ---- Backtraces (empty stubs) ---- *)

let backtrace_enabled : bool mref = { contents = false }

let record_backtrace (b : bool) = backtrace_enabled.contents <- b
let backtrace_status () = backtrace_enabled.contents
let restore_raw_backtrace (_exn : exn) (_bt : 'a) = ()
let get_exception_raw_backtrace () : 'a = cast (array_make 0 0)
let get_current_callstack (_max_frames : int) : 'a = cast (array_make 0 0)
let ml_debug_info_status () = 0
let raw_backtrace_slot (_bt : 'a) (_i : int) : 'b =
  raise (Invalid_argument "index out of bounds")
let raw_backtrace_next_slot (_slot : 'a) : 'a option = None
let convert_raw_backtrace (_bt : 'a) : 'b array = cast (array_make 0 0)
let convert_raw_backtrace_slot (_slot : 'a) : 'b =
  raise (Failure "convert_raw_backtrace_slot: unsupported")

(* ---- Sys configuration & warnings ---- *)

let warnings_enabled : bool mref = { contents = false }

let get_config () =
  ((if sys_is_win32 () then "Win32" else "Unix"), 64, false)

let get_executable_name () =
  let argv = sys_argv () in
  if array_length argv > 0 then array_get argv 0 else ""

let get_proc_self_exe () : string option = None
let io_buffer_size () = 65536
let runtime_variant () = ""
let runtime_parameters () = ""
let convert_signal_number (s : int) = s
let rev_convert_signal_number (s : int) = s
let enable_runtime_warnings (b : bool) = warnings_enabled.contents <- b
let runtime_warnings_enabled () = warnings_enabled.contents

let temp_dir_name () =
  match sys_getenv_opt "TMPDIR" with
  | Some t -> if t <> "" then t else "/tmp"
  | None -> "/tmp"
