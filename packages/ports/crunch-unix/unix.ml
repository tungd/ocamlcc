type dir_handle = { mutable remaining : string list option }

let opendir path = { remaining = Some (Array.to_list (Sys.readdir path)) }
let readdir handle =
  match handle.remaining with
  | None -> raise (Sys_error "readdir: closed directory")
  | Some [] -> raise End_of_file
  | Some (name :: rest) -> handle.remaining <- Some rest; name
let closedir handle = handle.remaining <- None
let chdir = Sys.chdir

external realpath_result : string -> (string, string) result = "ocpkg_realpath"
external file_size : string -> (int, string) result = "ocpkg_file_size"
external time_result : unit -> (float, string) result = "ocpkg_time"

let system_result = function Ok value -> value | Error message -> raise (Sys_error message)
let realpath path = system_result (realpath_result path)
type stats = { st_size : int }
let stat path = { st_size = system_result (file_size path) }
let gettimeofday () = system_result (time_result ())

type tm = {
  tm_sec : int; tm_min : int; tm_hour : int; tm_mday : int;
  tm_mon : int; tm_year : int; tm_wday : int; tm_yday : int; tm_isdst : bool;
}
let gmtime seconds =
  match Ptime.of_float_s seconds with
  | None -> raise (Sys_error "gmtime: timestamp outside Ptime range")
  | Some time ->
      let (year, month, day), ((hour, minute, second), _) = Ptime.to_date_time time in
      let days, _ = Ptime.Span.to_d_ps (Ptime.to_span time) in
      let jan1 = match Ptime.of_date_time ((year, 1, 1), ((0, 0, 0), 0)) with
        | Some value -> value
        | None -> assert false
      in
      let first_day, _ = Ptime.Span.to_d_ps (Ptime.to_span jan1) in
      { tm_sec = second; tm_min = minute; tm_hour = hour; tm_mday = day;
        tm_mon = month - 1; tm_year = year - 1900; tm_wday = ((days + 4) mod 7 + 7) mod 7;
        tm_yday = days - first_day; tm_isdst = false }
