(** Independent POSIX oracle for Ptime tests. Do not use the crunch adapter's
    Ptime-based calendar conversion to test Ptime itself. *)
type tm = {
  tm_sec : int; tm_min : int; tm_hour : int; tm_mday : int;
  tm_mon : int; tm_year : int; tm_wday : int; tm_yday : int; tm_isdst : bool;
}
external gmtime_result : float -> tm option = "ocpkg_test_gmtime"
let gmtime value = match gmtime_result value with
  | Some tm -> tm
  | None -> invalid_arg "libc gmtime rejected the timestamp"
