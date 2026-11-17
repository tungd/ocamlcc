let test () =
  let value = ([|min_int; max_int; -12345; 42|], "a\000b", [|1.5; -0.0|], (123l, -456L, 789n)) in
  let bytes = Marshal.to_bytes value [] in
  assert (Marshal.from_bytes bytes 0 = value);
  assert (Marshal.total_size bytes 0 = Bytes.length bytes);
  let buffer = Bytes.make (Bytes.length bytes + 7) 'x' in
  let written = Marshal.to_buffer buffer 3 (Bytes.length bytes) value [] in
  assert (written = Bytes.length bytes && Marshal.from_bytes buffer 3 = value);
  assert (try ignore (Marshal.to_string (fun x -> x) []); false with Invalid_argument _ -> true);
  print_endline "marshal: core values, offsets, size, closure rejection"

let () = try test () with e -> prerr_endline (Printexc.to_string e); exit 1
