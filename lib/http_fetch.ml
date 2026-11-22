external curl_init : unit -> string = "ocpkg_curl_init"
external curl_download : string -> string -> string = "ocpkg_curl_download"

let initialization = lazy (curl_init ())

let download ~url ~destination =
  match Lazy.force initialization with
  | "" ->
      (match curl_download url destination with
       | "" -> Ok ()
       | error -> Error ("download failed: " ^ error))
  | error -> Error ("cannot initialize libcurl: " ^ error)
