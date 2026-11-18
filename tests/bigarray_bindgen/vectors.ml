open Bigarray
type vector = (float, float64_elt, c_layout) Array1.t
type matrix = (float, float64_elt, c_layout) Array2.t
let matrix rows cols = Array2.create float64 c_layout rows cols
let row m i = Array2.slice_left m i
let create n = Array1.create float64 c_layout n
let sub a pos len = Array1.sub a pos len
let scale_words (src : vector) (dst : vector) factor n =
  let before = Gc.minor_words () in
  for i = 0 to n - 1 do dst.{i} <- src.{i} *. factor done;
  Gc.minor_words () -. before
let saved : vector option ref = ref None
let save v = saved := Some v
let write_saved x = match !saved with Some v -> v.{0} <- x | None -> assert false
let clear () = saved := None
type node = { mutable link : node option; buffer : vector }
let leave_cycle buffer =
  let node = { link = None; buffer } in
  node.link <- Some node
external collect_cycles : unit -> int = "ocamlcc_arc_collect"
let collect () = collect_cycles ()
let fortran () = Array1.create float64 fortran_layout 1
let singles = Array1.create float32 c_layout 1
external live_count : unit -> int = "ocamlcc_arc_live"
let live () = live_count ()
