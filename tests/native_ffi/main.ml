external double : float -> float = "ffi_double_boxed" "ffi_double" [@@unboxed] [@@noalloc]

external mixed : (int [@untagged]) -> (float [@unboxed]) ->
                 (int32 [@unboxed]) -> (int64 [@unboxed]) -> (nativeint [@unboxed]) ->
                 (int64 [@unboxed])
  = "ffi_mixed_boxed" "ffi_mixed" [@@noalloc]

external step : int -> int = "ffi_step_boxed" "ffi_step" [@@untagged] [@@noalloc]

external digits : int -> int -> int -> int -> int -> int -> int -> int ->
                  (int [@untagged]) -> (int [@untagged])
  = "ffi_digits_bytecode" "ffi_digits_native" [@@noalloc]

external null_value : unit -> int option = "ffi_null_value" [@@noalloc]
external observe : 'a -> unit = "ffi_observe" [@@noalloc]

let[@inline never] release_unknown value = observe value

type magnitude = Magnitude of float [@@unboxed]

let[@inline never] opaque x = x

let () =
  let indirect = opaque double in
  let (Magnitude x) = Magnitude (indirect 2.25) in
  assert (x = 4.5);
  assert (step (-40) = -43);
  assert (digits 1 2 3 4 5 6 7 8 9 = 123456789);
  let partial = opaque (mixed (-12) 2.0 (-300l)) in
  assert (partial 4000000000L (-500n) = 3999999194L);
  release_unknown (null_value ());
  release_unknown (-17);
  release_unknown (Some 17);
  print_endline "native FFI: PASS"
