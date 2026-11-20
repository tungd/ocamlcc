let[@inline never] via_map f v = Option.map f v
let[@inline never] via_bind r f = Result.bind r f
let[@inline never] via_fold f init xs = List.fold_left f init xs

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
  assert (Fiber.resume fiber 41 = 42)
