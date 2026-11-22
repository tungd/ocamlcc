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
    ("ocamlcc_opaque_identity", abi 1 false false);
    ("ocamlcc_print_int_val", abi 1 false false);
    ("ocamlcc_print_char_val", abi 1 false false);
    ("ocamlcc_print_float_val", abi 1 false false);
    ("ocamlcc_print_string_val", abi 1 false false);
    ("ocamlcc_print_endline_val", abi 1 false false);
    ("ocamlcc_prerr_string_val", abi 1 false false);
    ("ocamlcc_exit_val", abi 1 false false);
    (* Bounds are checked in CamlinternalBulkOps. *)
    ("ocamlcc_bulk_blit_bytes", abi 5 false false);
    ("ocamlcc_bulk_fill_bytes", abi 4 false false);
    ("ocamlcc_bulk_array_sub", abi 3 false false);
    ("ocamlcc_bulk_array_blit", abi 5 false false);
    ("ocamlcc_bulk_array_fill", abi 4 false false);
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
    ("ocamlcc_fiber_is_done", abi 1 false false);
    ("ocamlcc_fiber_suspend", abi 1 true true);
    ("ocamlcc_fiber_resume", abi 2 true true);
    ("ocamlcc_fiber_is_main", abi 1 false false);
    ("ocamlcc_fiber_can_yield", abi 1 true false);
    ("ocamlcc_fiber_sched_get", abi 1 false false);
    ("ocamlcc_fiber_sched_set", abi 1 false false);
    (* Algebraic effects share the stackful coroutine and shadow-stack ABI. *)
    ("caml_alloc_stack", abi 3 false false);
    ("caml_continuation_use_noexc", abi 1 false false);
    ("caml_continuation_use_and_update_handler_noexc", abi 4 false false);
    ("ocamlcc_effect_register_exceptions", abi 2 false false);
    ("ocamlcc_effect_perform", abi 1 true true);
    ("ocamlcc_effect_runstack", abi 3 true true);
    ("ocamlcc_effect_resume", abi 4 true true);
    ("ocamlcc_effect_reperform", abi 3 true true);
    ("ocamlcc_monotonic_ns", abi 1 false false);
    ("ocamlcc_poller_watch", abi 3 true false);
    ("ocamlcc_poller_unwatch_waiter", abi 3 false false);
    ("ocamlcc_poller_wait", abi 2 false false);
    ("ocamlcc_poller_wait_adding", abi 4 true false);
    (* structural comparison / hashing *)
    ("caml_fresh_oo_id", abi 1 false false);
    ("caml_equal", abi 2 true false);
    ("caml_notequal", abi 2 true false);
    ("caml_compare", abi 2 true false);
    ("caml_lessthan", abi 2 true false);
    ("caml_lessequal", abi 2 true false);
    ("caml_greaterthan", abi 2 true false);
    ("caml_greaterequal", abi 2 true false);
    ("caml_hash", abi 4 false false);
    (* value let rec dummy allocation/backpatch *)
    ("caml_alloc_dummy", abi 1 false false);
    ("caml_alloc_dummy_float", abi 1 false false);
    ("caml_alloc_dummy_lazy", abi 1 false false);
    ("caml_update_dummy", abi 2 false false);
    ("caml_update_dummy_lazy", abi 2 false false);
    (* floats, formatting, parsing, boxed-integer conversions *)
    ("caml_format_float", abi 2 false false);
    ("caml_float_of_string", abi 1 true false);
    ("caml_int32_to_float", abi 1 false false);
    ("caml_int32_of_float", abi 1 false false);
    ("caml_int32_bits_of_float", abi 1 false false);
    ("caml_int32_float_of_bits", abi 1 false false);
    ("caml_int64_to_float", abi 1 false false);
    ("caml_int64_of_float", abi 1 false false);
    ("caml_int64_bits_of_float", abi 1 false false);
    ("caml_int64_float_of_bits", abi 1 false false);
    ("caml_nativeint_to_float", abi 1 false false);
    ("caml_nativeint_of_float", abi 1 false false);
    ("caml_sqrt_float", abi 1 false false);
    ("caml_floor_float", abi 1 false false);
    ("caml_ceil_float", abi 1 false false);
    ("caml_fmod_float", abi 2 false false);
    ("caml_copysign_float", abi 2 false false);
    ("caml_classify_float", abi 1 false false);
    (* atomics, stdlib core *)
    ("caml_atomic_load_field", abi 2 false false);
    ("caml_atomic_cas_field", abi 4 false false);
    ("caml_atomic_exchange_field", abi 3 false false);
    ("caml_atomic_fetch_add_field", abi 3 false false);
    ("ocamlcc_set_at_exit_fn", abi 1 false false);
    ("ocamlcc_caml_install_lookup", abi 1 false false);
    ("caml_sys_exit", abi 1 false false);
    (* channels / raw fd hooks *)
    ("caml_sys_open", abi 3 true false);
    ("ocamlcc_raw_fd_read", abi 4 true false);
    ("ocamlcc_raw_fd_write", abi 4 true false);
    ("ocamlcc_raw_fd_lseek", abi 3 true false);
    ("ocamlcc_raw_fd_size", abi 1 true false);
    ("ocamlcc_raw_fd_close", abi 1 true false);
    ("ocamlcc_raw_fd_isatty", abi 1 false false);
    ("ocamlcc_stdio_flush", abi 1 false false);
    ("ocamlcc_ba_to_bytes", abi 5 true false);
    ("ocamlcc_ba_of_bytes_slice", abi 5 true false);
    ("ocamlcc_ptr_id", abi 1 false false);
    ("ocamlcc_marshal_kind", abi 1 false false);
    ("ocamlcc_ba_info", abi 1 false false);
    ("ocamlcc_ba_read_bytes", abi 1 false false);
    ("ocamlcc_ba_of_bytes", abi 4 true false);
    ("ocamlcc_zstd_compress_bytes", abi 2 false false);
    ("ocamlcc_zstd_decompress_bytes", abi 4 false false);
    (* obj / hex float / atomic contended *)
    ("caml_obj_tag", abi 1 false false);
    ("caml_hexstring_of_float", abi 3 false false);
    ("caml_atomic_make_contended", abi 1 false false);
    (* sys / env / fs / runtime *)
    ("ocamlcc_sys_is_win32", abi 1 false false);
    ("caml_sys_argv", abi 1 false false);
    ("caml_sys_getenv", abi 1 true false);
    ("caml_sys_getenv_opt", abi 1 false false);
    ("caml_sys_file_exists", abi 1 false false);
    ("caml_sys_is_directory", abi 1 true false);
    ("caml_sys_is_regular_file", abi 1 true false);
    ("caml_sys_remove", abi 1 true false);
    ("caml_sys_rename", abi 2 true false);
    ("caml_sys_chdir", abi 1 true false);
    ("caml_sys_mkdir", abi 2 true false);
    ("caml_sys_rmdir", abi 1 true false);
    ("caml_sys_getcwd", abi 1 true false);
    ("caml_sys_read_directory", abi 1 true false);
    ("caml_sys_system_command", abi 1 true false);
    ("caml_sys_time", abi 1 false false);
    ("caml_sys_close", abi 1 true false);
    ("caml_sys_random_seed", abi 1 false false);
    (* sync: mutex / condition *)
    ("caml_ml_mutex_new", abi 1 false false);
    ("caml_ml_mutex_lock", abi 1 true false);
    ("caml_ml_mutex_try_lock", abi 1 false false);
    ("caml_ml_mutex_unlock", abi 1 true false);
    ("caml_ml_condition_new", abi 1 false false);
    ("caml_ml_condition_wait", abi 2 true false);
    ("caml_ml_condition_signal", abi 1 false false);
    ("caml_ml_condition_broadcast", abi 1 false false);
    (* libm float math *)
    ("caml_exp_float", abi 1 false false);
    ("caml_exp2_float", abi 1 false false);
    ("caml_expm1_float", abi 1 false false);
    ("caml_log_float", abi 1 false false);
    ("caml_log10_float", abi 1 false false);
    ("caml_log2_float", abi 1 false false);
    ("caml_log1p_float", abi 1 false false);
    ("caml_power_float", abi 2 false false);
    ("caml_sin_float", abi 1 false false);
    ("caml_cos_float", abi 1 false false);
    ("caml_tan_float", abi 1 false false);
    ("caml_asin_float", abi 1 false false);
    ("caml_acos_float", abi 1 false false);
    ("caml_atan_float", abi 1 false false);
    ("caml_atan2_float", abi 2 false false);
    ("caml_sinh_float", abi 1 false false);
    ("caml_cosh_float", abi 1 false false);
    ("caml_tanh_float", abi 1 false false);
    ("caml_asinh_float", abi 1 false false);
    ("caml_acosh_float", abi 1 false false);
    ("caml_atanh_float", abi 1 false false);
    ("caml_cbrt_float", abi 1 false false);
    ("caml_hypot_float", abi 2 false false);
    ("caml_fma_float", abi 3 false false);
    ("caml_erf_float", abi 1 false false);
    ("caml_erfc_float", abi 1 false false);
    ("caml_trunc_float", abi 1 false false);
    ("caml_round_float", abi 1 false false);
    ("caml_signbit_float", abi 1 false false);
    ("caml_nextafter_float", abi 2 false false);
    ("caml_frexp_float", abi 1 false false);
    ("caml_ldexp_float", abi 2 false false);
    ("caml_modf_float", abi 1 false false);
    (* computed fields & bigarray stubs *)
    ("caml_obj_field", abi 2 false false);
    ("caml_obj_set_field", abi 3 false false);
    ("caml_ba_create", abi 3 true false);
    ("caml_ba_get_generic", abi 2 true false);
    ("caml_ba_set_generic", abi 3 true false);
    ("caml_ba_get_1", abi 2 true false);
    ("caml_ba_get_2", abi 3 true false);
    ("caml_ba_get_3", abi 4 true false);
    ("caml_ba_set_1", abi 3 true false);
    ("caml_ba_set_2", abi 4 true false);
    ("caml_ba_set_3", abi 5 true false);
    ("caml_ba_num_dims", abi 1 true false);
    ("caml_ba_kind", abi 1 true false);
    ("caml_ba_layout", abi 1 true false);
    ("caml_ba_change_layout", abi 2 true false);
    ("caml_ba_sub", abi 3 true false);
    ("caml_ba_slice", abi 2 true false);
    ("caml_ba_blit", abi 2 true false);
    ("caml_ba_fill", abi 2 true false);
    ("caml_ba_reshape", abi 2 true false);
    ("caml_ba_dim", abi 2 true false);
    (* lazy & obj *)
    ("caml_lazy_make_block", abi 1 false false);
    ("caml_lazy_make_forward", abi 1 false false);
    ("caml_lazy_update_to_forcing", abi 1 false false);
    ("caml_lazy_reset_to_lazy", abi 1 false false);
    ("caml_lazy_update_to_forward", abi 1 false false);
    ("caml_obj_block", abi 2 true false);
    ("caml_obj_dup", abi 1 false false);
    ("caml_obj_with_tag", abi 2 false false);
    ("caml_floatarray_get", abi 2 true false);
    ("caml_floatarray_set", abi 3 true false);
    ("caml_obj_add_offset", abi 2 false false);
    ("caml_obj_reachable_words", abi 1 false false);
    ("caml_obj_raw_field", abi 2 false false);
    ("caml_obj_set_raw_field", abi 3 false false);
    ("caml_ephe_create", abi 1 true false);
    ("caml_ephe_get_key", abi 2 true false);
    ("caml_ephe_get_key_copy", abi 2 true false);
    ("caml_ephe_set_key", abi 3 true false);
    ("caml_ephe_unset_key", abi 2 true false);
    ("caml_ephe_check_key", abi 2 true false);
    ("caml_ephe_blit_key", abi 5 true false);
    ("caml_ephe_get_data", abi 1 true false);
    ("caml_ephe_get_data_copy", abi 1 true false);
    ("caml_ephe_set_data", abi 2 true false);
    ("caml_ephe_unset_data", abi 1 true false);
    ("caml_ephe_check_data", abi 1 true false);
    ("caml_ephe_blit_data", abi 2 true false);
    (* weak blit *)
    ("caml_weak_blit", abi 5 true false);
    (* gc / finalizers / memprof *)
    ("caml_gc_stat", abi 1 true false);
    ("caml_gc_quick_stat", abi 1 true false);
    ("caml_gc_counters", abi 1 false false);
    ("caml_gc_minor_words", abi 1 false false);
    ("caml_gc_get", abi 1 false false);
    ("caml_gc_set", abi 1 false false);
    ("ocamlcc_finalizers_due", abi 0 false false);
    ("ocamlcc_poll_finalizers", abi 0 true false);
    ("caml_gc_minor", abi 1 true false);
    ("caml_gc_major_slice", abi 1 true false);
    ("caml_gc_major", abi 1 true true);
    ("caml_gc_full_major", abi 1 true true);
    ("caml_gc_compaction", abi 1 true true);
    ("caml_get_minor_free", abi 1 false false);
    ("caml_final_register", abi 2 true false);
    ("caml_final_register_called_without_value", abi 2 true false);
    ("caml_final_release", abi 1 false false);
    ("caml_memprof_start", abi 3 true false);
    ("caml_memprof_is_sampling", abi 1 false false);
    ("caml_memprof_stop", abi 1 false false);
    ("caml_memprof_discard", abi 1 false false);
    ("caml_ml_gc_ramp_up", abi 1 true false);
    ("caml_ml_gc_ramp_down", abi 1 false false);
    ("caml_gc_tweak_set", abi 2 false false);
    ("caml_gc_tweak_get", abi 1 false false);
    ("caml_gc_tweak_list_active", abi 1 false false);
    ("caml_get_public_method", abi 2 true false);
    ("caml_get_continuation_callstack", abi 2 false false);
    (* compiler-libs.common primitives (linked by bootstrap compiler_stubs.c) *)
    ("caml_sys_get_stdlib_dirs", abi 1 false false);
    ("caml_sys_time_include_children", abi 1 false false);
    ("caml_terminfo_rows", abi 1 true false);
    ("caml_zstd_initialize", abi 1 false false) ]

