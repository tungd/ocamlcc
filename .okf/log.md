# Change Log

- 2026-11-18 (codex/1): The executable initializes every explicitly linked implementation once, in dependency order. This includes units whose only effect is registration at startup.

- 2026-11-17 (codex/1): Verify all 72 stdlib modules and the full native upstream matrix: 68/77 standalone tests pass, nine fail, 42 files skipped. All repository API fixtures pass on stock OCaml and ocamlcc, including lexer buffer growth, parser recovery/positions/nested parses, and foreign Marshal headers/endianness. Core ninja (26), sanitizer (16), and dune checks pass. Fix fixture discovery to ignore the README.

- 2026-11-17 (codex/1): Add native and ASan/UBSan ownership checks for malformed partial cycles, truncation/mutation, cycle collection, and Bigarray backing lifetime. Both pass with no live-object delta. Document the compatibility build and add the opt-in `ninja -j1 stdlib_compat` target.

- 2026-11-17 (codex/1): Fix object OID comparison/freshening and empty float-array structural equality after stock-passing regressions. Upstream Dynarray and Floatarray tests now pass. Bound decoded block allocation by the remaining payload and preserve channel Sys_error exceptions during reads.

- 2026-11-17 (codex/1): Add standard Bigarray Marshal custom payloads after a failing public roundtrip. Verify stock byte-for-byte wire fixtures, sharing/cycles, No_sharing, deep lists, sequential channels/EOF, and Compat_32. Upstream bigarrays, marshal_bigarray, all Hashtbl tests, and intern_final pass.

- 2026-11-17 (codex/1): Add iterative Marshal encoding/decoding, external sharing tables, ARC backpatch ownership, standard scalar/block/string/float/boxed-integer wire formats, buffer/offset/size APIs, and channels. Public core roundtrip fixture fails on missing primitives before implementation and passes after. All 72/72 stdlib modules now compile; normalize array/tag-zero structural comparison and hashing for decoded values.

- 2026-11-17 (codex/1): Complete Bigarray structural comparisons/hashes, complex records, channel I/O, overflow diagnostics, and Bigarray-backed Random state. Eight of nine selected upstream tests pass; the remaining Bigarray test reaches its unsupported Marshal section. Extend native runner with selection, reuse, JSON receipts, logs, and isolated test working directories.

- 2026-11-17 (codex/1): Lower Bigarray refs/sets and correct dimension numbering. Add ARC backing-buffer ownership and core Bigarray runtime API. Public int/float64 layout/bounds fixture fails before lowering and passes after; stdlib compiles 71/72 modules.

- 2026-11-17 (codex/1): Add pure OCaml Parsing LR engine and tracing. Generated ocamlyacc parser failed to link before the overlay and passes afterward, including stock differential checks, stack growth, parse errors, and restoration. Stdlib module build: 70/72.

- 2026-11-17 (codex/1): Add pure OCaml Lexing DFA and capture engines. Real ocamllex fixtures failed to link before the overlay and pass afterward, including stock differential checks. Stdlib module build: 69/72.

- 2026-11-17 (codex/1): Record the existing upstream stdlib import and ARC primitive integration as the foundation for Lexing, Parsing, Bigarray, and Marshal. Existing core checks pass (`ninja -j1 test`, `dune runtest -j1`); compatibility report is historical.

- 2026-11-17 (autoagent/1): Fix multi-`.mli` `--emit-header`, `.mli`-less `ios-xcframework`, and `Kind_shared` symbol visibility (TDD) —
  added `exported_symbols` to `C_bindgen.generated` (`lib/c_bindgen.mli`,
  `lib/c_bindgen.ml`, `bin/main.ml`, `test/c_bindgen_test.ml`); updated
  `lib/driver.ml` so multi-`.mli` `--emit-header <dir>/<stem>.h` writes
  `<stem>_<mod>.h` sub-headers plus an umbrella `<stem>.h` header,
  `ios-xcframework` skips forced `--emit-header` / `-headers` when no `.mli`
  input is present (and suppresses noisy `xcodebuild` stdout unless `-v`),
  and `Kind_shared` hides internal runtime/stdlib symbols (via
  `-Wl,-exported_symbols_list` / `-Wl,-unexported_symbols_list` on Darwin
  and `-Wl,--version-script` / `ar` + `-Wl,--exclude-libs,ALL` on
  Linux/Android) so two separate OCaml shared libraries link into one host
  without symbol collision. Added `two shared libs no collision`, `multi-mli
  emit-header naming`, and `ios-xcframework without mli` tests and updated
  `shared library + header` in `test/driver_test.ml`. `dune runtest` (14/14),
  `ninja test` (25/25), and `ninja asan_test` (15/15) pass. Updated
  [build-pipeline](/concepts/build-pipeline.md).

- 2026-11-17 (autoagent/1): Support `.mli`-mediated mutual `.ml` dependencies in `Driver.plan_build_order` (TDD) —
  separated compile-time `.cmi` edges (`hard_deps`) from `.ml -> .ml`
  ordering hints (`soft_deps`) in `lib/driver.ml` (`plan_build_order`), using
  Tarjan SCC condensation + Kahn topological sort on `hard_deps` within each
  SCC so mutually dependent `.ml` modules mediated by `.mli` interfaces build
  and initialize cleanly via idempotent `ocamlcc_init_*` while true `.ml` (no
  `.mli`) and `.mli` cycles still fail with `"cyclic module dependency
  detected"`. Added `mli-mediated mutual deps` test in `test/driver_test.ml`.
  `dune runtest` (14/14) and `ninja test` (25/25) pass.

- 2026-11-17 (autoagent/1): Topological header typedef ordering & option/tuple `_free` helpers (TDD) —
  refactored `lib/c_bindgen.ml` (`translate_signature` / `emit_header`) to
  record and emit `HD_opaque`, `HD_record`, `HD_option`, and `HD_tuple`
  typedefs in topological post-order so inner types (records containing
  `option`/tuples, options of tuples) always precede outer structs; added
  `static inline` `<sname>_free` destructors for `CT_option` and `CT_tuple`
  when `needs_free` is true; changed `ocamlcc_free_string` to a header
  `static inline void ocamlcc_free_string(const char *s)` (removing the
  duplicate definition from `emit_shim`) so `const char *` fields free
  without qualifier warnings and multiple shims link cleanly; shared
  `emit_free_field` across header and shim destructors. Added `nested typedef
  order + free` test in `test/c_bindgen_test.ml` verified with `cc -std=c99
  -Wall -Wextra -Werror`. `dune runtest` (14/14) and `ninja test` (25/25) pass.

