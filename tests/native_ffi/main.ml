external double : float -> float = "ffi_double_boxed" "ffi_double" [@@unboxed] [@@noalloc]

external mixed : (int [@untagged]) -> (float [@unboxed]) ->
                 (int32 [@unboxed]) -> (int64 [@unboxed]) -> (nativeint [@unboxed]) ->
                 (int64 [@unboxed])
  = "ffi_mixed_boxed" "ffi_mixed" [@@noalloc]

external step : int -> int = "ffi_step_boxed" "ffi_step" [@@untagged] [@@noalloc]

type magnitude = Magnitude of float [@@unboxed]

let[@inline never] opaque x = x

let () =
  let indirect = opaque double in
  let (Magnitude x) = Magnitude (indirect 2.25) in
  assert (x = 4.5);
  assert (step (-40) = -43);
  let partial = opaque (mixed (-12) 2.0 (-300l)) in
  assert (partial 4000000000L (-500n) = 3999999194L);
  print_endline "native FFI: PASS"
