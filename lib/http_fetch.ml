external curl_download : string -> string -> string = "ocpkg_curl_download"

let download ~url ~destination =
  match curl_download url destination with
  | "" -> Ok ()
  | error -> Error ("download failed: " ^ error)
