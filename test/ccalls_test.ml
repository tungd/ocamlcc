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
    ("ocamlcc_print_string_val", 1, false, false);
    ("ocamlcc_print_endline_val", 1, false, false);
    ("ocamlcc_prerr_string_val", 1, false, false);
    ("ocamlcc_exit_val", 1, false, false);
    ("ocamlcc_pipe", 0, false, false);
    ("ocamlcc_fd_read", 4, false, false);
    ("ocamlcc_fd_write", 4, false, false);
    ("ocamlcc_fd_close", 1, false, false);
    ("ocamlcc_weak_create", 1, true, false);
    ("ocamlcc_weak_length", 1, false, false);
    ("ocamlcc_weak_get", 2, true, false);
    ("ocamlcc_weak_get_copy", 2, true, false);
    ("ocamlcc_weak_set", 3, true, false);
    ("ocamlcc_weak_check", 2, true, false);
    ("ocamlcc_fiber_create", 1, false, false);
    ("ocamlcc_fiber_spawn", 1, false, false);
    ("ocamlcc_fiber_is_done", 1, false, false);
    ("ocamlcc_fiber_yield", 1, true, true);
    ("ocamlcc_fiber_suspend", 1, true, true);
    ("ocamlcc_fiber_sleep_ms", 1, true, true);
    ("ocamlcc_fiber_fd_wait_read", 1, true, true);
    ("ocamlcc_fiber_fd_wait_write", 1, true, true);
    ("ocamlcc_fiber_resume", 2, true, true);
    ("ocamlcc_fiber_await", 1, true, true);
    ("ocamlcc_fiber_run_all", 0, false, true);
    ("caml_fresh_oo_id", 1, false, false);
    ("caml_equal", 2, false, false);
    ("caml_notequal", 2, false, false);
    ("caml_compare", 2, true, false);
    ("caml_lessthan", 2, true, false);
    ("caml_lessequal", 2, true, false);
    ("caml_greaterthan", 2, true, false);
    ("caml_greaterequal", 2, true, false);
    ("caml_hash", 4, false, false);
    ("caml_blit_bytes", 5, true, false);
    ("caml_blit_string", 5, true, false);
    ("caml_fill_bytes", 4, true, false);
    ("caml_string_equal", 2, false, false);
    ("caml_bytes_equal", 2, false, false);
    ("caml_string_compare", 2, false, false);
    ("caml_bytes_compare", 2, false, false) ]

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
  if Ccalls.is_known "ocamlcc_weak_get" && not (Ccalls.is_known "my_user_ffi")
  then Printf.printf "is_known: PASS\n"
  else begin
    Printf.printf "is_known: FAIL\n";
    incr failures
  end;
  exit (if !failures = 0 then 0 else 1)
