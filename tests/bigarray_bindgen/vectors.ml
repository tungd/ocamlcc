open Bigarray
type vector = (float, float64_elt, c_layout) Array1.t
type single_vector = (float, float32_elt, c_layout) Array1.t
type matrix = (float, float64_elt, c_layout) Array2.t
type cube = (float, float64_elt, c_layout) Array3.t
type generic = (float, float64_elt, c_layout) Genarray.t
let matrix rows cols = Array2.create float64 c_layout rows cols
let cube x y z = Array3.create float64 c_layout x y z
let as_genarray (a : cube) = genarray_of_array3 a
let generic_rank (a : generic) = Genarray.num_dims a
let plane (a : generic) i = array2_of_genarray (Genarray.slice_left a [|i|])
let row m i = Array2.slice_left m i
let create n = Array1.create float64 c_layout n
let sub a pos len = Array1.sub a pos len
let scale_words (src : vector) (dst : vector) factor n =
  let before = Gc.minor_words () in
  for i = 0 to n - 1 do
    let cell = src.{i} in
    let product = cell *. factor in
    let shifted = product +. 1. in
    dst.{i} <- (shifted -. 2.) /. 2.
  done;
  Gc.minor_words () -. before

let conditional_scale_words (src : vector) (dst : vector) factor n =
  let before = Gc.minor_words () in
  for i = 0 to n - 1 do
    let product = if i land 1 = 0 then src.{i} *. factor else src.{i} *. 2. in
    dst.{i} <- product
  done;
  Gc.minor_words () -. before

let single_words (a : single_vector) n =
  let before = Gc.minor_words () in
  for i = 0 to n - 1 do
    let x = a.{i} in
    a.{i} <- (x +. 1.) -. x
  done;
  Gc.minor_words () -. before

let create_singles n = Array1.create float32 c_layout n
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