let find_opt name = List.assoc_opt name table

let find name =
  match find_opt name with
  | Some abi -> abi
  | None ->
      (* Unknown user externals: conservative default. *)
      { argc = 0; raises = true; yields = false }

let is_known name = List.mem_assoc name table

let returns_imm = function
  | "ocamlcc_finalizers_due" | "ocamlcc_poll_finalizers"
  | "ocamlcc_bulk_blit_bytes" | "ocamlcc_bulk_fill_bytes"
  | "ocamlcc_bulk_array_blit" | "ocamlcc_bulk_array_fill"
  | "caml_gc_minor" | "caml_gc_major_slice" | "caml_gc_major"
  | "caml_gc_full_major" | "caml_gc_compaction" | "caml_get_minor_free"
  | "caml_final_register" | "caml_final_register_called_without_value"
  | "caml_final_release"
  | "caml_string_length" | "caml_bytes_length" | "caml_array_length"
  | "caml_int_compare" | "caml_equal" | "caml_notequal" | "caml_compare"
  | "caml_lessthan" | "caml_lessequal" | "caml_greaterthan" | "caml_greaterequal"
  | "caml_hash"
  | "caml_obj_tag" | "caml_obj_size" | "caml_obj_is_int" | "caml_obj_set_tag"
  | "ocamlcc_raw_fd_read" | "ocamlcc_raw_fd_write" | "ocamlcc_raw_fd_close"
  | "ocamlcc_raw_fd_isatty" | "ocamlcc_stdio_flush"
  | "ocamlcc_ba_to_bytes" | "ocamlcc_ba_of_bytes_slice"
  | "ocamlcc_set_at_exit_fn" | "ocamlcc_caml_install_lookup" | "ocamlcc_sys_is_win32"
  | "ocamlcc_fiber_is_done" | "ocamlcc_fiber_is_main"
  | "ocamlcc_fiber_can_yield" | "ocamlcc_fiber_sched_set"
  | "ocamlcc_effect_register_exceptions"
  | "ocamlcc_monotonic_ns" | "ocamlcc_poller_watch"
  | "ocamlcc_poller_unwatch_waiter" | "ocamlcc_poller_wait"
  | "ocamlcc_poller_wait_adding"
  | "ocamlcc_arc_live" | "ocamlcc_arc_reuse" | "ocamlcc_arc_collect"
  | "ocamlcc_arc_slab_count"
  | "ocamlcc_ptr_id" | "ocamlcc_marshal_kind"
  | "ocamlcc_zstd_compress_bytes" | "ocamlcc_zstd_decompress_bytes"
  | "caml_ba_dim" | "caml_ba_num_dims" | "caml_ba_kind" | "caml_ba_layout"
  | "caml_ba_set_1" | "caml_ba_set_2" | "caml_ba_set_3" | "caml_ba_set_generic"
  | "caml_terminfo_rows" | "caml_zstd_initialize" ->
      true
  | _ -> false
