val read_file : string -> string
val write_file : string -> string -> unit

val write_atomic : string -> string -> unit
(** Publish a complete file by renaming a temporary file in the same directory. *)

val write_if_changed : string -> string -> unit
(** Leave an identical regular file untouched. Publish new contents atomically,
    preserving the permissions of an existing regular file. *)

val mkdir_p : string -> unit
val rm_rf : string -> unit
val find_in_path : string -> string option

val run_cmd :
  verbose:bool -> ?stdout_file:string -> string -> string list -> (unit, string) result
(** Run a command directly. Capture stderr for diagnostics on failure. *)

val capture_cmd : string -> string list -> (string, string) result
(** Return trimmed stdout from a successful command. *)

module Result_syntax = Result.Syntax
module Option_syntax = Option.Syntax
