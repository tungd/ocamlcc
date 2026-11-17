open Bigarray
let () =
  let a = Array2.create int c_layout 2 3 in
  assert (Array2.dim1 a = 2 && Array2.dim2 a = 3);
  a.{1,2} <- 42;
  assert (a.{1,2} = 42);
  assert (try ignore a.{2,0}; false with Invalid_argument _ -> true);
  let f = Array2.create float64 fortran_layout 2 3 in
  f.{2,3} <- 1.25;
  assert (f.{2,3} = 1.25);
  assert (try ignore f.{0,1}; false with Invalid_argument _ -> true);
  print_endline "bigarray: typed access, layouts, dimensions, bounds"
