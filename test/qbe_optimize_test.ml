open Qbe_il

let () =
  let raw = Temp "raw" and shifted = Temp "shifted" in
  let tagged = Temp "tagged" and test = Temp "test" in
  let cmp = Cmp (Slt, Long, raw, Temp "x", Temp "y") in
  let start =
    { label = "start";
      insts = [cmp; Binop (Shl, Long, shifted, raw, Int 1L);
               Binop (Add, Long, tagged, shifted, Int 1L);
               Cmp (Ne, Long, test, tagged, Int 1L)];
      term = Br (test, "yes", "no") }
  in
  let finish label value = { label; insts = []; term = Ret (Some (Int value)) } in
  let tail = [finish "yes" 1L; finish "no" 0L] in
  let names = { Names.temp_counter = 0; label_counter = 0 } in
  let blocks, names_after = optimize_blocks names (start :: tail) in
  assert (names_after = names);
  assert (blocks = { start with insts = [cmp]; term = Br (raw, "yes", "no") } :: tail)
