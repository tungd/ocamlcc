type t = Release | Debug

let to_string = function
  | Release -> "release"
  | Debug -> "debug"

let optimize = function
  | Release -> true
  | Debug -> false

let cflags ?debug_info = function
  | Release ->
      let debug = match debug_info with Some b -> b | None -> false in
      if debug then ["-O2"; "-g"] else ["-O2"]
  | Debug ->
      let debug = match debug_info with Some b -> b | None -> true in
      if debug then ["-O0"; "-g"] else ["-O0"]
