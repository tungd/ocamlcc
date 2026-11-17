(* C-call ABI registry: the single source of truth for every C external the
   compiler lowers to [Anf.Ccall].

   The ARC pass previously assumed every Ccall borrows all arguments,
   returns an owned value, never raises (unless the name was on a hardcoded
   list in [ce_may_raise_fn]) and never yields (unless on another hardcoded
   list in [is_yielding_ccall]); those lists drifted — e.g. [Weak.get_copy]
   was missed once, and [caml_blit_bytes]/[caml_fill_bytes] abort the
   process on out-of-bounds instead of raising [Invalid_argument]. Every
   ABI fact lives here now:

   - [raises]   — the C function stores a caught exception into
                  [ocamlcc_exn_slot]; call sites inside [TryWith] must be
                  wrapped in [CheckExn] so live values unwind.
   - [yields]   — the C function can suspend the current fiber; call sites
                  participate in the shadow-stack protocol.
   - [argc]     — the declared arity of the external; a known symbol called
                  with a different arity is a compile error.

   Unknown non-[caml_] externals (user C FFI) get a conservative default:
   [raises = true] so [TryWith] unwinds correctly even if the function never
   raises (the cost is one dead branch), and [yields = false] (a plain C
   function cannot suspend unless it calls into the fiber runtime). *)

type abi = {
  argc : int;      (* declared arity of the external *)
  raises : bool;   (* stores to [ocamlcc_exn_slot] on failure *)
  yields : bool;   (* can suspend the current fiber *)
}

let abi argc raises yields = { argc; raises; yields }

(* Arities match the [external] declarations in [stdlib/]; raises/yields
   match the runtime implementations in [runtime/arc.c] and
   [runtime/fiber.c]. *)
let table =
  [ (* printing / process *)
    ("ocamlcc_print_int_val", abi 1 false false);
    ("ocamlcc_print_char_val", abi 1 false false);
    ("ocamlcc_print_string_val", abi 1 false false);
    ("ocamlcc_print_endline_val", abi 1 false false);
    ("ocamlcc_prerr_string_val", abi 1 false false);
    ("ocamlcc_exit_val", abi 1 false false);
    (* fd / pipe *)
    ("ocamlcc_pipe", abi 0 true false);
    ("ocamlcc_fd_read", abi 4 true false);
    ("ocamlcc_fd_write", abi 4 true false);
    ("ocamlcc_fd_close", abi 1 false false);
    (* weak arrays *)
    ("ocamlcc_weak_create", abi 1 true false);
    ("ocamlcc_weak_length", abi 1 false false);
    ("ocamlcc_weak_get", abi 2 true false);
    ("ocamlcc_weak_get_copy", abi 2 true false);
    ("ocamlcc_weak_set", abi 3 true false);
    ("ocamlcc_weak_check", abi 2 true false);
    (* fibers *)
    ("ocamlcc_fiber_create", abi 1 false false);
    ("ocamlcc_fiber_spawn", abi 1 false false);
    ("ocamlcc_fiber_is_done", abi 1 false false);
    ("ocamlcc_fiber_yield", abi 1 true true);
    ("ocamlcc_fiber_suspend", abi 1 true true);
    ("ocamlcc_fiber_sleep_ms", abi 1 true true);
    ("ocamlcc_fiber_fd_wait_read", abi 1 true true);
    ("ocamlcc_fiber_fd_wait_write", abi 1 true true);
    ("ocamlcc_fiber_resume", abi 2 true true);
    ("ocamlcc_fiber_await", abi 1 true true);
    ("ocamlcc_fiber_run_all", abi 0 false true);
    (* structural comparison / hashing *)
    ("caml_fresh_oo_id", abi 1 false false);
    ("caml_equal", abi 2 false false);
    ("caml_notequal", abi 2 false false);
    ("caml_compare", abi 2 true false);
    ("caml_lessthan", abi 2 true false);
    ("caml_lessequal", abi 2 true false);
    ("caml_greaterthan", abi 2 true false);
    ("caml_greaterequal", abi 2 true false);
    ("caml_hash", abi 4 false false);
    (* bytes / strings *)
    ("caml_blit_bytes", abi 5 true false);
    ("caml_blit_string", abi 5 true false);
    ("caml_fill_bytes", abi 4 true false);
    ("caml_string_equal", abi 2 false false);
    ("caml_bytes_equal", abi 2 false false);
    ("caml_string_compare", abi 2 false false);
    ("caml_bytes_compare", abi 2 false false) ]

let find_opt name = List.assoc_opt name table

let find name =
  match find_opt name with
  | Some abi -> abi
  | None ->
      (* Unknown user externals: conservative default. *)
      { argc = 0; raises = true; yields = false }

let is_known name = List.mem_assoc name table
