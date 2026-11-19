open Bigarray

type vector = (float, float64_elt, c_layout) Array1.t
let scale (src : vector) (dst : vector) factor =
  for i = 0 to Array1.dim src - 1 do
    let cell = src.{i} in
    let product = cell *. factor in
    dst.{i} <- product
  done

type column = (float, float64_elt, fortran_layout) Array1.t
let scale_column (src : column) (dst : column) i j factor =
  dst.{j} <- src.{i} *. factor

let scale_with (src : vector) (dst : vector) factor =
  let cell = src.{0} in
  let product = cell *. factor () in
  dst.{0} <- product

let scale_and_capture (src : vector) (dst : vector) factor =
  let product = if factor > 0. then src.{0} *. factor else src.{0} in
  dst.{0} <- product;
  product, (fun () -> product)

let conditional_store (src : vector) (dst : vector) take_load i fallback =
  dst.{0} <- (if take_load then src.{i} *. 2. else fallback ())

let divide_in_place (a : vector) i divisor =
  let biased = (a.{i} +. 1.) -. 2. in
  a.{i} <- biased /. divisor

let add_single (a : (float, float32_elt, fortran_layout) Array1.t) i delta =
  a.{i} <- a.{i} +. delta

type integers = (int64, int64_elt, fortran_layout) Array1.t

let add_integer (src : integers) (dst : integers) i j delta =
  let value = src.{i} in
  dst.{j} <- Int64.add value delta

let store_and_capture_integer (a : integers) =
  let value = Int64.add a.{1} 1L in
  a.{2} <- value;
  value, (fun () -> value)

let add_int32 (a : (int32, int32_elt, fortran_layout) Array1.t) i j delta =
  let value = a.{i} in
  a.{j} <- Int32.add value delta

let conditional_int32 (a : (int32, int32_elt, fortran_layout) Array1.t)
    take_load i fallback =
  a.{2} <- (if take_load then Int32.add a.{i} 1l else fallback ())

let high_bits (a : integers) =
  let sign = Int64.shift_right_logical a.{2} 63 in
  a.{3} <- Int64.logxor sign (Int64.shift_left 1L 63)

let div_rem_int32 (a : (int32, int32_elt, fortran_layout) Array1.t) i divisor =
  let x = a.{i} in
  let quotient = Int32.div x divisor in
  a.{i} <- Int32.add quotient (Int32.rem x divisor)

let compare_integer (a : integers) i pivot =
  let value = Int64.add a.{i} 1L in
  if compare value pivot < 0 then -1 else if value = pivot then 0 else 1

let convert_through_native (a : integers) i =
  let narrow = Int64.to_int32 a.{i} in
  let native = Nativeint.of_int32 narrow in
  a.{i} <- Int64.of_nativeint native

let round_trip_ocaml_int (a : integers) i =
  a.{i} <- Int64.of_int (Int64.to_int a.{i})

type int32_choice = Literal of int32 | Load of int | Increment | Minimum

let match_int32 (a : (int32, int32_elt, fortran_layout) Array1.t) choice =
  let value = match choice with
    | Literal v -> v
    | Load i -> a.{i}
    | Increment -> Int32.add a.{1} 1l
    | Minimum -> Int32.min_int
  in
  a.{2} <- value

let match_default_int32 (a : (int32, int32_elt, fortran_layout) Array1.t) choice i =
  a.{2} <- (match choice with
    | 0 -> 0l
    | 1 -> -11l
    | 2 -> Int32.min_int
    | _ -> Int32.add a.{i} 1l)

let add_nativeint (a : (nativeint, nativeint_elt, fortran_layout) Array1.t) i j delta =
  let value = a.{i} in
  a.{j} <- Nativeint.add value delta

