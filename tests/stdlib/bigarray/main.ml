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
  let product = src.{0} *. factor in
  dst.{0} <- product;
  product, (fun () -> product)

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
