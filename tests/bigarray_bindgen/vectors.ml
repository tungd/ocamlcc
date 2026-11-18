open Bigarray
type vector = (float, float64_elt, c_layout) Array1.t
let create n = Array1.create float64 c_layout n
let sub a pos len = Array1.sub a pos len
let fortran () = Array1.create float64 fortran_layout 1
let singles = Array1.create float32 c_layout 1
external live_count : unit -> int = "ocamlcc_arc_live"
let live () = live_count ()