let () =
  let values = Array1.of_array float64 c_layout [|1.; 2.; 3.; 4.|] in
  let src = Array1.sub values 0 3 and dst = Array1.sub values 1 3 in
  scale src dst 2.;
  assert (values.{2} = 4. && values.{3} = 8.);
  let short = Array1.sub values 0 1 in
  assert (try scale dst short 3.; false with Invalid_argument _ -> true);
  assert (values.{0} = 6. && values.{1} = 2.);
  scale_with src short (fun () -> values.{0} <- 40.; Gc.full_major (); 0.5);
  assert (values.{0} = 3.);
  let result, capture = scale_and_capture src short 2. in
  Gc.full_major ();
  assert (result = 6. && values.{0} = 6. && capture () == result);
  conditional_store src short false (-1) (fun () -> Gc.full_major (); -0.);
  assert (Int64.bits_of_float values.{0} = Int64.bits_of_float (-0.));
  assert (try
    conditional_store src short true (-1) (fun () -> assert false);
    false
  with Invalid_argument _ -> true);
  assert (Int64.bits_of_float values.{0} = Int64.bits_of_float (-0.));
  conditional_store src short true 1 (fun () -> assert false);
  assert (values.{0} = 4.);
  divide_in_place values 0 (-0.);
  assert (values.{0} = neg_infinity);
  let singles = Array1.of_array float32 fortran_layout [|16777216.; -0.; nan|] in
  add_single singles 1 1.;
  assert (singles.{1} = 16777216.);
  add_single singles 2 (-0.);
  assert (Int64.bits_of_float singles.{2} = Int64.bits_of_float (-0.));
  add_single singles 3 1.;
  assert (Float.is_nan singles.{3});
  assert (try add_single singles 0 1.; false with Invalid_argument _ -> true);
  let integers = Array1.of_array int64 fortran_layout [|Int64.max_int; 7L; 11L|] in
  add_integer integers integers 1 2 1L;
  assert (integers.{2} = Int64.min_int);
  add_integer integers integers 2 3 Int64.min_int;
  assert (integers.{3} = 0L);
  assert (try add_integer integers integers 0 1 1L; false with Invalid_argument _ -> true);
  assert (integers.{1} = Int64.max_int);
  assert (try add_integer integers integers 1 4 1L; false with Invalid_argument _ -> true);
  let value, capture = store_and_capture_integer integers in
  Gc.full_major ();
  assert (value = Int64.min_int && integers.{2} = value && capture () == value);
  high_bits integers;
  assert (integers.{3} = Int64.succ Int64.min_int);
  assert (compare_integer integers 1 0L = -1);
  assert (compare_integer integers 2 (Int64.succ Int64.min_int) = 0);
  assert (compare_integer integers 3 Int64.min_int = 1);
  integers.{3} <- 0x1_ffff_ffffL;
  convert_through_native integers 3;
  assert (integers.{3} = -1L);
  round_trip_ocaml_int integers 2;
  assert (integers.{2} = 0L);
  let narrow = Array1.of_array int32 fortran_layout [|Int32.max_int; 7l|] in
  add_int32 narrow 1 2 1l;
  assert (Int32.to_int narrow.{2} = -2147483648);
  assert (try add_int32 narrow 0 1 1l; false with Invalid_argument _ -> true);
  assert (narrow.{1} = Int32.max_int);
  conditional_int32 narrow false 0 (fun () -> Gc.full_major (); -3l);
  assert (narrow.{2} = -3l);
  assert (try conditional_int32 narrow true 0 (fun () -> assert false);
    false with Invalid_argument _ -> true);
  assert (narrow.{2} = -3l);
  narrow.{1} <- -5l;
  div_rem_int32 narrow 1 3l;
  assert (narrow.{1} = -3l);
  narrow.{2} <- Int32.min_int;
  div_rem_int32 narrow 2 (-1l);
  assert (narrow.{2} = Int32.min_int);
  assert (try div_rem_int32 narrow 1 0l; false with Division_by_zero -> true);
  assert (narrow.{1} = -3l);
  match_int32 narrow (Literal (-7l));
  assert (narrow.{2} = -7l);
  match_int32 narrow Increment;
  assert (narrow.{2} = -2l);
  match_int32 narrow Minimum;
  assert (narrow.{2} = Int32.min_int);
  match_int32 narrow (Load 1);
  assert (narrow.{2} = -3l);
  assert (try match_int32 narrow (Load 0); false with Invalid_argument _ -> true);
  assert (narrow.{2} = -3l);
  match_default_int32 narrow 1 0;
  assert (narrow.{2} = -11l);
  match_default_int32 narrow 8 1;
  assert (narrow.{2} = -2l);
  assert (try match_default_int32 narrow 8 0; false with Invalid_argument _ -> true);
  assert (narrow.{2} = -2l);
  let native = Array1.of_array nativeint fortran_layout [|Nativeint.max_int; 7n|] in
  add_nativeint native 1 2 1n;
  assert (native.{2} = Nativeint.min_int);
  assert (try add_nativeint native 0 1 1n; false with Invalid_argument _ -> true);
  assert (native.{1} = Nativeint.max_int);
  let col = Array1.of_array float64 fortran_layout [|-0.; nan; infinity|] in
  scale_column col col 1 3 2.;
  assert (Int64.bits_of_float col.{3} = Int64.bits_of_float (-0.));
  scale_column col col 2 3 1.;
  assert (Float.is_nan col.{3});
  assert (try scale_column col col 0 1 1.; false with Invalid_argument _ -> true);
  assert (Int64.bits_of_float col.{1} = Int64.bits_of_float (-0.));
  let a = Array2.create int c_layout 2 3 in
  assert (Array2.dim1 a = 2 && Array2.dim2 a = 3);
  a.{1,2} <- 42;
  assert (a.{1,2} = 42);
  assert (try ignore a.{2,0}; false with Invalid_argument _ -> true);
  let f = Array2.create float64 fortran_layout 2 3 in
  f.{2,3} <- 1.25;
  assert (f.{2,3} = 1.25);
  assert (try ignore f.{0,1}; false with Invalid_argument _ -> true);
  let view =
    let owner = Array1.of_array int c_layout [|1; 2; 3; 4|] in
    let sub = Array1.sub owner 1 2 in
    sub.{0} <- 20;
    assert (owner.{1} = 20);
    sub
  in
  assert (view.{1} = 3);
  let other = Array1.of_array int c_layout [|20; 3|] in
  assert (compare view other = 0 && view = other);
  assert (Hashtbl.hash view = Hashtbl.hash other);
  let z = Array1.of_array complex64 c_layout [|{Complex.re = 1.5; im = -2.0}|] in
  assert (z.{0}.Complex.re = 1.5 && z.{0}.Complex.im = -2.0);
  print_endline "bigarray: typed access, layouts, dimensions, bounds"
