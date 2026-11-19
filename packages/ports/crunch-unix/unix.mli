(** The Unix surface used by crunch, not a replacement for the Unix library.
    Directory enumeration is a snapshot; OS errors raise [Sys_error]. *)
type dir_handle
val opendir : string -> dir_handle
val readdir : dir_handle -> string
val closedir : dir_handle -> unit
val chdir : string -> unit
val realpath : string -> string
type stats = { st_size : int }
val stat : string -> stats
type tm = {
  tm_sec : int; tm_min : int; tm_hour : int; tm_mday : int;
  tm_mon : int; tm_year : int; tm_wday : int; tm_yday : int; tm_isdst : bool;
}
val gmtime : float -> tm
val gettimeofday : unit -> float
