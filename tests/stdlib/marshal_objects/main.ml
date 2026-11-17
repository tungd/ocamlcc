let test () =
  let a = Dynarray.of_list [42] in
  let b = Marshal.from_string (Marshal.to_string a []) 0 in
  assert (Dynarray.to_list b = [42]);
  assert (Stdlib.compare a b <> 0 && a <> b);
  assert (Float.Array.concat [] = Float.Array.create 0);
  assert (Float.Array.of_list [] = Float.Array.create 0);
  print_endline "marshal: fresh object identities and empty arrays"
let () = try test () with e -> prerr_endline (Printexc.to_string e); exit 1
