(* C-call ABI registry contract test.

   Every C external the stdlib binds must be registered in [Ccalls] with the
   ABI its runtime implementation actually has (arities from the
   [external] declarations in [stdlib/]; [raises]/[yields] from
   [runtime/arc.c] / [runtime/fiber.c]). Unknown user externals must get the
   conservative default: [raises = true] so [TryWith] unwinds correctly even
   if the function never raises, [yields = false]. *)

let check_abi name argc raises yields =
  match Ccalls.find_opt name with
  | None ->
      Printf.printf "%s: FAIL not registered\n" name;
      false
  | Some abi ->
      if abi.Ccalls.argc = argc && abi.Ccalls.raises = raises
         && abi.Ccalls.yields = yields
      then begin
        Printf.printf "%s: registered\n" name;
        true
      end
      else begin
        Printf.printf "%s: FAIL got {argc=%d; raises=%b; yields=%b} expected {argc=%d; raises=%b; yields=%b}\n"
          name abi.Ccalls.argc abi.Ccalls.raises abi.Ccalls.yields argc raises
          yields;
        false
      end

(* (name, argc, raises, yields) for every external bound in [stdlib/]. *)
let stdlib_abis =
  [ ("ocamlcc_print_int_val", 1, false, false);
    ("ocamlcc_print_char_val", 1, false, false);
    ("ocamlcc_print_float_val", 1, false, false);
    ("ocamlcc_print_string_val", 1, false, false);
    ("ocamlcc_print_endline_val", 1, false, false);
    ("ocamlcc_prerr_string_val", 1, false, false);
    ("ocamlcc_exit_val", 1, false, false);
    ("ocamlcc_sys_is_win32", 1, false, false);
    ("ocamlcc_set_at_exit_fn", 1, false, false);
    ("ocamlcc_pipe", 0, true, false);
    ("ocamlcc_fd_read", 4, true, false);
    ("ocamlcc_fd_write", 4, true, false);
    ("ocamlcc_fd_close", 1, false, false);
    ("ocamlcc_weak_create", 1, true, false);
    ("ocamlcc_weak_length", 1, false, false);
    ("ocamlcc_weak_get", 2, true, false);
    ("ocamlcc_weak_get_copy", 2, true, false);
    ("ocamlcc_weak_set", 3, true, false);
    ("ocamlcc_weak_check", 2, true, false);
    ("ocamlcc_fiber_create", 1, false, false);
    ("ocamlcc_fiber_is_done", 1, false, false);
    ("ocamlcc_fiber_suspend", 1, true, true);
    ("ocamlcc_fiber_resume", 2, true, true);
    ("ocamlcc_fiber_is_main", 1, false, false);
    ("ocamlcc_fiber_can_yield", 1, true, false);
    ("ocamlcc_fiber_sched_get", 1, false, false);
    ("ocamlcc_fiber_sched_set", 1, false, false);
    ("ocamlcc_monotonic_ns", 1, false, false);
    ("ocamlcc_poller_watch", 3, true, false);
    ("ocamlcc_poller_unwatch_waiter", 3, false, false);
    ("ocamlcc_poller_wait", 2, false, false);
    ("caml_fresh_oo_id", 1, false, false);
    ("caml_equal", 2, true, false);
    ("caml_notequal", 2, true, false);
    ("caml_compare", 2, true, false);
    ("caml_lessthan", 2, true, false);
    ("caml_lessequal", 2, true, false);
    ("caml_greaterthan", 2, true, false);
    ("caml_greaterequal", 2, true, false);
    ("caml_hash", 4, false, false);
    ("caml_alloc_dummy", 1, false, false);
    ("caml_alloc_dummy_float", 1, false, false);
    ("caml_alloc_dummy_lazy", 1, false, false);
    ("caml_update_dummy", 2, false, false);
    ("caml_update_dummy_lazy", 2, false, false);
    ("caml_format_float", 2, false, false);
    ("caml_float_of_string", 1, true, false);
    ("caml_int32_to_float", 1, false, false);
    ("caml_int32_of_float", 1, false, false);
    ("caml_int32_bits_of_float", 1, false, false);
    ("caml_int32_float_of_bits", 1, false, false);
    ("caml_int64_to_float", 1, false, false);
    ("caml_int64_of_float", 1, false, false);
    ("caml_int64_bits_of_float", 1, false, false);
    ("caml_int64_float_of_bits", 1, false, false);
    ("caml_nativeint_to_float", 1, false, false);
    ("caml_nativeint_of_float", 1, false, false);
    ("caml_sqrt_float", 1, false, false);
    ("caml_floor_float", 1, false, false);
    ("caml_ceil_float", 1, false, false);
    ("caml_fmod_float", 2, false, false);
    ("caml_copysign_float", 2, false, false);
    ("caml_classify_float", 1, false, false);
    (* compiler-libs.common primitives *)
    ("caml_sys_get_stdlib_dirs", 1, false, false);
    ("caml_sys_time_include_children", 1, false, false);
    ("caml_terminfo_rows", 1, true, false);
    ("caml_zstd_initialize", 1, false, false) ]

let () =
  let failures = ref 0 in
  List.iter
    (fun (name, argc, raises, yields) ->
      if not (check_abi name argc raises yields) then incr failures)
    stdlib_abis;
  (* Conservative default for unknown user C externals. *)
  let unknown = Ccalls.find "my_user_ffi" in
  if unknown.Ccalls.raises && not unknown.Ccalls.yields then
    Printf.printf "unknown external default: PASS\n"
  else begin
    Printf.printf "unknown external default: FAIL got {raises=%b; yields=%b}\n"
      unknown.Ccalls.raises unknown.Ccalls.yields;
    incr failures
  end;
  let imm_ok =
    Ccalls.returns_imm "caml_equal"
    && Ccalls.returns_imm "caml_compare"
    && not (Ccalls.returns_imm "caml_sys_get_stdlib_dirs")
    && Ccalls.returns_imm "ocamlcc_set_at_exit_fn"
    && Ccalls.returns_imm "ocamlcc_sys_is_win32"
    && Ccalls.returns_imm "caml_zstd_initialize"
    && Ccalls.returns_imm "caml_terminfo_rows"
    && Ccalls.returns_imm "caml_lessthan"
    && Ccalls.returns_imm "caml_greaterequal"
    && not (Ccalls.returns_imm "caml_sys_time_include_children")
  in
  if imm_ok then Printf.printf "imm ccalls: PASS\n"
  else begin
    Printf.printf "imm ccalls: FAIL\n";
    incr failures
  end;
  if Ccalls.is_known "ocamlcc_weak_get" && not (Ccalls.is_known "my_user_ffi")
  then Printf.printf "is_known: PASS\n"
  else begin
    Printf.printf "is_known: FAIL\n";
    incr failures
  end;
  exit (if !failures = 0 then 0 else 1)
