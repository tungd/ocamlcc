let[@inline never] width data = Bytes.length data
let[@inline never] forward data = width data

let rec left data n =
  if n = 0 then forward data else right data (n - 1)
and right data n =
  if n = 0 then forward data + 1 else left data (n - 1)

let use data n =
  let result = left data n in
  let answer = result + forward data in
  answer + Char.code (Bytes.get data 0)

let run weak =
  let data = Bytes.make 17 'x' in
  Weak.set weak 0 (Some data);
  assert (use data 100_000 = 154);
  assert (use data 100_001 = 155);
  assert (left data 2 = 17)

let () =
  let weak = Weak.create 1 in
  run weak;
  Gc.full_major ();
  assert (not (Weak.check weak 0));
  print_endline "recursive borrowed calls: ok"
