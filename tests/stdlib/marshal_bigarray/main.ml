open Bigarray
let test () =
  let a = Array2.init int64 fortran_layout 2 3 (fun i j -> Int64.of_int (10*i+j)) in
  let b = (Marshal.from_string (Marshal.to_string a []) 0 : (int64, int64_elt, fortran_layout) Array2.t) in
  assert (a = b && b.{2,3} = 23L);
  let owner = Array1.of_array char c_layout [|'a'; 'b'; 'c'|] in
  let view = Array1.sub owner 1 2 in
  let copy = Marshal.from_string (Marshal.to_string view []) 0 in
  assert (copy = view && copy.{0} = 'b');
  print_endline "marshal: bigarray descriptors, layouts and view payloads"
let () = try test () with e -> prerr_endline (Printexc.to_string e); exit 1