- 2026-11-17 (autoagent/1): Wrap C_bindgen shims in the ARC mutator gate (TDD) —
  updated `lib/c_bindgen.ml` (`emit_shim`) to declare `arc_mutator_enter` and
  `arc_mutator_leave` and enter/leave the mutator gate across `<mod>_init`,
  opaque `_retain`/`_release`, and every exported `<mod>_<val>` entrypoint
  body (marshalling, `ocamlcc_apply*`, exception cleanup, unmarshalling, and
  `arc_release_val(res)` across all return paths). Added `shim mutator gate`
  structural checks in `test/c_bindgen_test.ml` and concurrent 4-thread
  worker + collector `mt bindgen mutator gate` stress test in
  `test/driver_test.ml`. `dune runtest` (14/14), `ninja test` (25/25), and
  `ninja asan_test` (15/15) pass. Updated [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-17 (autoagent/1): Fix Driver stdlib `.cmi` resolution and pre-user fallback compilation (TDD) —
  `lib/driver.ml` now resolves `ocamlcc`'s own `stdlib.cmi` before user
  compilation when `not cfg.nostdlib`: on host default toolchain it uses
  `prebuilt_stdlib_dir` (requiring both `.o` objects and `stdlib.cmi`), and
  otherwise compiles `stdlib/` `.cmi` + `.ssa` into `work_dir/stdlib` via
  `compile_stdlib_cmis_and_ssa` ahead of user `.mli`/`.ml` and `C_bindgen`
  steps, prepending that directory to `inc_dirs` and passing `~nostdlib:true`
  (then assembling/compiling those `.ssa` files with `compile_stdlib_objs_from_ssa`
  at link time). Added `default stdlib cmi` and `stdlib fallback cmi` tests
  and removed the `nostdlib = true` workaround from the shared-library test in
  `test/driver_test.ml`. `dune runtest` (14/14) and `ninja test` (25/25) pass.
  Updated [build-pipeline](/concepts/build-pipeline.md).

- 2026-11-17 (autoagent/1): Add single-binary driver `ocamlcc build --target <t>` (TDD) —
  implemented `lib/driver.ml`/`lib/driver.mli` and wired `ocamlcc build` in
  `bin/main.ml` (plus `unix` in `lib/dune`). Parses `.mli`/`.ml` module
  dependencies via compiler-libs `Depend`, topologically sorts compilation
  units (ensuring `.mli` `.cmi` precedes `.ml` and runtime dependency `.ml`
  precedes dependents), compiles units, optionally invokes `C_bindgen` via
  `--emit-header`, invokes `qbe -t <target>` (`arm64_apple`, `arm64`,
  `amd64_sysv`, `rv64`, `amd64_apple`, `amd64_win`, plus platform aliases
  `ios-arm64`, `ios-sim-arm64`, `ios-xcframework`, `android-arm64`,
  `android-x86_64`, `linux-*`, `macos-*`), compiles/links runtime + stdlib
  with `cc`/`xcrun`/NDK/`ar` (omitting `main_entry.o` for `--shared`,
  `--static`, `--no-main`, and `ios-xcframework`). Added `test/driver_test.ml`
  (Red: unbound `Driver`; Green: dependency order, out-of-order exe, shared
  lib + generated header + C host with no `main`, static lib with no `main`,
  and cross-target QBE asm for `arm64_apple`/`arm64`/`amd64_sysv`/`rv64`).
  Also verified CLI `ocamlcc build --target ios-xcframework` producing
  `ios-arm64` + `ios-arm64-simulator` `.xcframework`. `dune runtest` (14/14),
  `ninja test` (25/25), `ninja asan_test` (15/15). Documented in
  [roadmap](/concepts/roadmap.md), [build-pipeline](/concepts/build-pipeline.md),
  and [getting-started](/concepts/getting-started.md).

- 2026-11-17 (autoagent/1): Add `.mli -> .h` C99 header & FFI shim generator (`C_bindgen`, `ocamlcc bindgen`) (TDD) —
  implemented `lib/c_bindgen.ml`/`lib/c_bindgen.mli` walking typed `.mli`
  signatures via `Frontend.with_typed_interface` (`Typemod.type_interface` +
  `sig_final_env`), emitting C99 headers + standalone `_shim.c` wrappers
  covering `unit`, `int`, `bool`, `char`, `float`, `string`, `int32`,
  `int64`, `nativeint`, `'a option` (`ocamlcc_opt_*`), tuples
  (`ocamlcc_tuple_*`), regular and all-float records (`Record_regular` /
  `Record_float` / `Record_unboxed`), and opaque abstract types (`_retain`/
  `_release` handles). Added freestanding `ocamlcc_format_exn` in
  `runtime/arc.c`/`runtime/arc.h` so raised OCaml exceptions are cleared
  from `tls_exn_slot`, released, and surfaced via an explicit
  `ocamlcc_error_t *err` out-parameter. Wired `ocamlcc bindgen` in
  `bin/main.ml`, added `test/c_bindgen_test.ml` (`dune runtest` 13/13), and
  added end-to-end `-std=c99 -Wall -Wextra -Werror` + ASan/UBSan test
  `examples/bindgen_lib.{mli,ml}` + `tests/bindgen_host.c` (`test_bindgen`
  + `asan_bindgen`, `delta=0`). `ninja test` (25/25), `ninja asan_test`
  (15/15).

- 2026-11-17 (autoagent/1): Sync `README.md` with current test suites and QBE 1.3 —
  updated `README.md` from stale 19 checked examples / QBE 1.2 to reflect
  `ninja test` (24/24), `ninja asan_test` (14/14), `dune runtest` (12/12),
  vendored QBE 1.3, `test/`, `runtime/` (`closure.c`, `main_entry.c`), and
  `Int32`/`Int64`/`Nativeint` stdlib modules.

- 2026-11-17 (autoagent/1): Resolve `Builtins` directly from `stdlib.cmi` without host probe-snippet compilation (TDD) —
  replaced `lib/builtins.ml`'s `Frontend.compile_implementation` probe
  snippets (`let () = print_int 1`, etc.) and `Printlambda.lambda` string
  matching with direct `Cmi_format.read_cmi` slot-offset scanning over the
  active `stdlib.cmi` along `include_dirs` (falling back to
  `Config.standard_library`) and direct `Lambda.Lprim (Pfield _, [Lprim
  (Pgetglobal id, ...)])` AST matching. Added `?include_dirs` to
  `Anf.of_lambda` (`lib/anf.ml`/`lib/anf.mli`, passed by `lib/pipeline.ml`),
  so compiling with `-I dir` and `--nostdlib` off resolves `dir/stdlib.cmi`
  instead of always probing the host switch's `Stdlib` or mutating global
  compiler-libs state inside `Anf.of_lambda`. Added `test/builtins_test.ml`
  to `test/dune` (Red: `custom stdlib builtins: FAIL` with `print_int` at
  slot 0; Green: both custom `-I` and host `Stdlib` pass). `dune runtest`
  (12/12), `ninja test` (24/24), `ninja asan_test` (14/14). Documented in
  [compiler-pipeline](/concepts/compiler-pipeline.md).

- 2026-11-17 (autoagent/1): Reclaim empty 64 KB slabs and rehash sparse weak-target tables without doubling (TDD) —
  replaced the bump-only slab freelist in `runtime/arc.c` with per-slab
  metadata (`SlabPage` at offset 0 of each 64 KB slab, sorted `g_slab_dir`
  directory, per-class `g_partial_slabs`/`g_full_slabs` lists); `slab_free`
  now returns empty 64 KB slabs to `pal_page_free` when
  `g_class_slab_count[cls] > 1` (retaining at most 1 warm slab per active
  class). Added `g_weak_targets_live` tracking and replaced
  `weak_targets_grow` with `weak_targets_rehash`, which purges tombstones at
  the same capacity instead of doubling whenever `(live + 1) * 2 <= cap`.
  Added `ocamlcc_arc_slab_count` / `ocamlcc_weak_table_cap` probes to
  `examples/arc_test.ml` and `examples/weak_cycle.ml` (Red: `arc_test`
  retained >4 slabs after freeing a 100k-list, `weak_cycle` doubled table
  cap past 1024 under 2000 insert/clear cycles; Green: `arc_slab_count <= 4`
  and `weak_table_cap = 1024`, `arc_live = 0`). `dune runtest` (11/11),
  `ninja test` (24/24), `ninja asan_test` (14/14). Documented in
  [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-17 (autoagent/1): Synchronize `ocamlcc_arc_collect` across FFI mutator threads via mutator gate (TDD) —
  `ocamlcc_arc_collect` previously traversed `cc_visit_children` and freed
  dead cycles without stopping or draining active mutator threads. Added an
  OS-thread FFI mutator gate (`arc_mutator_enter` / `arc_mutator_leave` in
  `runtime/arc.c` / `runtime/arc.h`, tracking `g_active_mutators`,
  `g_cc_waiting`, and `_Thread_local tls_os_mutator_active`) around
  `ocamlcc_apply1..4` and `ocamlcc_apply_n` (`runtime/closure.c`), while
  `fiber_trampoline` (`runtime/fiber.c`) and recursive over-application call
  `ocamlcc_apply1_raw` / `ocamlcc_apply_n_raw` so fiber stack swaps never
  leak mutator depth. Serialized collection with `g_cc_collect_lock`:
  external callers wait for `g_active_mutators == 0` while `g_cc_waiting`
  blocks new entries; callers already inside `ocamlcc_apply*` use
  `arc_trylock(&g_cc_collect_lock)` and return `0` when other mutator threads
  are active, avoiding both AB-BA deadlock and use-after-free. Added
  concurrent `cycle_iter` + 9th collector thread stress in
  `examples/mt_ffi_lib.ml` and `tests/mt_ffi_host.c` (Red: `test_mt_ffi`
  crashed with `SIGBUS`/138; Green: `all_ok=1 delta=0` across `ninja test`
  24/24, `ninja asan_test` 14/14, `dune runtest` 11/11, and TSan with 0
  races). Documented the concurrency boundary in
  [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-17 (autoagent/1): Mark `caml_equal` and `caml_notequal` as `raises = true` in `Ccalls` (TDD) —
  `val_compare_raw` (`runtime/arc.c`) raises `Invalid_argument "compare: cyclic structure"`
  when `*steps <= 0` or `depth >= COMPARE_MAX_DEPTH` even when `total == 0`
  (`caml_equal` / `caml_notequal`), but `lib/ccalls.ml` registered both as
  `abi 2 false false`, causing `arc_pass` to omit `CheckExn` around `=`/`<>`
  inside `try ... with`. Updated `test/ccalls_test.ml` and added `eq_cyc`/
  `neq_cyc` probes with live locals inside `try ... with Invalid_argument _`
  in `examples/stdlib_test.ml` (Red: `ccalls_test` failed `raises=false`,
  `stdlib_test` aborted with `SIGABRT`/134; Green: `cmp=1,1,1,1,1` and
  `arc_delta=0`). `dune runtest` (11/11), `ninja test` (24/24),
  `ninja asan_test` (14/14). Documented in [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-17 (autoagent/1): Fix `Anf.pure_defs` dropping `known'` across sequential `Let (id, Fun lf, body)` (TDD) —
  in `lib/anf.ml`, the `Let (id, Fun lf, body)` arm added `id` to `known'`
  when recursing into `lf.body`, but passed the stale `known` when recursing
  into `body`. Any pure non-recursive function `f` defined after and calling
  a prior pure non-recursive function `h` (`let h x = x + 1 in let f y = h y`)
  was omitted from `Anf.pure_defs`, so `arc_pass` owned and `Release`d `f`
  while `codegen` compiled it as static. `test/pure_nested_test.ml`'s
  `static_fun_ids` helper had the identical `go extra acc body` omission
  (plus missing `extra` propagation in `LetRec`), reporting `1 static funs`
  for `toplevel_helper`. Fixed `static_fun_ids` and added unexported
  `seq_unexported_helper` (Red: `toplevel_helper` released `f` 1x,
  `seq_unexported_helper` released `f` 2x; Green: `toplevel_helper` 2 static
  funs / 0 releases, `seq_unexported_helper` 3 static funs / 0 releases).
  `dune runtest` (11/11), `ninja test` (24/24), `ninja asan_test` (14/14).

- 2026-11-17 (autoagent/1): Add `float`, `float array`, `int32`, `int64`, `nativeint`, and `Printf` `%f`/`%ld`/`%Ld`/`%nd` (TDD) —
  implemented unboxed QBE `Double` (`d`) and 32/64-bit boxed integer lowering
  in `lib/qbe_il.ml`, `lib/anf.ml`, `lib/arc_pass.ml`, `lib/codegen_ctx.ml`,
  and `lib/codegen_expr.ml`: `Const_float`, `Const_float_array`, `Const_int32`,
  `Const_int64`, `Const_nativeint`, float arithmetic/neg/abs/conversions/
  comparisons (`ceqd`..`cged`/`Fcmp`), `Pfloatarray` + all-float records
  (`Pfloatfield`/`Psetfloatfield`) + `Pgenarray` runtime dispatch
  (`arc_alloc_array`, `ocamlcc_gen_makearray`, `ocamlcc_gen_array_get`,
  `ocamlcc_gen_array_set`), and boxed int ops (`Pint32` via `Word`/`extsw`,
  `Pint64`/`Pnativeint` via `Long`, with zero-divisor `Division_by_zero` and
  `-1` guards against `INT_MIN / -1` SIGFPE). Added `ARC_TAG_CUSTOM = 255`
  (`ARC_CUSTOM_INT32/INT64/NATIVEINT`) alongside `ARC_TAG_FLOAT`/`ARC_TAG_FLOAT_ARRAY`
  in `runtime/arc.h`/`runtime/arc.c`, excluded all unscanned leaves via
  `is_unscanned_leaf_tag`, added structural float/float-array/custom
  comparison + hashing (with NaN semantics and `-0.0` normalization), capped
  `COMPARE_MAX_DEPTH` at `10000` with `noinline` float compare helpers so
  deep cyclic compare stays ASan stack-safe (`asan_stdlib_test`), added `-lm`
  link flag in `build.ninja`, implemented formatting/parsing/math helpers in
  `runtime/builtins.c`/`runtime/arc.c`/`lib/ccalls.ml`, added `Stdlib.Int32`,
  `Stdlib.Int64`, `Stdlib.Nativeint`, stdlib `float` primitives, and `Printf`
  `Int32`/`Int64`/`Nativeint`/`Float` formatters (`%f`, `%.2f`, `%e`, `%g`,
  `%F`, `%ld`, `%Ld`, `%nd`, width/zero-padding/`#`). Added `test/primitives_ir_test.ml`
  and `examples/primitives_test.ml` (`delta=0`). `dune runtest` (11/11),
  `ninja test` (24/24), `ninja asan_test` (14/14). Documented in
  [compiler-pipeline](/concepts/compiler-pipeline.md),
  [value-representation](/concepts/value-representation.md), and
  [perceus-arc](/concepts/perceus-arc.md).
- 2026-11-17 (autoagent/1): Add `Tupled` functions and `value let rec` (`caml_alloc_dummy*` / `caml_update_dummy*`) (TDD) —
  lowered `Lambda.Tupled` functions in `Anf.conv_fun` by unpacking tuple fields
  via `Field (i, Var tup)` from a single tuple parameter so both direct calls
  and higher-order closures work uniformly. Registered `caml_alloc_dummy`,
  `caml_alloc_dummy_float`, `caml_alloc_dummy_lazy`, `caml_update_dummy`, and
  `caml_update_dummy_lazy` in `lib/ccalls.ml` and implemented them in
  `runtime/arc.c` (`runtime/arc.h` adds `ARC_TAG_FLOAT = 253` and
  `ARC_TAG_FLOAT_ARRAY = 254` excluded from scanning/cycle-candidate checks):
  `caml_update_dummy` releases prior dummy children, copies `newval` payload
  while preserving `dhdr->byte_size` for slab class accuracy, updates
  `tag`/`scan_fields`, and retains copied scanned children so cyclic `let rec`
  values collect cleanly via `ocamlcc_arc_collect`. Added
  `test/tupled_letrec_test.ml` and end-to-end `examples/tupled_letrec.ml`
  (`s=4,30,1,5 coll=1 delta=0`). `dune runtest` (10/10), `ninja test`
  (23/23), `ninja asan_test` (13/13). Documented in
  [compiler-pipeline](/concepts/compiler-pipeline.md).
- 2026-11-17 (autoagent/1): Thread-safe runtime for multi-threaded Mobile FFI (TDD) —
  converted `ArcHeader.refcount` to C11 `_Atomic uint32_t` with atomic
  retain/release/drop-reuse and CAS-based `arc_try_retain` for weak-ref
  upgrades (`runtime/arc.h`, `runtime/arc.c`); converted `g_live_objects`,
  `g_reuse_hits`, `g_next_oo_id`, and `g_weak_count` to atomics; guarded slab
  allocation (`g_alloc_lock`), weak registry (`g_weak_lock`), cycle-collector
  roots (`g_cc_lock` + `g_cc_active`), and `PAL_USE_EPOLL` `g_watches`
  (`g_watch_lock` in `runtime/pal.c`) with freestanding C11 spinlocks. Replaced
  process-global `ocamlcc_exn_slot` with `_Thread_local` `tls_exn_slot` via
  `ocamlcc_get_exn()`/`ocamlcc_set_exn()` (`lib/codegen_expr.ml`,
  `runtime/closure.c`, `runtime/fiber.c`), and made `tls_main_fiber`,
  `tls_current_fiber`, and `tls_sched` `_Thread_local` in `runtime/fiber.c`.
  Rewrote `ocamlcc_arc_collect` to compute trial refcounts in a local
  `TrialMap` without mutating live objects' `refcount` fields, and fixed a
  dangling `g_cc_roots` double-free where `cc_roots_remove_locked` skipped
  `ARC_TAG_FIBER` even though `is_cycle_candidate_obj` added fibers to
  `g_cc_roots` (`delta=-1` caught by the new test). Added 8-thread stress test
  `examples/mt_ffi_lib.ml` + `tests/mt_ffi_host.c` (`test_mt_ffi` and
  `asan_mt_ffi`): Red run segfaulted on unpatched runtime; Green passes
  `all_ok=1 delta=0` across `ninja test` (22/22), `ninja asan_test` (12/12),
  `dune runtest` (9/9), and `-fsanitize=thread` (0 TSan data races).
  Documented in [perceus-arc](/concepts/perceus-arc.md) and
  [wren-fibers](/concepts/wren-fibers.md).
- 2026-11-17 (autoagent/1): Modularize codegen & eliminate builder save/restore boilerplate (TDD) —
  split the 2,061-line `lib/codegen.ml` into five focused modules:
  `lib/codegen_ctx.ml` (module builder + isolated `fn_state` with
  `with_fn_state` and `with_shadowed_vars` replacing duplicated 12-field
  save/restore boilerplate across `compile_function` and `compile_group`),
  `lib/codegen_analysis.ml` (pure-defs, tail-call SCCs, free-variable filter,
  dependency collection), `lib/codegen_expr.ml` (atoms, ops, cexprs, apply,
  control flow, switches), `lib/codegen_fn.ml` (closures, trampolines,
  `compile_function`, `compile_group`, `compile_letrec`), and `lib/codegen.ml`
  (`compile_program`, preserving `lib/codegen.mli`). Added
  `test/codegen_ctx_test.ml` testing `with_fn_state` exception-safe isolation
  and SCC grouping. `dune runtest` (9/9), `ninja test` (21/21),
  `ninja asan_test` (11/11). Documented in
  [compiler-pipeline](/concepts/compiler-pipeline.md).
- 2026-11-17 (autoagent/1): Upgrade vendored QBE to 1.3 + PIC `extern` emission (TDD) —
  replaced `vendor/qbe/` (1.2) with the official QBE 1.3 release (`gvn.c`,
  `gcm.c`, `ifopt.c`, `amd64/winabi.c`, `extern` GOT/PLT support, upstream
  Darwin `R18`/`IP1` fix); updated `build.ninja` (`-fPIC` on `rt_cflags`,
  QBE 1.3 objects). Added `Extern` and `?pic` (`true` by default) to
  `Qbe_il.to_string` so function bodies emit `extern $sym` for all external
  and exported symbols while keeping local non-exported symbols PC-relative.
  Separated `main()` from `runtime/builtins.c` into `runtime/main_entry.c` so
  shared libraries linking `libocamlrt.a` do not pull an undefined
  `ocamlcc_module_init` symbol. Verified with `test/qbe_pic_test.ml`,
  `test_qbe_pic` (`-t arm64` `:got:`/`:got_lo12:`, `-t amd64_sysv`
  `@gotpcrel`/`@plt`, `-t amd64_win`), and `test_pic_so` (`-shared -fPIC`
  DSO + C host). `dune runtest` (8/8), `ninja test` (21/21), `ninja asan_test`
  (11/11). Documented in [vendored-qbe](/concepts/vendored-qbe.md) and
  [build-pipeline](/concepts/build-pipeline.md).
- 2026-11-17 (autoagent/1): Repo hygiene, unit/IR/negative tests, ASan/UBSan & CI (TDD) —
  removed tracked `examples/hello.cmi` (`*.cmi` ignored in `.gitignore`), added
  `Pipeline.compile_source` for in-memory compilation tests, added
  `test/frontend_negative_test.ml`, `test/anf_negative_test.ml`, and
  `test/pipeline_ir_test.ml` to `dune runtest` (7/7 suites passing), added
  `ninja asan_test` (`-fsanitize=address,undefined -fno-sanitize-recover=all`),
  fixed signed left-shift UB caught by UBSan in `runtime/arc.c` (`tag_int`
  helper using `uint64_t`), and added `.github/workflows/ci.yml` covering Linux
  (epoll) and macOS (kqueue). Documented in
  [build-pipeline](/concepts/build-pipeline.md) and
  [getting-started](/concepts/getting-started.md).
- 2026-11-16 (autoagent/1): Bounded compare + fd/pipe contract fixes (TDD) —
  `val_compare_raw` (`runtime/arc.c`) had no cycle/depth limit: comparing two
  cyclic records recursed until the C stack crashed (red probe:
  `stdlib_test` died with SIGSEGV before printing the `cmp=` line), and
  tail-cyclic lists spun forever. Structural comparison is now bounded by a
  C-recursion depth limit (50 000) plus a shared step budget (10⁸), raising
  `Invalid_argument "compare: cyclic structure"`. Exception-constructor id
  blocks (tag 248: field 0 = name string, field 1 = OID) now compare
  structurally (name string, then OID) like real OCaml instead of by raw
  heap address. `ocamlcc_fd_read`/`ocamlcc_fd_write` raised
  `pal_abort` on out-of-bounds buffers and `ocamlcc_pipe` aborted on
  pipe creation failure (the `caml_blit_*`/`caml_fill_bytes` half of this
  item was already fixed in the C-call ABI registry slice): they now raise
  `Invalid_argument "index out of bounds"` / `Sys_error "pipe failed"` and
  are registered `raises = true` in `lib/ccalls.ml` so `TryWith` unwinds
  correctly (OS errors on read/write keep returning the negative count for
  the Fiber I/O poller). Green probes in `examples/stdlib_test.ml`
  (`cmp=1,1,1`: cyclic compare caught, deterministic exn-id ordering, fd
  bounds caught) with `arc_delta=0`. `19/19` examples pass. Documented in
  [perceus-arc](/concepts/perceus-arc.md).
- 2026-11-16 (autoagent/1): Weak-drop O(1) registry + fiber cycle collection
  (TDD) — two cycle-collector/weak fixes in `runtime/arc.c`:
  (1) **Weak-target registry** — whenever `g_weak_count > 0`, every dying
  heap object ran `weak_clear_target`, linearly scanning every `ArcWeakArray`
  slot even for objects never referenced by a `Weak.t`. `weak_set` now
  records weakly-referenced values in an open-addressing registry
  (`g_weak_targets`; load factor ≤ 2/3 with tombstone reuse — the first
  version allowed a fully-occupied cap-2 table whose probes never terminated
  and hung `weak_cycle`, red run observed; the growth invariant now always
  leaves empty slots), and `weak_clear_target` only scans when the dying
  object is registered, removing the entry afterwards. (2) **Fiber cycles** —
  `is_cycle_candidate_obj` excluded `ARC_TAG_FIBER`, so cycles through a
  suspended fiber's shadow stack (`record -> fiber -> record`) were
  uncollectable. Fibers are now candidates and `cc_visit_children` traverses
  the fiber's owning edges (shadow slots, entry closure, resume/suspend
  payload, per-fiber exn slots) — the entry-closure edge was essential
  (red: with only shadow edges, the trial's `scan_black` cascaded back
  through the fiber's `entry_closure -> holder -> Some -> fiber`,
  restoring the cycle to black; observed `dead=0`). Collected fibers get
  reuse tokens, stacks, and buffers torn down in the dead pass. Red probe:
  `test_fiber_shadow_cycle` in `examples/cycle_collect.ml` observed
  `freed=0, weak_alive=1, delta=4`; green: `freed=1, weak_alive=0, delta=0`.
  Deferred as roadmap decisions (documented in
  [perceus-arc](/concepts/perceus-arc.md)): automatic collector triggering
  (opt-in design, re-entrancy hazards) and empty-slab reclamation
  (`slab_free` still returns slots to per-class free lists without ever
  unmapping an empty 64 KB slab — needs per-slab occupancy metadata).
  `19/19` examples pass.
- 2026-11-16 (autoagent/1): epoll watch-registry fix — two bugs in
  `runtime/pal.c`'s `PAL_USE_EPOLL` branch: (1) `pal_poller_watch` returned
  0 (success) for any `epoll_ctl(EPOLL_CTL_ADD)` failure other than EEXIST;
  (2) two fibers watching the same fd (one `PAL_POLL_READ`, one
  `PAL_POLL_WRITE`) hit EEXIST and the `EPOLL_CTL_MOD` overwrote
  `ev.data.ptr`, silently losing the first fiber's wakeup (and, with
  `EPOLLONESHOT`, disarming its interest). Replaced with a per-poller,
  per-fd `PalWatch` registry: one registration per fd carrying per-direction
  udata, merged interest masks on re-watch, wait dispatch to the right
  watcher(s) (one kernel event can wake both directions), re-arm of a
  surviving interest after a one-shot fire, deregistration when both are
  done, and registry cleanup in `pal_poller_close` (transient pollers from
  `pal_poll_wait` no longer leak stale entries). Verified by shim
  syntax-check only — this macOS host cannot execute the epoll path; the
  kqueue path is unaffected and `19/19` examples pass. Documented in
  [wren-fibers](/concepts/wren-fibers.md).
- 2026-11-16 (autoagent/1): Fiber cross-call guard fix (TDD) — the two
  fiber kinds (coroutines from `Fiber.create` vs scheduler fibers from
  `Fiber.spawn`) had unguarded cross-calling: `Fiber.suspend` inside a
  spawned fiber stranded the fiber off every scheduler queue (leaking the
  fiber and its payload — `sched_step` sees `state != FIBER_DONE` and never
  releases it), and `Fiber.yield`/`sleep_ms`/`fd_wait_*` inside a coroutine
  queued it on `g_sched` without scheduler ownership while returning the
  resume payload to the resumer, leaving a dangling queue entry if the
  coroutine handle was dropped (UAF). Added mode guards in
  `runtime/fiber.c` using the stored `is_scheduled` flag plus a new
  `ocamlcc_fiber_raise_invalid` (`runtime/arc.c`/`arc.h`) raising
  `Invalid_argument` for: suspend-in-scheduler-fiber, yield/sleep/fd-wait in
  coroutines, and `Fiber.await` across modes in either direction (waiter
  handoff is only sound between scheduler fibers; awaiting a live coroutine
  from main can never complete). The guards' Ccalls are registered
  `raises = true` in `lib/ccalls.ml` so the ARC pass wraps them in
  `CheckExn` and the raise is catchable. Red run (pristine runtime):
  `cross=-0,0,0,-0,0` with `delta=1` (leaked fiber) and the raise escaping
  the coroutine as `pending_exn`; green: `cross=1,1,1,1,1`, all `delta=0`.
  Also fixed `build.ninja`'s `dune_ocamlcc` rule missing `lib/ccalls.ml`
  from its dependency list — registry-only edits left a stale compiler
  binary (found because the guards appeared to not catch until the
  compiler was rebuilt). `19/19` examples passing. Documented in
  [wren-fibers](/concepts/wren-fibers.md).
- 2026-11-16 (autoagent/1): C-call ABI registry fix (TDD) — the ARC pass
  classified `Ccall`s via hardcoded name lists (`ce_may_raise_fn`,
  `is_yielding_ccall`) that had drifted (`Weak.get_copy` was missed once),
  and `anf.ml` lowered any non-`caml_` external (≤ 6 args) to `Ccall` while
  silently assuming it borrows all args, returns an owned value, never
  raises and never yields. Replaced both lists with a single typed registry
  `lib/ccalls.ml` (`argc`/`raises`/`yields` per symbol, derived from the
  `stdlib/` external declarations and the runtime implementations in
  `runtime/arc.c`/`fiber.c`): `anf.ml` now rejects unknown `caml_`
  primitives at compile time and gives unknown user C externals the
  conservative default `raises = true` (so `TryWith` always unwinds
  correctly) / `yields = false`; `arc_pass` derives `ce_may_raise_fn` and
  `is_yielding_ccall` from the registry. Also fixed `caml_blit_bytes`/
  `caml_blit_string`/`caml_fill_bytes` in `runtime/arc.c` to raise
  `Invalid_argument "index out of bounds"` on out-of-bounds (matching real
  OCaml) instead of `pal_abort` — red: `stdlib_test` aborted with SIGABRT
  on an OOB `Bytes.unsafe_blit` inside `try`; green: caught as
  `invarg=...,-17,-18`. Added `test/ccalls_test.ml` pinning the ABI of all
  42 stdlib-bound C externals plus the unknown-external default (`19/19`
  examples passing, `arc_delta=0`). The `Builtins` runtime-probing of
  Stdlib entry-point lambdas (host-switch `.cmi` coupling) is now a
  documented limitation — probe failures degrade to the conservative
  unknown-external path instead of silently skipping unwinding.
- 2026-11-16 (autoagent/1): Nested pure-function analysis fix (TDD) —
  `pure_defs_of_aexpr` (`lib/arc_pass.ml`) and `collect_pure_defs`
  (`lib/codegen.ml`) duplicated the same top-level-spine walk and never
  recursed into function bodies or branches, so a non-capturing helper
  defined inside a branch (e.g. inside an `if` arm, which ANF places in a
  `LetJoin` rhs) missed the pure set: `arc_pass` owned its binding and
  emitted `Release` at its last use, while `codegen` compiled it with
  `has_closure = false` and had to synthesize an immortal static closure
  wrapper (`clos.N`) just to feed those `arc_release_val` calls (observed in
  the QBE IL of `let f x = if x > 0 then let helper y = y + 1 in helper x
  else x - 1`). Replaced both walks with a single shared, fully recursive
  `Anf.pure_defs` (function bodies + `LetJoin` rhs + `If`/`Switch`/
  `StringSwitch`/`StaticCatch`/`TryWith`/`While`/`For`/`CheckExn` +
  instruction continuations; nested defs may capture enclosing pure ids).
  Added `test/pure_nested_test.ml` (red: branch helper released 2×, nested
  `let rec` pair released 2×/1×; green: 0 releases, controls — toplevel
  helper already static, capturing helper still owned — preserved). `19/19`
  examples pass. Documented in [perceus-arc](/concepts/perceus-arc.md).
- 2026-11-16 (autoagent/1): `Lstaticraise` in let-RHS fix (TDD) —
  `Anf.conv_bind` (`lib/anf.ml`) raised `Unsupported "static raise"` for an
  `Lstaticraise` used as a let binding RHS, while `conv_expr` lowers the same
  node fine in tail position. The pattern matcher's tuple-let optimization
  (`Matching.assign_pat` / `simple_for_let`) emits `Llet` chains whose tail is
  a guard-failure `Lstaticraise` (e.g. `(let (y = 4 x = 3) (exit 1 x y))`), and
  `conv_bind` recurses through the bodies of RHS-lets (`Llet`/`Lmutlet`/
  `Lletrec`/`Lsequence`), so such a chain bound by an outer `let` failed to
  compile. Fixed by lowering `Lstaticraise (i, args)` in `conv_bind` as a
  terminator via `conv_atoms args (fun vs -> StaticRaise (i, vs))` — the bound
  continuation is unreachable and dropped, matching `conv_expr`. Added
  middle-end regression test `test/anf_staticraise_test.ml` (`dune runtest`;
  red: `conv error: static raise` for let-RHS and atom-arg cases; green:
  `StaticRaise` lifted with the staticcatch handler preserved). `19/19`
  examples pass. Documented in
  [compiler pipeline](/concepts/compiler-pipeline.md).
- 2026-11-16 (autoagent/1): MutLet double-release fix (TDD) — a mutable slot
  in scope across a `LetJoin` rhs, `While`/`For` condition/body, or loop exit
  was released multiple times: `Halt` unconditionally emitted
  `emit_mut_releases env.muts` even when the `Halt` flows into a join
  continuation instead of leaving the function, and the synthesized
  `While`/`For` loop-exit continuations also released `env.muts`. Fixed in
  `lib/arc_pass.ml` with a `no_release_muts` field on the ARC pass state (set
  to `env.muts` when descending into join rhs / loop regions); `Halt` now
  releases `env.muts - env.no_release_muts` and loop-exit continuations
  release nothing (the continuation's own scope exit releases each slot
  exactly once). Latent today — OCaml 5.5's frontend emits no `Lmutlet` into
  `Lambda.program` (no local `let mutable` syntax; `Tmc.rewrite`/`eliminate_ref`
  only run in backends ocamlcc skips) — but would corrupt any future
  `[@tail_mod_cons]` or local-mutable lowering. Added middle-end regression
  test `test/arc_mutlet_test.ml` driving hand-written `Lmutlet` Lambda terms
  through `Anf.of_lambda` + `Arc_pass.run` (red: letjoin 3 / while 4 / for 3
  releases; green: 1 each) via `dune runtest`. Corrected the wrong
  "released on all exits" claim in
  [perceus-arc](/concepts/perceus-arc.md) (`19/19` examples passing).
- 2026-11-16 (autoagent/1): Functional-value compare fix (TDD) — added a
  `total` flag to `val_compare_raw` in `runtime/arc.c` so ordered comparison
  (`compare`, `<`, `<=`, `>`, `>=` via `caml_compare`/`caml_lessthan`/
  `caml_lessequal`/`caml_greaterthan`/`caml_greaterequal`) raises
  `Invalid_argument "compare: functional value"` for `ARC_TAG_CLOSURE` and
  `ARC_TAG_PAP` values, while `( = )`/`( <> )` (`caml_equal`/`caml_notequal`,
  `total = 0`) keep physical (address) comparison on closures — matching real
  OCaml semantics. Registered the five total-compare `Ccall`s (plus the
  previously missed `ocamlcc_weak_get_copy`) in `ce_may_raise_fn`
  (`lib/arc_pass.ml`) so `TryWith` unwinds live values when compare raises.
  Probe `fncompare=true,true,false,true` in `examples/stdlib_test.ml` +
  `tests/stdlib_test.expected` (red run observed `false,false,false,true`)
  (`19/19` passing, `arc_delta=0`).
- 2026-11-16 (autoagent/1): `Weak.get_copy` aliasing fix (TDD) — replaced
  `let get_copy = get` in `stdlib/stdlib__weak.ml` with a real
  `ocamlcc_weak_get_copy` primitive (`runtime/arc.c`/`runtime/arc.h`,
  registered as potentially raising in `ce_may_raise_fn`,
  `lib/arc_pass.ml`) that copies the stored block one level deep (same
  `tag`/`scan_fields`/`byte_size`, scanned fields retained, no wrap-retain —
  the fresh block's refcount 1 is exactly balanced to one free by the
  caller's field-read retain + `Some` drop + binding release), matching real
  OCaml semantics where mutating the copy never affects the stored element.
  The probe in `examples/stdlib_test.ml` (`weak_copy=20,10,true,10` in
  `tests/stdlib_test.expected`) also surfaced two learning points captured in
  [perceus-arc](/concepts/perceus-arc.md): the ARC pass releases a binding
  mid-expression right after its last read (so probes must finish
  observations before the target's last use), and the earlier `check=false`
  observations were correct drop-after-last-use behavior, not a runtime bug.
  (`19/19` passing, `arc_delta=0`).
- 2026-11-16 (autoagent/1): `List.init` effect-order fix (TDD) — rewrote
  `init` in `stdlib/stdlib__list.ml` to invoke `f` in order `0..len-1`
  (tail-recursively accumulating `f i :: acc` with an ascending index, then
  `rev`), matching the documented stdlib contract. Previously `f` was
  invoked in reverse order `len-1..0` while still producing the correct
  value list. Added an effect-order probe to `examples/stdlib_test.ml` that
  logs each `f i` invocation (`listinit=0123,true` in
  `tests/stdlib_test.expected`; red run observed `listinit=3210`)
  (`19/19` passing, `arc_delta=0`).
- 2026-11-16 (autoagent/1): Binary-safe string output — record the string
  payload length from `ArcHeader.reserved` in the codegen/runtime I/O path and
  write explicit byte counts, preserving embedded NULs in `print_string`,
  `print_endline`, and `print_char`. Documented the invariant in
  [value representation](/concepts/value-representation.md).
- 2026-11-16 (autoagent/1): `int_of_string` radix/overflow fix (TDD) —
  rewrote `int_of_string_opt` in `stdlib/stdlib.ml` to support `0x`/`0o`/`0b`
  (and unsigned `0u`) radix prefixes with OCaml-accurate semantics:
  decimal parses strictly in range (overflow now yields `None`/`Failure`
  instead of wrapping into `min_int`), non-decimal radices wrap as in OCaml,
  `min_int` is parseable via negative accumulation, and `_` separators are
  skipped after the first digit (`_100`/`0x_ff` rejected, `100_`/`1__000`
  accepted). Verified by a 56-input differential against real OCaml 5.5 and
  extended `examples/stdlib_test.ml` + `tests/stdlib_test.expected` (`19/19`
  passing, `arc_delta=0`).
- 2026-11-16 (autoagent/1): `Printf.eprintf` stderr routing fix (TDD) —
  added `pal_stderr_write` in `runtime/pal.h`/`runtime/pal.c` and
  `ocamlcc_prerr_string_val` in `runtime/arc.h`/`runtime/arc.c` (using
  `ArcHeader.reserved` length without modifying `runtime/builtins.c`), and
  factored `printf_to` in `stdlib/stdlib__printf.ml` so `eprintf` writes to
  `stderr` rather than `stdout`. Extended `examples/stdlib_test.ml` (`19/19`
  passing, stdout diff excludes `eprintf` output and `stderr` verified
  separately with `arc_delta=0`).
- 2026-11-16 (autoagent/1): `Printf` `%S` and `%C` escaping & quoting fix
  (TDD) — added `add_escaped_char`, `format_caml_char`, and
  `format_caml_string` in `stdlib/stdlib__printf.ml` to emit OCaml-escaped
  literals wrapped in `'...'` (`%C`) and `"..."` (`%S`), including `\n`, `\r`,
  `\t`, `\b`, `\\`, `\"`/`\'`, and `\ddd` decimal escapes for control/non-ASCII
  bytes. Extended `examples/stdlib_test.ml` and `tests/stdlib_test.expected`
  (`19/19` passing, `arc_delta=0`).
- 2026-11-16 (autoagent/1): `Printf` integer zero-padding & precision fix
  (TDD) — replaced `format_int` + post-hoc string padding in
  `stdlib/stdlib__printf.ml` with `format_int_padded`, `with_pad_spec`, and
  `with_prec_spec` so integer precision zero-pads digits before prepending
  sign/alternate prefixes and `Zeros` padding (`%05d`, `%#05x`, `%0*d`)
  inserts `'0'`s between the prefix and digits (while negative dynamic widths
  left-align with spaces). Extended `examples/stdlib_test.ml` and
  `tests/stdlib_test.expected` (`19/19` passing, `arc_delta=0`).
- 2026-11-16 (autoagent/1): `Printf` integer formatting fix (TDD) — updated
  `format_int` in `stdlib/stdlib__printf.ml` to accumulate negative magnitudes
  for signed specifiers (`%d`/`%i`, avoiding `-min_int` overflow/punctuation)
  and split negative inputs with `(v lsr 1)` / `(v land 1)` for 63-bit
  unsigned specifiers (`%u`/`%x`/`%X`/`%o`, avoiding `/` on `-1`). Extended
  `examples/stdlib_test.ml` and `tests/stdlib_test.expected` (`19/19` passing,
  `arc_delta=0`).
- 2026-11-16 (autoagent/1): Raising `while` condition terminator fix (TDD) —
  guarded `While` loop condition emission in `lib/codegen.ml` on
  `if b.term = None` so conditions that unconditionally raise/terminate do not
  emit `Cmp`/`Br` after a closed block terminator. Extended `examples/exn.ml`
  and `tests/exn.expected` (`19/19` passing, `arc_live = 0`).
- 2026-11-16 (autoagent/1): `for` loop integer-limit wrap fix (TDD) —
  updated `For` lowering in `lib/codegen.ml` to check the initial `sv <= ev` /
  `sv >= ev` entry condition once before entering `@fbody`, then test `iv < ev`
  / `iv > ev` at `@fstep` before adding `±2L` to `iv` in `@fnext`, avoiding
  63-bit counter wraparound at `max_int` and `min_int`. Extended
  `examples/loops.ml` and `tests/loops.expected` with boundary `max_int`/`min_int`
  `to`/`downto` probes (`19/19` passing).
- 2026-11-16 (autoagent/1): Safe indexing & invalid size `Invalid_argument`
  (TDD) — updated `ce_may_raise_fn` in `lib/arc_pass.ml` for safe
  `StringGet`/`BytesSet`/`ArrayGet`/`ArraySet`, `CreateBytes`, `MakeArrayInit`,
  and `ocamlcc_weak_*`; added `ocamlcc_raise_invalid_arg_oob` and converted
  invalid lengths/indices in `arc_alloc_bytes`, `arc_alloc_array` (releasing
  consumed `init`), and `ocamlcc_weak_*` in `runtime/arc.c` (+16-byte
  alignment on immortal strings/predef exns) to raise `Invalid_argument`;
  replaced `pal_abort` in `lib/codegen.ml` bounds checks with
  `compile_bounds_guarded` (releasing consumed RHS on OOB `ArraySet`). Extended
  `examples/stdlib_test.ml` and `tests/stdlib_test.expected` (`19/19` passing,
  `arc_delta=0`).
- 2026-11-15 (autoagent/1): Division/modulo by zero exception check (TDD) —
  marked `Binop ((Div | Mod), _, _)` as potentially raising in
  `ce_may_raise_fn` (`lib/arc_pass.ml`) so `TryWith` retains live bindings and
  `CheckExn` unwinds frame values on failure; added `compile_div_mod` in
  `lib/codegen.ml` to branch on zero divisor (`jnz uc`) before emitting
  machine `div`/`rem` and store `ocamlcc_global_Division_by_zero` into
  `ocamlcc_exn_slot`; extended `examples/stdlib_test.ml` and
  `tests/stdlib_test.expected` covering `1 / 0`, `1 mod 0`, direct &
  indirect divisor checks, and ARC unwind (`19/19` passing, `arc_delta=0`).
- 2026-11-15 (autoagent/1): Review hardening & packaging fixes (with TDD
  regressions) — fixed `TryWith` in `lib/arc_pass.ml` to keep `frame_borrowed`
  vars in `body_env.try_owned`; changed `GetGlobal` `arc_retain_val` call to
  `Call_void` in `lib/codegen.ml`; fixed direct over-application in
  `lib/codegen.ml` to check `ocamlcc_exn_slot`, release unconsumed
  `rest_vals` on first-stage exception, and release intermediate `clos_res`;
  fixed `drop_child_val` in `runtime/arc.c` to register surviving decremented
  children in `g_cc_roots`; fixed `release_subtree` in `runtime/arc.c` to run
  `weak_clear_target` on dying `ARC_TAG_WEAK` arrays after `weak_unlink`;
  fixed `rule run_test` exit-status masking in `build.ninja`, tightened
  `ocamlcc.opam` OCaml lower bound to `>= "5.3" & < "5.6"`, added
  `(public_name ocamlcc)` in `bin/dune`, added OKF frontmatter to
  `perceus-arc.md`, and promoted `wren-fibers.md` + `platform-abstraction-layer.md`
  docs. Extended `examples/exn.ml`, `examples/cycle_collect.ml`, and
  `examples/weak_cycle.ml` (19/19 passing).
- 2026-11-15 (autoagent/1): Phase 3 Wren-style stackful fibers & async I/O
  poller — added assembly context switch (`runtime/pal_ctx.S` for arm64 and
  x86_64), real `kqueue`/`epoll` OS poller + non-blocking fd/pipe helpers in
  `runtime/pal.c`, ARC-managed `ARC_TAG_FIBER` (`250`) objects in
  `runtime/arc.c` with `fiber_destroy` cleanup on abandoned fibers, full Wren
  coroutine (`create`/`resume`/`suspend`/`is_done`) + cooperative scheduler
  (`spawn`/`yield`/`sleep_ms`/`fd_wait_read`/`fd_wait_write`/`await`/`run_all`)
  with per-fiber `ocamlcc_exn_slot` preservation in `runtime/fiber.c`. Added
  static fixed-point yield-effect inference (`compute_yield_info`) and
  `ShadowPush`/`ShadowPop` lowering (covering values, `muts`, and open Perceus
  reuse tokens) across `lib/anf.ml`, `lib/arc_pass.ml`, and `lib/codegen.ml`,
  plus `stdlib/stdlib__fiber.ml` (`Stdlib.Fiber`) and checked tests
  `fiber_test` & `fiber_io` (19/19 passing, zero ARC leaks).
- 2026-11-15 (autoagent/1): Pre-Phase-3 ARC cycle hardening — added compiler
  warning in `lib/codegen.ml` (`compile_letrec`) when non-pure mutual
  `let rec` closures capture sibling closures in a cycle; implemented opt-in
  Bacon-Rajan trial-deletion cycle collector (`ocamlcc_arc_collect`) in
  `runtime/arc.h`/`runtime/arc.c` using 16-byte `ArcHeader.reserved` color and
  buffered root tracking with zero changes to `runtime/builtins.c`. Added
  `examples/cycle_collect.ml` + `tests/cycle_collect.expected` covering both
  cyclic mutual closures and mutable record cycles (17/17 passing,
  `arc_live () = 0`).
- 2026-11-15 (autoagent/1): Phase 5 multi-module linking and ARC-native core
  stdlib — added multi-module compilation (`.mli` → `.cmi` via
  `compile-mli`, `--mod` / `-I` / `--nostdlib` / `--nopervasives` /
  `--emit-cmi` / `--cmi-prefix`), `GetGlobal` lowering with idempotent
  dependency-driven `$ocamlcc_init_<Mod>()` and `$ocamlcc_global_<Mod>` slots,
  `Pisout` and `Pduparray` lowering, and Darwin arm64 `R18` avoidance in
  vendored QBE (`IP1` scratch in `vendor/qbe/arm64/`). Added structural
  comparison/hashing (`caml_equal`, `caml_compare`, `caml_hash`, etc.),
  bytes/string primitives (`caml_blit_*`, `caml_fill_bytes`, `caml_*_equal/compare`),
  tagged I/O wrappers, and 12 singleton predef exception constructors in
  `runtime/arc.c` while keeping `runtime/builtins.c` minimal. Implemented
  ARC-native `stdlib/` (`CamlinternalFormatBasics`, `Option`, `Result`,
  `List`, `Array`, `Bytes`, `String`, `Buffer`, `Hashtbl`, `Printf`, `Weak`,
  `Stdlib`) built into `build/stdlib/libocamlstdlib.a`. Added `mod_main`
  and `stdlib_test` (16/16 passing, zero ARC leaks).
- 2026-11-15 (autoagent/1): Phase 2 Perceus ARC, freestanding slab
  allocator, zero-leak exceptions, and Weak references — replaced
  `malloc`/`free` in `runtime/arc.c` with a 12-class freestanding slab
  allocator (`64 KB` slabs + `16 KB`-aligned large blocks) over
  `pal_page_alloc`/`pal_page_free`; implemented O(1)-stack tail-drop
  `arc_release`, Perceus `arc_drop_reuse`/`arc_alloc_reuse`/`arc_free_reuse`,
  balanced ARC refcounting in `runtime/closure.c`, `ARC_TAG_WEAK` weak arrays
  with automatic dead-target clearing, and `caml_fresh_oo_id` /
  `ocamlcc_exn_slot` while keeping `runtime/builtins.c` minimal. Added
  `lib/arc_pass.ml` for static dup/drop/reuse/borrow/exception-unwind
  insertion over ANF, zero-leak error-return exceptions (`Ltrywith`/`Praise`),
  and `Pccall` lowering in `Anf`/`Codegen`. Three new checked tests
  (`arc_test`, `exn`, `weak_cycle`; 14/14 passing).
- 2026-11-15 (autoagent/1): Heap blocks, full ADT pattern matching, closures,
  and control/bitwise primitives — added QBE memory load/store/alloc8 and
  structured data items; `arc_alloc` block allocation, field load/store,
  immortal `Const_block` data with `ArcHeader`, `Lswitch` with `sw_blocks` +
  `ArcHeader.tag` dispatch, `Pisint`, `while`/`for`/`Lmutlet`/`Lassign`,
  bitwise/short-circuit/comparison primitives; closure conversion with
  free-variable capture (`ArcClosure`), lazy immortal wrappers for pure
  functions, partial & over-application (`ArcPap` + `runtime/closure.c`),
  local recursive & mutually recursive closures, and SSA phi joins across
  all branches. Three new checked tests (`adt`, `closures`, `loops`; 10/10
  passing).
- 2026-11-13 (autoagent/1): Match lowering — `Lswitch` desugared to
  comparison chains; `Lstaticraise`/`Lstaticcatch` lowered with per-binder
  phis and two-way joins (integers and constant constructors). Mutual tail
  recursion: tail-call graph + SCC analysis groups mutually tail-recursive
  functions into single trampoline functions with a selector argument and
  uniform phi slots; `even`/`odd` ping-pong 100k in constant stack. Two new
  checked tests (`match`, `mutual`).
- 2026-11-13 (autoagent/1): Phase 1 increment — top-level/recursive function
  definitions with direct calls, self-tail-call loop lowering via QBE phi
  nodes (constant stack space), booleans as values, string literals via QBE
  data emission with `print_string`/`print_endline` runtime builtins, and
  `ninja test` (5 checked examples). Re-vendored QBE from the official 1.2
  release tarball (the sr.ht dev snapshot used phi-less IL and was replaced);
  updated build-pipeline and value-representation concepts with the QBE
  gotchas learned.
- 2026-11-13 (autoagent/1): Initial bundle produced during project
  initialization — captured the design document (`docs/design.md`), the
  scaffolded pipeline (compiler, build, runtime), and the planned ARC/fiber
  designs as draft concepts.
