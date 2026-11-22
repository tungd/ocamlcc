let wide () = Z.shift_left Z.one 130

let () =
  let square = Z.mul (wide ()) (wide ()) in
  let modulus = Z.pred (Z.shift_left Z.one 127) in
  let residue = Z.powm_sec (wide ()) (Z.of_int 41) modulus in
  assert (Z.equal square (Z.shift_left Z.one 260));
  assert (Z.equal residue (Z.shift_left Z.one 123));
  Printf.printf "square=%s\npowm_sec=%s\n" (Z.to_string square) (Z.to_string residue);

  let alias = Z.shift_left (wide ()) 0 in
  let quotient, remainder = Z.div_rem (wide ()) (Z.of_int 3) in
  assert (Z.equal alias (wide ()));
  assert (Z.equal remainder Z.one);
  assert (Z.equal (Z.succ (Z.mul quotient (Z.of_int 3))) alias);

  let negative = Z.neg alias in
  let reread = Z.of_bits (Z.to_bits alias) in
  assert (not (alias == reread));
  assert (Stdlib.compare negative Z.zero < 0);
  assert (Stdlib.compare Z.zero negative > 0);
  assert (Stdlib.compare alias reread = 0);
  assert (Hashtbl.hash alias = Hashtbl.hash reread);
  assert (Obj.is_int (Obj.repr (Z.sub alias reread)));
  assert (match Z.to_int alias with exception Z.Overflow -> true | _ -> false);
  assert (match Z.div alias Z.zero with exception Division_by_zero -> true | _ -> false);
  print_endline "Zarith ownership, comparison, hashing, and exceptions: PASS"
