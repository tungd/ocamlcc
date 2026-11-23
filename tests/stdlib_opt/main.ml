let[@inline never] via_map f v = Option.map f v
let[@inline never] via_bind r f = Result.bind r f
let[@inline never] via_fold f init xs = List.fold_left f init xs
let[@inline never] read32 bytes offset = Int32.to_int (Bytes.get_int32_le bytes offset)
let[@inline never] read64 bytes offset = Int64.to_int (Bytes.get_int64_le bytes offset)

let expect_bounds_error read bytes offset =
  match read bytes offset with
  | _ -> failwith "expected Invalid_argument"
  | exception Invalid_argument message -> assert (message = "index out of bounds")

let () =
  assert (via_map succ (Some 41) = Some 42);
  assert (via_bind (Ok 6) (fun n -> Ok (n * 7)) = Ok 42);
  assert (via_fold ( + ) 0 [10; 15; 17] = 42);
  let fiber = Fiber.create (fun n ->
    match via_map Fiber.suspend (Some n) with
    | None -> assert false
    | Some n -> n + 1)
  in
  assert (Fiber.resume fiber 17 = 17);
  assert (Fiber.resume fiber 41 = 42);
  let bytes = Bytes.make 17 '\x00' in
  Bytes.set_int32_le bytes 1 Int32.min_int;
  Bytes.set_int64_le bytes 5 0x7fff_ffff_ffff_ffffL;
  assert (read32 bytes 1 = -2_147_483_648);
  assert (read64 bytes 5 = -1);
  expect_bounds_error read32 bytes (-1);
  expect_bounds_error read64 bytes 10;
  expect_bounds_error read64 bytes max_int;
  expect_bounds_error read64 (Bytes.make 7 '\x00') 0
