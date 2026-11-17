type node = { mutable next : node option; value : int }
let copy x flags = Marshal.from_string (Marshal.to_string x flags) 0
let test () =
  let shared = ref 42 in
  let a, b = copy (shared, shared) [] in
  assert (a == b);
  let a, b = copy (shared, shared) [Marshal.No_sharing] in
  assert (a != b && !a = !b);
  let node = {next = None; value = 7} in
  node.next <- Some node;
  let cycle = copy node [] in
  assert (match cycle.next with Some again -> again == cycle | None -> false);
  node.next <- None; cycle.next <- None;
  let deep = List.init 50000 Fun.id in
  assert (copy deep [] = deep);
  let filename = "marshal.dat" in
  let out = open_out_bin filename in
  Marshal.to_channel out ("channel", 17) [];
  Marshal.to_channel out [|1.; 2.|] [];
  close_out out;
  let input = open_in_bin filename in
  assert (Marshal.from_channel input = ("channel", 17));
  assert (Marshal.from_channel input = [|1.; 2.|]);
  assert (try ignore (Marshal.from_channel input); false with End_of_file -> true);
  close_in input;
  Sys.remove filename;
  assert (try ignore (Marshal.to_string max_int [Marshal.Compat_32]); false with Failure _ -> true);
  print_endline "marshal: sharing, cycles, no sharing, deep values, channels, Compat_32"
let () = try test () with e -> prerr_endline (Printexc.to_string e); exit 1
