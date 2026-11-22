# Change Log

- 2026-11-22 (codex/1) — Isolate ANF lowering state per compilation. Extract the Lambda optimizer, shared ANF model, and scalar selection pass, and consolidate boxed integer operations by width and operation. Build the new modules in each bootstrap stage. See [ANF lowering](/concepts/compiler-pipeline.md#anf-lowering).

- 2026-11-22 (codex/1) — Centralize filesystem and process operations in `Sys_util`. Return SSA, the CMI path, and export facts from the typed [compiler pipeline](/concepts/compiler-pipeline.md#compilation-requests).

- 2026-11-22 (codex/1) — Compatibility Array.fill, Array.sub, Bytes.fill and Bytes.sub call native bulk kernels after upstream validation, preserving bounds errors and checked compatibility entry points.

- 2026-11-22 (codex/1) — Lower counted loop poll phases from raw indices, tag indices on demand, and preserve proven stack-slot and option borrows through local reads.

- 2026-11-22 (codex/1) — Preserve immutable block layout and omit scans for unmanaged fields. Keep the lock-free cycle-root eligibility guard inline and restore scan counts on computed pointer stores.

- 2026-11-22 (codex/1) — Borrowed calls accept stack-slot and immutable projection arguments while preserving owned dispatch for dying values and mutable field snapshots.

- 2026-11-22 (codex/1) — Borrow mutable array projections across read-only index expressions and inline verified Uchar scalar-range fast paths. Tterm paired replay improved 2.5% plain and 10.2% Unicode (default), 4.1% plain and 12.4% Unicode (single-thread RC). Against Round 4 in a fresh stock-paired run, Round 5 improved 4.1% plain and 26.6% Unicode (default), 8.6% plain and 26.4% Unicode (single-thread RC). All 1,758 parser assertions match stock OCaml 5.5.0.

- 2026-11-22 (codex/1) — Retire small immediate-only blocks without a subtree worklist and skip their registration under single-thread ownership. Tterm paired replay changed -0.4% plain and -2.2% Unicode (default), +0.4% plain and -4.0% Unicode (single-thread RC). Native cycle, weak, ASan and TSan tests passed.

- 2026-11-22 (codex/1) — Publish compatibility stdlib object summaries during assembly and retain borrowed candidates across nested definitions and inlined value aliases. Tterm paired replay changed +5.8% plain and -5.9% Unicode (default), -1.9% plain and -8.4% Unicode (single-thread RC). Parser allocation medians were identical.

- 2026-11-22 (codex/1) — Fuse finalizer poll fast paths, throttle bounded self-tail loops, and branch directly from single-use short-circuit joins. Tterm paired replay improved 3.2% plain and 1.8% Unicode (default), 3.9% plain and 4.0% Unicode (single-thread RC).

- 2026-11-22 (codex/1) — Use a single nullable heap predicate, skip ARC guards after receiver dereferences, and share the raw for-loop index. Tterm paired replay changed by +0.4% plain and -5.7% Unicode (default) and +0.9% plain and -3.2% Unicode (single-thread RC). Parser allocation medians were identical.

- 2026-11-22 (codex/1) — Prove guarded indexes against fixed sizes from the selected Stdlib Array.init and record the Round 4 tterm comparison. See [Perceus ARC](/concepts/perceus-arc.md#round-4-tterm-replay).

- 2026-11-22 (codex/1) — Bypass ARC traversal for unmarked leaf releases and use direct slab size-class lookup. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Keep single-thread ARC compact on exception cleanup paths. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Bind compatibility Array, Bytes, and String kernels directly and expose the immediate Uchar conversion. See [stdlib compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-22 (codex/1) — Skip TLS on empty exception checks and load the single-thread slot directly. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Borrow sole receivers through child stores and carry checked slot snapshots into lazy option joins. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Preserve owning call entries for dying imported arguments so callee reuse remains available. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Centralize fiber-owned values and stack teardown for ARC and trial deletion. See [Wren-style stackful fibers](/concepts/wren-fibers.md#owned-values-and-stack-teardown).

- 2026-11-22 (codex/1) — Compile the bounds pass before ANF in bootstrap and exercise v1 export compatibility with a seven-field fixture. See [Self-hosting](/concepts/self-hosting.md).

- 2026-11-22 (codex/1) — Isolate TLS materialization behind cold foreign-release calls. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Store fresh float results directly into mutable fields and reuse uniquely owned boxes. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Borrow payloads from lazy option slot joins. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Elide redundant bounds checks before inferring escaping exceptions. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Keep foreign release bookkeeping off ordinary ARC subtree drops. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Publish borrowed parameter masks for direct cross-unit calls. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-22 (codex/1) — Keep mutating receivers eligible for borrowed ARC parameters. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Preserve thread-local slab spill order and age out old slots only in the process-owned magazines. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Exercise mutable snapshots and array scan promotion using the standalone smoke-test primitives. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Cover borrowable mutable projections and the owning snapshot required across callbacks in the immediate-access suite. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Reuse cached slab slots across allocation boundaries in the single-thread runtime and drain older entries from full magazines. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Skip ARC destruction, cycle candidacy, and bulk tag scans on word arrays known to contain only immediates. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Fuse a mutable field projection with its immediate read-only consumer. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Preserve borrowed parameters across non-suspending calls when those calls do not take ownership of the parameter. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Borrow local mutable-slot snapshots through read-only uses and reload branch results from a common owning slot. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Guard exception checks at calls that only raise through automatic finalizers, poll counted loops every 64 iterations, and omit zero checks for literal nonzero divisors. See [ARC finalizers](/concepts/arc-finalizers.md).

- 2026-11-21 (codex/1) — Read slab magazines from thread-local storage, batch mixed-slab frees, and skip the automatic finalizer poll call when the registration count is zero. See [Perceus ARC](/concepts/perceus-arc.md) and [ARC finalizers](/concepts/arc-finalizers.md).

- 2026-11-21 (codex/1) — Route checked indexing errors directly to ARC cleanup and infer whether saturated calls can raise. Persist the raising flag in export summaries. See [Perceus ARC](/concepts/perceus-arc.md) and [build pipeline](/concepts/build-pipeline.md#persisted-export-summaries).

- 2026-11-21 (codex/1) — Apply extended field-view borrowing only when a loop uses the view, preserving early reuse in ordinary list matches. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Borrow immutable field views across loops and branches and track the receiver through each use. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Inline small imported Lambda aggregate producers before local scalar replacement in multi-unit builds. Keep the provider's initialization dependency. See [compiler pipeline](/concepts/compiler-pipeline.md#inlining-imported-aggregate-producers).

- 2026-11-21 (codex/1) — Propagate tagged literals and store captures rooted by published module functions in private module slots. See [compiler pipeline](/concepts/compiler-pipeline.md#captures-rooted-by-a-module).

- 2026-11-21 (codex/1) — Carry tagged-immediate value kinds through ANF bindings, mutable slots, static catches, and saturated function returns. See [value representation](/concepts/value-representation.md#tagged-immediate-binders).

- 2026-11-21 (codex/1) — Batch small-slot transfers through bounded per-thread magazines in the default ARC runtime. Drain cached slots at thread exit so fully retired slabs can be unmapped. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Remove slab locking and atomic counter read-modify-write operations from the single-thread ARC profile. Enforce the same owner at standalone collector entry. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Remove ARC guards on proven heap values and combine the tag and null tests for unknown values. Keep checked allocation proofs on the success path. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-21 (codex/1) — Keep eligible mutable numeric accumulators in typed raw stack slots and box at scope exit. Verify typed flat-float array accumulators in both imperative and self-tail loops. See [value representation](/concepts/value-representation.md#mutable-numeric-slots).

- 2026-11-21 (codex/1) — Publish .exports for loose stdlib objects and separate -c builds. Resolve metadata from the selected interface and bind direct entries to the implementation. See [build pipeline](/concepts/build-pipeline.md#persisted-export-summaries).

- 2026-11-21 (codex/1) — Flatten strict Lambda bindings after inlining so returned refs and immutable blocks can be scalar-replaced. Support up to four fields in direct bindings and matching branch joins. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Inline known local functor applications and resolve calls through their immutable module fields. See [compiler pipeline](/concepts/compiler-pipeline.md#local-functor-applications).

- 2026-11-20 (codex/1) — Persist direct-call facts with bundled and compatibility stdlib archives. Use matching archive and interface digests when compiling separately linked clients. See [build pipeline](/concepts/build-pipeline.md).

- 2026-11-20 (codex/1) — Honor native representations and noalloc for user C externals. Check for exceptions before boxing raw numeric results. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Carry float and boxed-integer inputs in raw QBE self-tail loop phis. Preserve boxed seeds and published values at the ordinary OCaml boundary. See [value representation](/concepts/value-representation.md).

- 2026-11-20 (codex/1) — Scalar-replace local aggregates with the same constructor shape across conditional and match branches. Carry components through a shared continuation. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Inline heap retain and eligible shared release updates for the single-thread ARC profile. Require its entry symbol and verify cycle collection through generated code. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Keep typed float-array and boxed-integer arithmetic in local scalar temporaries. Box at ordinary value uses and preserve numeric exception paths. See [value representation](/concepts/value-representation.md).

- 2026-11-20 (codex/1) — Replace non-escaping tuple and option blocks with their local components. Preserve initializer evaluation and escaping block identity. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Infer borrowed argument positions across static recursive groups and saturated forwarding calls. Preserve owning entries and test long mutual recursion. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Keep typed immediate field stores and inline heap checks for pointer-capable field and array ownership. Cover overwrites and checked-store errors. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Resume shallow continuations with fresh handlers on the same effect fiber. Check handler replacement and cancellation against stock OCaml. See [Wren-style fibers](/concepts/wren-fibers.md#ocaml-5-effect-handlers).

- 2026-11-20 (codex/1) — Run OCaml Deep handlers and effect-pattern syntax on stackful fibers. Cover one-shot continuation ownership, forwarding, exception injection, and Wren suspension. See [Wren-style fibers](/concepts/wren-fibers.md#ocaml-5-effect-handlers).

- 2026-11-20 (codex/1) — Branch over generated shadow-stack calls before first stackful fiber creation. Keep the runtime cleanup protocol for stackful frames. See [Wren-style fibers](/concepts/wren-fibers.md).

- 2026-11-20 (codex/1) — Align 64 KiB slabs through PAL and recover the owner from the slot address. Cover full slabs, large mappings, and warm-slab reclamation. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Fuse QBE comparison branches and fold tag corrections into constant integer arithmetic. Cover mixed boolean uses and wraparound. See [value representation](/concepts/value-representation.md).

- 2026-11-20 (codex/1) — Return from empty finalizer polls after reading the registration count. Preserve ready-queue handoff and explicit cycle collection. See [ARC finalizers](/concepts/arc-finalizers.md).

- 2026-11-20 (codex/1) — Follow bounded branches and local mutable slots when placing finalizer polls. Check every 64 condition evaluations in bounded while loops. See [ARC finalizers](/concepts/arc-finalizers.md).

- 2026-11-20 (codex/1) — Use native kernels for array fill, blit, and sub. Check the actual tagged slices and keep ownership-aware copies for pointer payloads. See [stdlib compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-20 (codex/1) — Use PAL memmove and memset for checked byte and string bulk operations. Cover aliased string views and empty slices. See [stdlib compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-20 (codex/1) — Track cross-unit exports through immutable Lambda blocks and their signature coercions. Exercise reordered slots and a hidden nested member in the native driver test. See [compiler pipeline](/concepts/compiler-pipeline.md#cross-unit-calls).

- 2026-11-20 (codex/1) — Bypass shadow-stack TLS before the first stackful fiber and skip shadow entries on root stacks. Preserve stackful abandonment cleanup. See [Wren-style fibers](/concepts/wren-fibers.md).

- 2026-11-20 (codex/1) — Resolve saturated cross-unit calls from build-local export summaries, inline scalar leaves, and carry suspension facts into ARC. See [compiler pipeline](/concepts/compiler-pipeline.md#cross-unit-calls).

- 2026-11-20 (codex/1) — Use raw closure application for generated OCaml calls, with direct fixed-arity dispatch and mutator boundaries at host entry. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Promote non-escaping refs and equivalent mutable blocks to local slots before ANF. Reuse immediate-slot inference and owning-slot cleanup. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Inline saturated local functions and specialize known callbacks before building closures or inserting ARC. See [compiler pipeline](/concepts/compiler-pipeline.md#local-inlining-and-known-callbacks).

- 2026-11-20 (codex/1) — Test the immediate tag and null inline for explicit ARC operations in QBE. Call the pointer retain or release helper on the heap path. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Infer unmanaged static handler arguments and join results, and elide ARC and shadow roots for local slots with only unmanaged writes. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Skip duplicate cycle-root lock acquisitions on shared drops. Keep collection through untouched members of cycles after a live trial. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Skip weak-target lookup on unmarked ordinary object drops and cycle reclamation. Preserve weak clearing across storage reuse, copying, and dummy updates. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Borrow immutable backing storage through local reads and a final array or byte write. Cover transferred values, mutable projections, and checked-store unwinding. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Omit entry polls in bounded leaf functions and poll every 64 iterations in counted loops with allocation-free local bodies. See [ARC finalizers](/concepts/arc-finalizers.md).

- 2026-11-20 (codex/1) — Borrow immutable fields at proven local read sites and keep the receiver live through the operation. Cover mutable fields, escaping values, callback and FFI barriers, and bounds-error cleanup. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Specialize saturated calls through immutable aliases of the selected stdlib’s integer selectors. Partial and first-class uses retain ordinary closure behavior. See [compiler pipeline](/concepts/compiler-pipeline.md).

- 2026-11-20 (codex/1) — Share a dispatcher closure for capturing recursive groups. In the matched tterm parser probe, the streaming dispatch signature shrank from 16 parameters to 3, and all 4,000 calls kept the live-block count flat. See [compiler pipeline](/concepts/compiler-pipeline.md).

- 2026-11-20 (codex/1) — Lower saturated calls to the selected stdlib’s integer min and max to a signed comparison on tagged values. See [compiler pipeline](/concepts/compiler-pipeline.md).

- 2026-11-20 (codex/1) — Lift direct calls in capturing recursive groups and keep independently owned wrappers for escaping functions. The native regression retained six blocks before the change and zero afterward. See [compiler pipeline](/concepts/compiler-pipeline.md).

- 2026-11-20 (codex/1) — Carry Lambda’s immediate field kind through ANF and elide ARC traffic for those reads and integer array reads. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Add an opt-in single-OS-thread runtime with load/store refcount updates and an owner check at managed entries. The atomic runtime remains the default. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Reuse both cells in an unrolled list map and fall back to the input cell when a previously selected token cannot fill the singleton result. Extend token cleanup to branched reads and multiple outstanding tokens. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (codex/1) — Infer borrowed arguments for saturated direct calls to eligible read-only OCaml functions and emit a private entry alongside the owning entry. See [Perceus ARC](/concepts/perceus-arc.md).

- 2026-11-20 (antigravity/1): Slice 6g — Migrate `Callback` named values, backtrace stubs, and non-POSIX `Sys` helpers to pure OCaml (`stdlib/camlinternalSys.ml`, `runtime/{arc.c,builtins.c}`, `lib/{anf.ml,ccalls.ml,driver.ml}`, `tools/{stdlib_compat.py,bootstrap.py}`, `test/{ccalls_test.ml,ccalls_test.expected}`, `tests/stdlib/sys_callback/`, `build.ninja`, `dune`):
  - Deleted 22 C stubs (`caml_register_named_value`, all 10 `caml_*backtrace*`/`caml_ml_debug_info_status` stubs, `caml_sys_{executable_name,proc_self_exe,get_config,io_buffer_size,temp_dir_name,*convert_signal_number}`, `caml_runtime_{variant,parameters}`, `caml_install_signal_handler`, `caml_ml_*runtime_warnings*`), shrinking runtime C/inc LOC `7,018 -> 6,880` (`7,066` including `pal_ctx.S`, down from `9,833` at Part II start) and keeping only `ocamlcc_set_at_exit_fn`, `ocamlcc_sys_is_win32`, and raw POSIX hooks.
  - Implemented pure OCaml `--nopervasives` `stdlib/camlinternalSys.ml`, lowered `caml_restore_raw_backtrace` cleanly in `lib/anf.ml`, and wired `Stdlib`, `Callback`, `Sys`, `Printexc`, `Lazy`, and `Filename` in `tools/stdlib_compat.py`.
  - Added TDD fixture `tests/stdlib/sys_callback/` (verified against stock `ocamlc`) and updated `test/ccalls_test.ml`.
  - Verified `dune runtest -j1`, `ninja -j1 test` (26/26), `ninja -j1 asan_test` (16/16), `ninja -j1 tsan_test` (2/2), `stdlib_compat.py` (77/77 modules, 68/77 upstream tests), `stdlib_regressions.py` (17/17 including `sys_callback`), and `sh tests/run_bootstrap_stubs_tests.sh`. See [stdlib-compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-20 (antigravity/1): Slice 6f — Migrate fiber cooperative scheduler, timers, and async fd waiters to pure OCaml (`stdlib/stdlib__fiber.ml`, `runtime/{fiber.h,fiber.c}`, `lib/ccalls.ml`, `test/{ccalls_test.ml,ccalls_test.expected}`, `examples/fiber_test.ml`, `tests/{fiber_test.expected,stdlib_runtime.c,mt_ffi_host.c}`):
  - Trimmed `runtime/fiber.c` (`909 -> 519` LOC; total runtime C/inc `7,408 -> 7,018` LOC, `7,204` including `pal_ctx.S`) down to guard-paged C stacks, `pal_ctx_*` swaps, shadow/reuse stack management, and thin TLS/poller hooks (`ocamlcc_fiber_{is_main,can_yield,sched_get,sched_set}`, `ocamlcc_monotonic_ns`, `ocamlcc_poller_{watch,unwatch_waiter,wait}`).
  - Implemented cooperative FIFO ready queue, timer deadline list, `await` waiter propagation/cycle detection, and async fd waiter dispatch in `stdlib/stdlib__fiber.ml` using acyclic task records wrapping raw coroutines, resetting TLS scheduler state to `None` when idle.
  - Added TDD scheduler edge tests in `examples/fiber_test.ml` (`test_sched_edges`: timer ordering, multi-waiter fanout, invalid fd, self-await, finalizer guard across all 5 fiber ops; `delta=0`) and updated `test/ccalls_test.ml` and C runtime tests.
  - Verified `dune runtest -j1`, `ninja -j1 test` (26/26), `ninja -j1 asan_test` (16/16), `ninja -j1 tsan_test` (2/2), `stdlib_regressions.py` (16/16), and `sh tests/run_bootstrap_stubs_tests.sh`. See [wren-fibers](/concepts/wren-fibers.md).

- 2026-11-20 (antigravity/1): Slice 6d — Migrate buffered `in_channel` / `out_channel` to pure OCaml and delete C `OcamlccChannel` (`stdlib/camlinternalChannel.ml`, `stdlib/camlinternalMarshal.ml`, `runtime/{arc.h,arc.c,bigarray.inc}`, `bootstrap/unix/unix.ml`, `lib/{ccalls.ml,driver.ml}`, `tools/{stdlib_compat.py,bootstrap.py}`, `tests/{stdlib_runtime.c,stdlib/channels/}`, `build.ninja`, `dune`):
  - Deleted `ARC_TAG_CHANNEL`, `OcamlccChannel`, `g_out_channels_head`, `channel_destroy`, `chan_*`, all `caml_ml_*` channel functions, and `caml_sys_isatty` (`7,894 -> 7,408` C/inc runtime LOC; `7,594` including `pal_ctx.S`), leaving only thin POSIX fd shims (`ocamlcc_raw_fd_{read,write,lseek,size,close,isatty}`, `ocamlcc_stdio_flush`) and `ocamlcc_ba_{to_bytes,of_bytes_slice}`.
  - Implemented pure OCaml `--nopervasives` `stdlib/camlinternalChannel.ml` (4096-byte `bytes` buffering, mutex-guarded weak out-channel registry for `flush_all`, unbuffered mode, 64-bit `LargeFile` seeks/lengths, binary 32-bit ints, `input_scan_line`, and Bigarray 1D `char` slice transfers) and wired `CamlinternalMarshal`, `Stdlib`, `In_channel`, `Out_channel`, and `Unix.in_channel_of_descr` onto it. Also cleaned stale `runtime/marshal.inc` entry in root `dune`.
  - Added TDD fixture `tests/stdlib/channels/` (verified against stock `ocamlc`) and updated `tests/stdlib_runtime.c` Bigarray/bounds coverage onto the new thin C shims.
  - Verified `dune runtest -j1`, `ninja -j1 test` (26/26), `ninja -j1 asan_test` (16/16), `ninja -j1 tsan_test`, `stdlib_compat.py` (76/76 modules, 68/77 upstream tests), `stdlib_regressions.py` (16/16 including `channels`), and `sh tests/run_bootstrap_stubs_tests.sh` (native + ASan). See [stdlib-compatibility](/concepts/stdlib-compatibility.md) and [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-20 (antigravity/1): Slice 6e — Migrate Marshal (`0x8495a6be`/`bf` + `0x8495a6bd` compressed codec hook) to pure OCaml and delete `runtime/marshal.inc` (`stdlib/camlinternalMarshal.ml`, `runtime/{arc.h,arc.c,bigarray.inc}`, `bootstrap/stubs/compiler_stubs.c`, `lib/{ccalls.ml,driver.ml}`, `tools/{stdlib_compat.py,fetch-ocaml-compiler-libs.py,bootstrap.py}`, `examples/stdlib_test.ml`, `tests/stdlib/marshal_hardening/`, `tests/bootstrap_stubs_test.c`, `build.ninja`):
  - Deleted `runtime/marshal.inc` (-690 C LOC; +~80 lines of tiny runtime introspection/bigarray-bytes helpers; `8,688 -> 7,894` total runtime LOC) and removed `ocamlcc_marshal_register_codec`, `caml_output_value*`, `caml_input_value*`, and `caml_marshal_data_size` from `runtime/` and `lib/ccalls.ml`.
  - Implemented pure OCaml `--nopervasives` `stdlib/camlinternalMarshal.ml` (open-addressed pointer map, explicit work stack, `No_sharing` cycle rejection, `Compat_32`, `_bigarr02` serialization, bounded 64 KiB channel reads against multi-GB DoS, `owners` cycle-severing cleanup on error, and `CamlinternalMarshal.register_codec` wired into `Compression` via thin `ocamlcc_zstd_{compress,decompress}_bytes` in `bootstrap/stubs/compiler_stubs.c`).
  - Added TDD fixture `tests/stdlib/marshal_hardening/` (verified against stock `ocamlc`) and ported compressed RLE codec / DoS / cycle cleanup leak tests into `examples/stdlib_test.ml` (`arc_delta=0` under native and ASan) + updated `tests/bootstrap_stubs_test.c`.
  - Verified `dune runtest -j1`, `ninja -j1 test` (26/26), `ninja -j1 asan_test` (16/16), `stdlib_compat.py` (75/75 modules, 68/77 upstream tests), `stdlib_regressions.py` (15/15 including `marshal_hardening`), and `sh tests/run_bootstrap_stubs_tests.sh` (native + ASan). See [stdlib-compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-20 (antigravity/1): Slice 6c — Migrate Array / Floatarray / Bytes / String bulk ops to pure OCaml and lower unaligned bytes access & bswap to QBE (`stdlib/camlinternalBulkOps.ml`, `lib/{anf.mli,anf.ml,arc_pass.ml,codegen_ctx.ml,codegen_expr.ml,ccalls.ml,driver.ml}`, `runtime/{arc.h,arc.c}`, `tools/stdlib_compat.py`, `tools/bootstrap.py`, `build.ninja`):
  - Deleted 513 C LOC (`9,201 -> 8,688` total runtime LOC): removed `caml_blit_{bytes,string}`, `caml_fill_bytes`, all 14 `caml_{string,bytes}_{equal,notequal,compare,lessthan,lessequal,greaterthan,greaterequal}` wrappers, `caml_string_hash`, `caml_bswap16`, `caml_{int32,int64,nativeint}_bswap`, `caml_bytes_{get,set}{16,32,64}_{unsafe,safe}`, `caml_array_{create_float,sub,append,concat,blit,fill}`, and `caml_floatarray_{create,make,sub,append,concat,blit,fill}`.
  - Lowered `%caml_{string,bytes}_{get,set}{16,32,64}` and `Pbswap16`/`Pbbswap` directly in ANF/QBE (`BytesGetN`/`BytesSetN`/`Bswap16`/`BswapBint` with `compile_bytes_slice_bounds_guarded`), mapped `Translprim`-emitted `caml_{string,bytes}_*` compares to structural `caml_*` in `Anf`, and implemented all bulk ops in `--nopervasives` `stdlib/camlinternalBulkOps.ml` + `tools/stdlib_compat.py`.
  - Added TDD fixture `tests/stdlib/bulk_ops/` (verified against stock `ocamlc`).
  - Verified `dune runtest -j1`, `ninja -j1 test` (26/26), `ninja -j1 asan_test` (16/16), `stdlib_compat.py` (74/74 modules, 68/77 upstream tests), and `stdlib_regressions.py` (14/14 including `bulk_ops`). See [stdlib-compatibility](/concepts/stdlib-compatibility.md) and [compiler-pipeline](/concepts/compiler-pipeline.md).

- 2026-11-20 (antigravity/1): Slice 6b — Implement integer formatting and parsing in pure OCaml and delete C `caml_*format` / `caml_*_of_string` (`stdlib/camlinternalIntFmt.ml`, `stdlib/{stdlib,stdlib__int32,stdlib__int64,stdlib__nativeint,stdlib__printf}.ml`, `lib/driver.ml`, `lib/ccalls.ml`, `runtime/{arc.h,arc.c,builtins.c}`, `tools/stdlib_compat.py`, `tools/bootstrap.py`, `build.ninja`):
  - Replaced `caml_format_int`, `caml_int32_format`, `caml_int64_format`, `caml_nativeint_format`, `caml_int_of_string`, `caml_int32_of_string`, `caml_int64_of_string`, and `caml_nativeint_of_string` (-241 C LOC, `9,442 -> 9,201` total runtime LOC) with `--nopervasives` `stdlib/camlinternalIntFmt.ml` compiled directly after `CamlinternalFormatBasics` and declarative rewrites in `tools/stdlib_compat.py` (`73/73` modules).
  - Added TDD fixture `tests/stdlib/int_fmt/` (verified against stock `ocamlc`).
  - Verified `dune runtest -j1`, `ninja -j1 test` (26/26), `ninja -j1 asan_stdlib_runtime`, `stdlib_compat.py` (73/73 modules, 68/77 upstream tests), and `stdlib_regressions.py` (13/13 including `int_fmt`). See [stdlib-compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-19 (antigravity/1): Slice 6a — Implement Digest (MD5 + BLAKE2b) in pure OCaml and delete C digest implementation (`stdlib/overlay/digest.ml`, `runtime/arc.c`, `runtime/builtins.c`, `runtime/arc.h`, `lib/ccalls.ml`):
  - Replaced `caml_md5_{string,bytes,chan}`, `caml_blake2_{create,update,final,string,bytes}`, and `ARC_CUSTOM_BLAKE2` (-391 C LOC across `runtime/*.c`/`arc.h`) with a pure OCaml `stdlib/overlay/digest.ml` implementing RFC 1321 MD5 (unboxed 63-bit masked arithmetic) and RFC 7693 BLAKE2b (`BLAKE128`, `BLAKE256`, `BLAKE512`) over `In_channel.input` / `Bytes`.
  - Added TDD fixture `tests/stdlib/digest/` (checked against stock `ocamlc`).
  - Verified `dune runtest -j1`, `ninja -j1 test` (26/26), `ninja -j1 asan_stdlib_runtime`, `stdlib_regressions.py` (12/12 including `digest`), and `stdlib_compat.py` (72/72 modules, 68/77 upstream tests including `lib-digest/digests.ml`, `lib-digest/md5.ml`, `lib-random/rand.ml`). See [stdlib-compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-19 (antigravity/1): Achieve bit-for-bit Stage 2 == Stage 3 self-hosting fixed point and wire Ninja targets (`build.ninja`, `tools/bootstrap.py`):
  - Added `bootstrap_fetch`, `bootstrap_stage1`, and `bootstrap` phony targets to `build.ninja`.
  - Updated `tools/bootstrap.py` to build Stage 1 -> Stage 2 -> Stage 3 using a stage-invariant `build/bootstrap/stdlib_src` directory (so `assert` `__FILE__` strings match across stages; Stage 0 `ocamlopt` evaluates `Translprim.make_params` cons cells right-to-left while self-hosted `ocamlcc` Stage 1 & Stage 2 evaluate left-to-right), verify all 386 `.ssa` and `.s` files between Stage 2 and Stage 3 (`386 checked, 0 differences`), and run the full Stage 2 validation suite (`hello`, `fib`, `closures`, `exn`, `mod_main`, `fiber_test`, `fiber_io`, `primitives_test`, `bindgen` + ASan `closures`/`exn`). See [self-hosting](/concepts/self-hosting.md).

- 2026-11-19 (antigravity/1): Extend mutual tail-call SCC `@dispatch` trampolines to non-pure `let rec` closure groups (`lib/codegen_analysis.ml`, `lib/codegen_expr.ml`, `lib/codegen_fn.ml`, `test/mutrec_closure_tail_test.ml`, `examples/closures.ml`):
  - Previously only pure `let rec` definitions received `@dispatch` trampolines; non-pure mutual `let rec` closures (including `ocamllex`-generated DFAs in `Lexer` scanning multi-ten-KB table literals in `lexer.ml` and `parser.ml`) pushed native C stack frames per state transition and overflowed macOS's 8 MB stack.
  - Added optional `~arities` saturated-call matching to `Codegen_analysis.tail_callees`, factored `compile_group` into shared `compile_scc_group ~export ~with_closure` (threading `%phi_clos` and unpacking member `env` at each entry), added `emit_group_wrapper` so individual closures remain indirect-callable via `ocamlcc_apply_n`, and unified `compile_app` direct/tail-call emission for pure and closure SCCs.
  - TDD-verified in `test/mutrec_closure_tail_test.ml`, `dune runtest -j1`, `ninja -j1 test` (with `examples/closures.ml` bumped to 300,000 mutual closure steps), and `ninja -j1 asan_closures`. See [compiler-pipeline](/concepts/compiler-pipeline.md).

- 2026-11-19 (antigravity/1): Track `env.in_tail` in `Arc_pass` so non-tail join branches never elide `CheckExn` (`lib/arc_pass.ml`, `test/arc_checkexn_join_test.ml`):
  - `is_pure_tail` previously checked only `body = Halt (Var v)` and `env.try_depth = 0`, which also matched calls at the end of a `LetJoin` rhs / `If` branch / loop body whose `Halt` flows into a join phi instead of returning from the function. When `Typecore.type_expect` raised inside such an `if` branch, execution continued into the join block with dummy result `1` and crashed.
  - Added `in_tail : bool` to `Arc_pass.state` (`false` in `LetJoin` rhs, `TryWith` body, and `While`/`For` loops) and gated `is_pure_tail` on `env.in_tail`.
  - TDD-verified in `test/arc_checkexn_join_test.ml` and `dune runtest -j1`. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (antigravity/1): Accept negative prefixed literals (`-0x...`, `-0o...`, `-0b...`, `-0u...`) in `ocamlcc_c_int_of_string` (`runtime/builtins.c`, `tests/stdlib_runtime.c`):
  - `Misc.Int_literal_converter.int` converts positive hex/oct/bin literals such as `"0x30"` by calling `int_of_string "-0x30"`, which `ocamlcc_c_int_of_string` rejected because it tested signed `v < 0` instead of checking magnitude `<= INT64_MAX`.
  - Replaced the check with magnitude bounds checking (`mag = is_neg ? 0ULL - (uint64_t)v : (uint64_t)v; mag <= (uint64_t)INT64_MAX`) plus 63-bit sign extension.
  - TDD-verified in `tests/stdlib_runtime.c` (`test_int_of_string_literals`), `ninja -j1 test` (26/26), and `ninja -j1 asan_stdlib_runtime`. See [stdlib-compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-19 (antigravity/1): Stage 1 self-hosted compiler builds and passes smoke suite (`tools/fetch-ocaml-compiler-libs.py`, `tools/bootstrap.py`):
  - Extended `tools/fetch-ocaml-compiler-libs.py` (`MANIFEST.json`) to emit topologically sorted `mli_order` (108 `.mli` interfaces, covering 4 `.mli`-only units via `.depend`) and rewrite internal `MenhirLib` references in `parser.{ml,mli}` to `CamlinternalMenhirLib` (matching the 104-module `compiler-libs.common` closure).
  - Added `tools/bootstrap.py` orchestrating `fetch`, `stage1`, `stage2`, `verify` (bit-for-bit `.ssa`/`.s` diff), and `all`: compiles `stdlib_compat` (72 modules), `compiler-libs.common` (108 `.mli` + 104 `.ml`), `bootstrap/unix/`, and `ocamlcc` (16 modules), linked with `libocamlrt.a` + `bootstrap/stubs/compiler_stubs.c` + `-lzstd`.
  - Stage 1 (`build/bootstrap/stage1/ocamlcc`, 19.4 MiB) builds cleanly and passes all 3 Stage 1 smoke checks (`hello.ml`, multi-module `Driver.build` on `examples/mod_lib.{mli,ml}` + `examples/mod_main.ml`, and reading host zstd-compressed `stdlib.cmi`). See [self-hosting](/concepts/self-hosting.md).

- 2026-11-19 (antigravity/1): Drop zero-occurrence `Alias` / `StrictOpt` bindings before ANF lowering (`lib/anf.ml`, `test/anf_unused_alias_test.ml`):
  - OCaml's pattern matcher shares catch arms across constructors of different payload sizes (exposed by `Typedtree.shallow_iter_pattern_desc` combining 5-field `Tpat_alias` with 1-field `Tpat_lazy` / `Tpat_value` / `Tpat_exception`), emitting `Llet (Alias, _, w, Pfield i param, body)` for unused wildcards and relying on dead `Alias` bindings not being evaluated out of bounds.
  - Added `drop_unused_alias_lets` in `lib/anf.ml` before `conv_tail`, pruning 0-occurrence `Alias` / `StrictOpt` bindings (including transitive chains) while keeping `Strict` bindings intact.
  - TDD-verified in `test/anf_unused_alias_test.ml`, `dune runtest -j1`, and `ninja -j1 test` (26/26). See [compiler-pipeline](/concepts/compiler-pipeline.md).

- 2026-11-19 (antigravity/1): Fix compressed Marshal (`0x8495a6bd`) shared-reference indexing (`runtime/marshal.inc`, `tests/stdlib_runtime.c`):
  - OCaml 5.5's compressed Marshal format (`extern.c`/`intern.c` #4056) encodes `CODE_SHARED*` as 0-based absolute object IDs (`r->objects[n]`) rather than uncompressed backward distances (`r->objects[r->count - n]`).
  - Updated `m_write_value`/`m_encode` (emitting absolute IDs whenever `Compression` is active with a registered codec, without falling back to `0x8495a6be` mid-encode) and `MReader`/`m_decode` (decoding `r->objects[n]` when `r->compressed` is set).
  - TDD-verified in `tests/stdlib_runtime.c` (compressed shared-DAG + self-cycle wire fixtures), `ninja -j1 test_stdlib_runtime`, and `ninja -j1 asan_stdlib_runtime`. See [stdlib-compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-19 (antigravity/1): Split wide QBE `phi` nodes into fan-in trees in `Codegen_ctx.finish_blocks` (`lib/codegen_ctx.ml`):
  - QBE's parser caps `phi` incoming edges at `NPred = 63` (`vendor/qbe/parse.c`), which wide OCaml switches in `compiler-libs` (`Warnings`, `Printlambda`, `Compenv`) exceed.
  - Added `split_wide_phis` in `Codegen_ctx.finish_blocks` (chunk size 50): any block with a `Phi` having > 50 incoming edges is recursively split into trampoline `@phisplit.*` blocks with predecessor `Jmp`/`Br` edges rewritten, keeping vendored QBE unmodified and imposing zero overhead on normal blocks.
  - TDD-verified in `test/phi_split_test.ml` (90-arm match compiles with max phi fan-in ≤ 50 and passes `vendor/qbe/qbe`); `dune runtest -j1` passes. See [compiler-pipeline](/concepts/compiler-pipeline.md).

- 2026-11-19 (antigravity/1): Add `caml_{string,bytes}_{less,greater}{than,equal}` primitives (`runtime/arc.h`, `runtime/arc.c`, `lib/ccalls.ml`):
  - OCaml's typechecker specializes relational comparisons on `string`/`bytes` (hit by `Diffing_with_keys`, `Cmi_format`, `Typecore` in `compiler-libs.common`) to these 8 primitives.
  - Added 1-line wrappers over `bytes_compare_raw` in `runtime/arc.c` and registered all 8 in `lib/ccalls.ml` (all `argc=2, raises=false, yields=false, returns_imm=true`).
  - TDD-verified in `test/ccalls_test.ml` and `tests/stdlib_runtime.c` (`test_string_bytes_rel_compare`, including embedded NUL bytes); `dune runtest -j1`, `test_stdlib_runtime`, and `asan_stdlib_runtime` pass. See [stdlib-compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-19 (antigravity/1): Add on-demand SHA-256-pinned OCaml 5.5.0 `compiler-libs.common` fetcher (`tools/fetch-ocaml-compiler-libs.py`, `tests/test_fetch_compiler_libs.py`):
  - Fetches or reuses from local opam/build cache `ocaml-5.5.0.tar.gz`, verifies its pinned SHA-256 (`c018052c...`), and extracts only the 104-module transitive closure + 4 `.mli`-only interfaces (`annot`, `outcometree`, `parsetree`, `value_rec_types`) into `build/bootstrap/src/compiler-libs/` (with pre-generated Menhir `parser.{ml,mli}` / `camlinternalMenhirLib.{ml,mli}`, `ocamllex`-generated `lexer.ml`, and boot-configured `config.ml`).
  - TDD-verified via `python3 -m unittest tests/test_fetch_compiler_libs.py` (rejects corrupt SHA-256 fail-closed; extracts and validates all 104 `.ml`/`.mli` + 4 `.mli`-only files and `MANIFEST.json`). See [self-hosting](/concepts/self-hosting.md).

- 2026-11-19 (antigravity/1): Add compiler-only bootstrap stubs and minimal `Unix` shim (`bootstrap/stubs/compiler_stubs.c`, `bootstrap/unix/unix.{mli,ml}`, `bootstrap/unix/unix_stubs.c`):
  - `compiler_stubs.c` implements `caml_zstd_initialize` (registering `ZSTD_decompress`/`ZSTD_compress` via `ocamlcc_marshal_register_codec`), `caml_sys_get_stdlib_dirs`, `caml_sys_time_include_children`, and `caml_terminfo_rows`, linked only into the self-hosted compiler binary so `libocamlrt.a` remains zstd-free.
  - `bootstrap/unix/` provides the exact 11-function POSIX `Unix` surface used by `lib/driver.ml`, leaving `lib/driver.ml` and host Dune builds unchanged.
  - TDD-verified under both native and ASan+UBSan (`sh tests/run_bootstrap_stubs_tests.sh`), including decoding a real host OCaml 5.5 zstd-compressed `stdlib.cmi` with zero leaks. See [self-hosting](/concepts/self-hosting.md).

- 2026-11-19 (antigravity/1): Add `-open <Mod>` frontend/CLI support, compiler-libs `Ccalls` ABI entries, and inter-unit `Gc.full_major ()` in `driver.ml` (`lib/frontend.ml*`, `lib/pipeline.ml*`, `bin/main.ml`, `lib/ccalls.ml`, `lib/driver.ml`):
  - Thread `~open_modules` through `Frontend` (`Clflags.open_modules := List.rev open_modules`, saved/restored in `with_flags`), `Pipeline`, and `bin/main.ml` (`-open` / `--open`).
  - Register the four `compiler-libs.common` primitives (`caml_sys_get_stdlib_dirs`, `caml_sys_time_include_children`, `caml_terminfo_rows`, `caml_zstd_initialize`) in `lib/ccalls.ml` (with `returns_imm` for `caml_terminfo_rows` and `caml_zstd_initialize`).
  - Call `Gc.full_major ()` between compilation units in `Driver.build` to collect cyclic typechecker graphs across large multi-module builds.
  - TDD-verified in `test/open_modules_test.ml` (missing `-open` fails, `-open` succeeds on `.mli`/`.ml`, precedence matches `ocamlc`, `Clflags.open_modules` restored) and `test/ccalls_test.ml`. `dune runtest -j1` and `ninja -j1 test` (26/26) pass. See [compiler-pipeline](/concepts/compiler-pipeline.md).

- 2026-11-19 (antigravity/1): Add generic compressed Marshal (`0x8495a6bd`) codec hooks and raise `MAX_CLOSURE_ARITY` to 32 (`runtime/arc.h`, `runtime/marshal.inc`, `runtime/closure.c`):
  - Add `ocamlcc_marshal_register_codec(decompress_fn, compress_fn)` (default `NULL`, zero `libzstd` dependency in `libocamlrt.a`) and full OCaml 5.5 `0x8495a6bd` 10–63 byte VLQ header framing across `m_read_header`, `m_from_block`, `caml_input_value`, `caml_marshal_data_size`, and flag-3 `Compression` encoding in `m_encode`.
  - Raise `MAX_CLOSURE_ARITY` in `runtime/closure.c` from 16 to 32 (`fn17_t`..`fn32_t`) to cover high-arity `compiler-libs` closures.
  - Regression-tested in `tests/stdlib_runtime.c` (`test_compressed_marshal_hooks` with a self-contained RLE codec covering round-trip bytes/channel, `data_size`, truncations, corrupt headers, and null-codec rejection; `test_high_arity_closure` for arity-20 direct and PAP dispatch; overflow guard updated to arity 33).
  - `ninja -j1 test` (26/26), `ninja -j1 asan_test` (16/16), and `ninja -j1 tsan_test` (2/2) pass. See [stdlib-compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-19 (autoagent/1): Shadow over-application tail args across the first call (`lib/codegen_expr.ml`):
  - The over-apply split (exact-arity first call + `apply_closure` over the tail) shadowed `clos_res` around the second call (d34f6a1) and `closure.c` shadows its own tail args internally — but `rest_vals` were compiled *after* the first (possibly suspending) call and never registered on the fiber shadow stack, so an over-applied call whose first call suspends leaked the tail arguments when the fiber was abandoned (no scope-exit release ever runs).
  - Fix: compile `rest_vals` before the first call (ANF atoms are pure temp reads/constants, so hoisting is side-effect-free), push them onto the fiber shadow stack across it, and pop once it returns — on both the error path (which then releases them) and the ok path (which transfers them to `apply_closure`, where `closure.c` takes over the shadowing). Push/pop/release stay balanced on every path.
  - End-to-end regression in `examples/fiber_test.ml` (`oapp=` probe): a coroutine abandoned inside the first (suspending) call of `mk 1 2 keep` must release the tail argument — pre-fix `after=1` and `delta=2`; post-fix `after=0`, `delta=0` (the probe drains pending finalizer dispatch before measuring, since the preceding cross-call probe defers a release).
  `ninja test` (100/100), `ninja asan_test` (31/31), `ninja tsan_test` (race-free), and `dune runtest` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (autoagent/1): Fix dangling TLS pointers and queued-fiber leaks in `fiber_tls_cleanup` (`runtime/fiber.c`):
  - The `pthread_key` destructor freed the `FiberThreadState` without clearing `tls_state`/`tls_current_fiber` — if `fiber_free_buffers`' released values ran a custom finalizer, or another `pthread_key` destructor touched fiber state afterwards, it dereferenced freed TLS.
  - Spawned fibers still queued on `sched.ready_head` / `timer_head` / `io_head` at thread exit were leaked (the scheduler's spawn pins were never released).
  - Fix: drain all three scheduler lists and `arc_release` each queued fiber (looping until stable, since wakes during release re-push to the ready queue), then free the main fiber's buffers, then detach `tls_state`/`tls_current_fiber` before `free(s)` so re-entrant fiber/runtime access allocates fresh state instead of touching freed TLS.
  - Also added `-pthread` to the `cc_link` / `cc_link_asan` rules (`tests/stdlib_runtime.c` now uses pthreads; needed on Linux).
  - Regression-tested in `tests/stdlib_runtime.c` (`test_tls_cleanup_queued_fibers`: worker exits with three queued fibers and a probe `pthread_key` destructor touching fiber state — no leak past `pthread_join`, no dangling-TLS deref). `ninja test` (51/51), `ninja asan_test` (34/34), `ninja tsan_test` (race-free), and `dune runtest` pass. See [wren-fibers](/concepts/wren-fibers.md).

- 2026-11-19 (autoagent/1): Fix dead-code poller unwatch and waiter UAF in `fiber_destroy` (`runtime/fiber.c`, `runtime/pal.c`, `runtime/pal.h`):
  - `fiber_destroy` called `sched_remove_io(f)` (which zeroes `wait_fd`/`wait_events`) *before* the `pal_poller_unwatch` guard on those fields — dead code, so a destroyed fiber's waiter entry stayed in the live poller queue as a freed-fiber udata.
  - The coarse `pal_poller_unwatch` was also the wrong tool: it clears *every* waiter on the (fd, direction) queue, breaking other fibers awaiting the same fd, and operates on the calling thread's poller.
  - An awaiting fiber destroyed while queued on `target->waiter_head` was never unlinked, leaving a dangling entry that the target's completion wake would dereference.
  - Fix: new `pal_poller_unwatch_waiter(pfd, fd, events, udata)` removes a single waiter entry (kernel registration and watch dropped only when the last waiter goes); `sched_remove_io` reports whether the fiber was parked on the destroying thread's io list, and `fiber_destroy` captures the watch key before unlinking, unwaits just that fiber, and unlinks itself from `f->awaiting->waiter_head` before anything can wake or free the target.
  - Regression-tested in `tests/stdlib_runtime.c` (`test_destroy_waiter_cleanup`: an awaiter torn down collector-style must vanish from `target->waiter_head` and the target must still wake cleanly; `test_poller_unwatch_waiter`: targeted removal preserves peers and a last-waiter removal unregisters the fd). `ninja test` (51/51), `ninja asan_test` (37/37), `ninja tsan_test` (race-free), and `dune runtest` pass. See [wren-fibers](/concepts/wren-fibers.md).

- 2026-11-19 (autoagent/1): Fix unsound suspension window from finalizer dispatch (`runtime/fiber.c`):
  - `ocamlcc_poll_finalizers` is marked `yields = false` (the fast non-yielding codegen), but nothing prevented a finalizer callback from suspending the dispatching fiber via `Fiber.yield`, `suspend`, `sleep_ms`, `fd_wait_*`, or `await` — if the fiber was later abandoned, every live local in unshadowed caller frames leaked (no `ShadowPush`/`ShadowPop` window exists around the non-yielding call).
  - Every suspension entry point in `runtime/fiber.c` now checks `owns_finalizer_dispatch` (set by `run_finalizers` around callback dispatch) and raises `Invalid_argument` instead of yielding.
  - Regression-tested in `tests/stdlib_runtime.c` (`test_finalizer_no_suspend`: a finalizer dispatched inside a spawned fiber probes all five entry points, each must raise, and the fiber must complete normally). `ninja test` (51/51), `ninja asan_test` (34/34), `ninja tsan_test` (race-free), and `dune runtest` pass. See [wren-fibers](/concepts/wren-fibers.md).

- 2026-11-19 (autoagent/1): Fix `caml_floatarray_blit` / `caml_floatarray_fill` ABI flags (`lib/ccalls.ml`):
  - Both delegate to `caml_array_blit` / `caml_array_fill` (which raise `Invalid_argument` on out-of-bounds slices since 86f028f), but the C-call ABI registry still marked them `raises = false`, so codegen skipped `CheckExn` after calls — leaking live values on OOB and leaving `ocamlcc_exn_slot` poisoned for the next checked call.
  - Mark both `raises = true` and add them to `returns_imm` (both return unit, like their `caml_array_*` counterparts).
  - Regression-pinned in `test/ccalls_test.ml` (registry entries + a `returns_imm` check) and end-to-end in `examples/stdlib_test.ml` (`invarg=` probes `i_fa_oob=-19`: OOB fill caught by try/with, and `i_fa_ok=1`: a following in-bounds fill succeeds, proving no stale exception slot); `ninja test` (100/100), `ninja asan_test` (31/31), and `dune runtest` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (autoagent/1): Fix C11 data race on `ArcHeader.reserved` (`runtime/arc.h`, `runtime/arc.c`):
  - `release_subtree` reads `(cur->reserved & CC_BUFFERED)` without `g_cc_lock` (the 4a6cba2 contention fix) while another thread's `cc_roots_remove_locked(other)` can swap-move `cur` from the tail of `g_cc_roots` into `other`'s slot and rewrite `cur->reserved` with a non-atomic store — a C11 data race (UB) even though `CC_BUFFERED` itself stays set.
  - `ArcHeader.reserved` is now `_Atomic uint32_t` (same 16-byte header layout, `_Static_assert` still holds); `cc_roots_add`, `cc_roots_remove_locked` (including the swap-move rewrite of `moved->reserved`), the root-reset loop in `ocamlcc_arc_collect`, and the lock-free read in `release_subtree` use explicit relaxed atomics.
  - Added a ThreadSanitizer suite to `build.ninja` (`ninja tsan_test`): builds the runtime with `-fsanitize=thread` and runs the new `tests/cc_reserved_race.c` stress (4 workers buffering/dropping cycle candidates against a collector thread — TSan reported the `reserved` data race before the fix) plus the `mt_ffi` concurrency stress under TSan.
  `ninja tsan_test` is race-free, `ninja test` (56/56), `ninja asan_test` (36/36), and `dune runtest` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (autoagent/1): Fix 32-byte struct overflow on RISC-V 64 and broken Win64 context switch (`runtime/pal.h`, `runtime/pal_ctx.S`, `runtime/pal.c`):
  - `PalContext` was a fixed `uint64_t regs[22]` (176 B) while the RISC-V 64 `pal_ctx_swap` saves/loads 26 registers up to `200(a0)` (208 B) — 32 bytes past `Fiber.ctx` into `c_stack`, `c_stack_bytes`, `shadow_base`, and `shadow_sp`.
  - `pal_ctx_make` was never updated for the new ABIs: RISC-V 64 still hit `pal_abort()`, and Win64 wrote SysV slot offsets `regs[6]`/`regs[7]` (48/56) while Win64 `pal_ctx_swap` loads `rsp`/`rip` from offsets 64/72 — resuming jumped to `0x0`.
  - Win64 `pal_ctx_swap` did not save/restore callee-saved `xmm6`-`xmm15`, violating the Windows x64 ABI and corrupting FP state across fiber switches.
  - Fix: `PalContext` is now sized per ABI via a `PAL_CTX_REGS`/`PAL_CTX_SP`/`PAL_CTX_PC` ladder in `pal.h` with `_Static_assert`s pinning the byte sizes (aarch64 21 regs/168 B, x86-64 SysV 8/64 B, Win64 30/240 B incl. `xmm6`-`xmm15` via `movdqu`, RISC-V 64 26/208 B); Win64 `pal_ctx_swap` now saves/restores `xmm6`-`xmm15`; `pal_ctx_make` covers all four ABIs using the shared slot macros.
  - New `test/pal_ctx_abi_test.ml` pins the contract from both sides: parses each `pal_ctx_swap` section (store extent, sp/pc slots, callee-saved FP registers) against the `pal.h` ladder and `pal_ctx_make`, and compiles forced-branch probes of all four ABIs on any host.
  `dune runtest` (incl. the new test), `ninja test` (58/58), and `ninja asan_test` (38/38) pass. See [platform-abstraction-layer](/concepts/platform-abstraction-layer.md) and [wren-fibers](/concepts/wren-fibers.md).

- 2026-11-19 (autoagent/1): Fix deterministic segfault / OOB read in `In_channel.input_bigarray` / `Out_channel.output_bigarray` (`runtime/arc.c`):
  - `caml_ml_input_bigarray` / `caml_ml_output_bigarray` passed raw `ArcBigarray.data` (a PAL mmap page or foreign C pointer with no `ArcHeader`) as a `Bytes`-shaped `buf_val` into `caml_ml_input` / `caml_ml_output_bytes`, whose 86f028f bounds hardening reads `((ArcHeader *)buf_val - 1)->reserved` — 16 bytes before the data: an immediate fault on page-aligned Bigarray buffers and an OOB read on foreign buffers.
  - Split the byte movement out of the header-checked entry points: `caml_ml_input` now delegates to a raw `chan_read_raw` helper (alongside the existing raw `chan_write_bytes`), keeps the `ArcHeader.reserved` slice check for `Bytes` buffers, and `caml_ml_input_bigarray` / `caml_ml_output_bigarray` validate the slice with `ba_channel_range` and call the raw helpers directly.
  - Regression-tested in `tests/stdlib_runtime.c` (`test_bigarray_channel_io`: round-trip, sub-range writes, out-of-range `Invalid_argument`); `ninja test` (51/51), `ninja asan_test` (34/34), and `dune runtest` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (autoagent/1): Fix self-deadlock on mutual module initialization (`runtime/arc.c`):
  - `ocamlcc_init_try_enter` spun forever when a same-thread re-entrant init call hit its own `-2` claim — `.mli`-mediated mutually dependent units (`mut_app` in `test/driver_test.ml`) recurse `ocamlcc_init_A → ocamlcc_init_B → ocamlcc_init_A` while the outer initializer is in flight. It now tracks active init slots in a `_Thread_local` stack (`tls_init_slots`, depth ≤ 64), returns `0` for re-entrant same-thread calls, keeps the spin only for slots claimed by *other* threads, and `ocamlcc_init_finish` pops the claim after publishing the value.
  - `run_capture` in `test/driver_test.ml` enforces a 60 s timeout and SIGKILLs hung children, so a startup deadlock fails the suite (`mli-mediated mutual deps: FAIL`) instead of hanging `dune runtest` forever.
  `dune runtest` and `ninja test` (52/52, incl. `test_mutual`) pass. See [perceus-arc](/concepts/perceus-arc.md) and [build-pipeline](/concepts/build-pipeline.md).

- 2026-11-19 (antigravity/1): Implement full graph traversal in `caml_obj_reachable_words` (`runtime/arc.c`) and align `docs/design.md` / `README.md` with the actual runtime architecture and unsupported OCaml feature list (`Lsend`, ephemerons, backtraces, signal handlers, `Marshal.Closures`). Regression-tested in `tests/stdlib_runtime.c` (`test_reachable_words`); `ninja test` and `ninja asan_test` pass.

- 2026-11-19 (antigravity/1): Fix driver, cross-compilation, bindgen shim, and CLI issues (§4):
  - Fix inverted `--nostdlib` condition (`if cfg.nostdlib then Ok []`) in `lib/driver.ml`; replace predictable `/tmp/ocamlcc_build_<pid>` with `Filename.temp_dir` and make `rm_rf` unlink symlinks without following them (`Unix.lstat`).
  - Derive `<prefix>-ar` for cross-compilers, pass `-pthread` on Linux and omit `-lm` on Windows, isolate `-headers` for `ios-xcframework` to a dedicated directory containing only the emitted header, add `Win64` and `rv64` context-switch support in `runtime/pal_ctx.S`, and guard `_WIN32` in `caml_sys_os_type`.
  - Guard uninitialized `ocamlcc_global_<Mod>` and 63-bit `CT_int` range (`ocamlcc_shim_int_fits`) in `lib/c_bindgen.ml`, and reject colliding sanitized C identifiers.
  - Catch `Sys_error` in `dump_lambda` (`bin/main.ml`).
  `ninja test` and `ninja asan_test` pass. See [build-pipeline](/concepts/build-pipeline.md).

- 2026-11-19 (antigravity/1): Fix finalizer dispatch stranding, spinlock contention, and runtime edge cases (`runtime/arc.c`, `runtime/builtins.c`, `runtime/bigarray.inc`):
  - Preserve `DISPATCH_READY` in `run_finalizers` when an exception breaks the loop with `pending_finalizers != NULL`.
  - Skip `g_cc_lock` in `release_subtree` when `g_cc_active == 0` and `CC_BUFFERED` is clear; snapshot/retain live channels under `g_chan_lock` in `chan_flush_all_out` and flush outside the lock.
  - Stream `caml_md5_chan` in 4 KB chunks (`ocamlcc_c_md5_init`/`update`/`final`); seed `caml_sys_random_seed` via `ocamlcc_c_random_bytes` (`arc4random_buf`/`getrandom`); follow `ARC_TAG_FORWARD` and reject non-numeric/non-Bigarray custom blocks in `val_compare_raw`; guard `malloc` failure in `ocamlcc_c_readdir_alloc`; add `NULL` check in `ocamlcc_bigarray_view_info` and portable IEEE-754 binary16 helpers when `__FLT16_MANT_DIG__` is absent.
  Regression-tested in `tests/stdlib_runtime.c` (`test_runtime_3_3`); `ninja test` and `ninja asan_test` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (antigravity/1): Harden fiber robustness and closure arity handling (`runtime/pal.h`, `runtime/pal.c`, `runtime/fiber.h`, `runtime/fiber.c`, `runtime/closure.c`):
  - Add a 16 KB `PROT_NONE` guard page (`pal_page_protect_none`) at the bottom of each fiber C stack.
  - Unlink `FIBER_WAITING_IO` / `FIBER_WAITING_TIMER` watches and wake `waiter_head` in `fiber_destroy`; detect cyclic `Fiber.await` via `Fiber.awaiting`.
  - Replace hard `pal_abort()` calls in `ocamlcc_fiber_resume`, `fiber_fd_wait`, `ocamlcc_fiber_await`, and `closure.c` (`> MAX_CLOSURE_ARITY = 16`, releasing consumed args) with `Invalid_argument` exceptions (`ocamlcc_fiber_raise_invalid`).
  Regression-tested in `tests/stdlib_runtime.c` (`test_fiber_robustness`); `ninja test` and `ninja asan_test` pass. See [wren-fibers](/concepts/wren-fibers.md).

- 2026-11-19 (antigravity/1): Fix per-thread `mmap` and poller fd leaks on OS thread exit (`runtime/fiber.c`): move `tls_main_fiber` and `tls_sched` into a `FiberThreadState` registered with a `pthread_key_create` destructor (`fiber_tls_cleanup`) so exiting worker threads free `shadow_base`/`reuse_base` and close `poller_fd` without touching `_Thread_local` after TLS teardown. Regression-tested in `tests/mt_ffi_host.c` (`test_thread_exit_tls_cleanup`); `ninja test` and `ninja asan_test` pass. See [wren-fibers](/concepts/wren-fibers.md).

- 2026-11-19 (antigravity/1): Fix ARC ownership leaks in `arc_pass.ml`, over-application, and module init:
  (1) release `env.muts - env.no_release_muts` on tail-position `While`/`For` exits;
  (2) track `target_live` in `StaticCatch` and drop dead `frame_borrowed` variables at `StaticRaise`;
  (3) recurse into `While`/`For` in `has_static_raise`;
  (4) push intermediate `clos_res`/`res` and remaining `argv` onto the fiber shadow stack during over-application (`lib/codegen_expr.ml`, `runtime/closure.c`);
  (5) add atomic `ocamlcc_init_try_enter`/`ocamlcc_init_finish` and check `ocamlcc_get_exn()` after dependency init in `lib/codegen.ml`.
  Regression-tested in `test/arc_loop_static_test.ml`; `dune test`, `ninja test`, and `ninja asan_test` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (antigravity/1): Hoist fixed-size `Alloc8` instructions (`MutLet`, `MakeArray Pgenarray`, and `>4`-argument closure calls) to `@start` via `fn_state.start_allocs` and `finish_blocks` (`lib/codegen_ctx.ml`, `lib/codegen_expr.ml`, `lib/codegen_fn.ml`, `lib/codegen.ml`), preventing dynamic `alloca` stack growth inside loops and tail-recursive functions. Regression-tested in `test/alloc8_hoist_test.ml`; `dune test`, `ninja test`, and `ninja asan_test` pass. See [compiler-pipeline](/concepts/compiler-pipeline.md).

- 2026-11-19 (antigravity/1): Restore yield-effect inference and immediate tracking (`lib/ccalls.ml`, `lib/arc_pass.ml`): mark `ocamlcc_poll_finalizers` as non-yielding (`yields = false`), add `Ccalls.returns_imm`, track `Lambda.Pintval` parameters, immediate-returning `LetJoin`s, and `imm_funs` in `Arc_pass`, eliminating `arc_fiber_push`/`arc_fiber_pop` and `arc_retain_val`/`arc_release_val` on tagged immediates in pure integer functions like `fib`. Regression-tested in `test/yield_imm_test.ml`; `dune test`, `ninja test`, and `ninja asan_test` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (antigravity/1): Fix mutator-gate handshake in `caml_ml_mutex_lock` and `caml_ml_condition_wait` (`runtime/arc.c`): replace the manual `g_active_mutators` increment (which omitted the `g_cc_waiting` Dekker re-check) with `arc_mutator_leave(1)` / `arc_mutator_enter()`, preventing blocked threads from waking into an active `collect_cycles()` trial. Stress-tested in `tests/mt_ffi_host.c` (`test_mutex_cond_collect_race`); `ninja test` and `ninja asan_test` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (antigravity/1): Harden C primitive bounds checking and Marshal input allocation: add `slice_in_bounds` checks in `caml_output_value_to_buffer`, `caml_ml_output_bytes`, `caml_ml_input`, `caml_array_blit`, and `caml_array_fill` (and mark `caml_array_blit`/`caml_array_fill` as `raises = true` in `lib/ccalls.ml`); read `caml_input_value` payloads incrementally in 64 KB chunks instead of eagerly `pal_page_alloc`ing up to 4 GB from an untrusted wire header; and clear/release `ocamlcc_get_exn()` in `m_read_bigarray` when `caml_ba_create` fails. Regression-tested in `tests/stdlib_runtime.c` (`test_bounds_and_marshal_dos`); `ninja test` and `ninja asan_test` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (antigravity/1): Fix `runtime/pal.c` poller pointer invalidation, buffer overflow, and waiter overwriting across `epoll` and `kqueue`: use fixed-slot `PalWatch` entries with generation-checked `(gen << 32) | idx` tokens (eliminating swap-remove pointer invalidation), FIFO `PalWaiter` lists per `(fd, direction)` (preventing second-fiber `udata` overwrites on `kqueue` and `epoll`), and per-emission `out_n < max_events` bounds checks with one-shot re-arming for leftover waiters. Regression-tested in `tests/stdlib_runtime.c` (`test_poller_multi_waiters_and_overflow`); `ninja test` and `ninja asan_test` pass. See [platform-abstraction-layer](/concepts/platform-abstraction-layer.md).

- 2026-11-19 (antigravity/1): Fix `ocamlcc_weak_get_copy` and `dup_with_tag` (`Obj.dup`/`Obj.with_tag`) segfaults and double-frees by unifying both on `dup_with_tag`: handle `ARC_TAG_STRING` (`reserved` length), `ARC_TAG_CLOSURE` (`env[]`), `ARC_TAG_PAP` (`orig` + `args[]`), `ARC_TAG_ARRAY` (`byte_size / 8u`), and `ARC_CUSTOM_INT32`/`INT64`/`NATIVEINT`, while returning retained aliases for uncopyable runtime-managed objects (`WEAK`, `FIBER`, `CHANNEL`, and handle `CUSTOM` blocks). Regression-tested in `tests/stdlib_runtime.c` (`test_weak_get_copy_and_obj_dup`); `ninja test` and `ninja asan_test` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (antigravity/1): Fix `ArcHeader.reserved` aliasing in the cycle collector root table: guard `cc_roots_remove_locked` with `!is_cycle_candidate_obj(hdr)` (preventing `ARC_TAG_CUSTOM` / leaf drops with `g_cc_active != 0` from underflowing/corrupting `g_cc_roots`) and remove `dhdr` from `g_cc_roots` under `g_cc_lock` before mutating `dhdr->tag`/`dhdr->reserved` in `caml_update_dummy`. Regression-tested in `tests/stdlib_runtime.c` (`test_buffered_dummy_update`) and `tests/mt_ffi_host.c` (`test_custom_leaf_collect_race`); `ninja test` and `ninja asan_test` pass. See [perceus-arc](/concepts/perceus-arc.md).

- 2026-11-19 (codex/1): Validate numeric format strings before passing them to `snprintf`. Runtime regressions cover float and integer formatting, boxed integer modifiers, and malformed format rejection. See [stdlib compatibility](/concepts/stdlib-compatibility.md).

- 2026-11-19 (codex/1): Integrate the ocpkg companion with main c7db0de. Compiler/runtime/ASan checks, 15 package tests, nine Crunch integration checks and all 71 non-Lwt checks pass. Record refreshed identities in packages/evidence/main-integration-2026-11-19.json.

- 2026-11-19 (codex/1): Keep scalar-only numeric matches with a default arm unboxed. The 128-element int64 loop fell from 771 to 3 ARC words. A checked int32 load in the default arm still raises before the store. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Keep scalar-only variant match results unboxed. The four-arm int64 loop fell from 771 to 3 ARC words. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Specialize integer conversions between boxed widths and OCaml int. The 128-element fixture went from 1539 to 3 ARC words. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Feed signed relational and three-way comparison primitives from unboxed integer Bigarray values. The int32 fixture fell from 387 to 3 ARC words for 128 elements. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Keep signed division and remainder unboxed, preserving zero-divisor exceptions and the minimum-integer overflow case. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Specialize negation, bitwise operations, and all three shift forms for integer Array1 expressions. The int32 fixture fell from 3075 to 3 ARC words. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Join scalar int32, int64, and nativeint conditional results at their machine widths. The 128-element loops match the three-word empty-loop control. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Specialize nativeint Array1 loads, stores, and wrapping arithmetic on 64-bit targets. The 128-element loop fell from 1539 to 3 ARC words. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Keep int32 Array1 loads and wrapping arithmetic unboxed at 32-bit width. The 128-element loop fell from 1539 to 3 ARC words. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Specialize int64 Array1 loads, stores, and wrapping arithmetic. The 128-element loop fell from 1539 to 3 ARC words. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Generate bindings for Array3 and Genarray. The C host keeps an Array2 plane alive after releasing both parents and exercises fixed and dynamic rank checks. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Specialize float32 Array1 loads and stores while preserving double precision in expressions and rounding at the write. The 128-element test fell from 1155 to 3 ARC words. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Extend float64 Array1 scalar lowering to addition, subtraction, and division. The 128-element fixture exercising all four operations fell from 1923 to 3 ARC words. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Keep named conditional results unboxed when all uses accept doubles. A boxed result shared with a closure keeps its identity. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Lower inline float64 conditionals feeding a Bigarray store to a double phi. The 128-element fixture matches its three-word empty-loop control. See [memory views](/concepts/memory-views.md).

- 2026-11-19 (codex/1): Keep named float64 Array1 reads and products unboxed when all their uses accept doubles in the same straight-line chain. The 128-element test again matches its three-word empty-loop control. See [memory views](/concepts/memory-views.md).

- 2026-11-18 (codex/1): Keep a direct float64 Array1 load, multiply and store unboxed in C and Fortran layouts. The 128-element scale fixture fell from 771 to 3 allocated words, matching the empty-loop control. See [memory views](/concepts/memory-views.md).

- 2026-11-18 (codex/1): Preserve Bigarray access metadata through ARC to QBE code generation. Tests cover a float64 scale loop, overlapping views, partial writes on bounds failure, and unsafe and polymorphic access signatures. See [memory views](/concepts/memory-views.md).

- 2026-11-18 (codex/1): Import caller-owned writable storage into Bigarray views. The final owning view schedules the native release callback outside ARC traversal and collection, including when a cycle owns the last view. See [memory views](/concepts/memory-views.md).

- 2026-11-18 (codex/1): Verify non-Lwt package behavior: both Crunch plain golden tests, 65 Cmdliner reference comparisons and 900,813 Ptime comparisons pass. Preserve upstream tests and record the B0 assertion adapter, independent libc oracle and negative controls in [package catalog](/concepts/package-catalog.md).

- 2026-11-18 (codex/1): Implement the ocpkg companion and build ocaml-crunch 4.1.0 from pinned sources with an explicit Unix adapter. Record 15 package tests, nine integration checks and passing compiler tests in [package catalog](/concepts/package-catalog.md).

- 2026-11-18 (codex/1): Record the package companion design and ocaml-crunch MVP plan in [package catalog](/concepts/package-catalog.md).

- 2026-11-18 (codex/1): Generate C bindings for concrete Bigarray.Array2 arguments and results. The C host releases a matrix and continues reading and writing its zero-copy Array1 row. See [memory views](/concepts/memory-views.md).

- 2026-11-18 (codex/1): Scope generated Bigarray view helpers to each module and reject input handles owned by another ARC heap. A two-library C fixture exercises both plain shared builds and libraries with native stubs.

- 2026-11-18 (codex/1): Generate typed Bigarray.Array1 C arguments and owned results. The C host checks subview aliasing after parent release, metadata errors and exception cleanup through a shared library. See [memory views](/concepts/memory-views.md).

- 2026-11-18 (codex/1): Export retained Bigarray subviews to C through an installed C/C++ header. Native tests cover aliasing, weak clearing after the last release, Fortran column offsets, empty views and rank-zero scalars. See [memory views](/concepts/memory-views.md).

- 2026-11-18 (codex/1): Publish a released finalizer queue to polls and explicit collections on other mutators. A native FFI regression observes delivery before the releasing thread resumes, even when a fresh trial cannot run.

- 2026-11-18 (codex/1): Implement Gc.finalise_release for nested dispatch. The shared stock OCaml and ARC fixture verifies callback order, exactly-once delivery, and the lifetimes of the outer argument and a captured buffer.

- 2026-11-18 (codex/1): Add the Bigarray memory-view implementation brief: retain ARC/QBE, specialize scalar loops, expose retained C views and foreign backing ownership, and focus on ARM64/AMD64 Linux/macOS. Defer MCU work and record measurement/reporting guidance without performance thresholds.

- 2026-11-18 (codex/1): Deliver allocation-driven finalizers at function and loop polls. Cover alarm deletion, exception propagation and mutable-slot cleanup on the normal and unwinding paths. An empty registry preserves explicit cycle collection.

- 2026-11-18 (codex/1): Verify exception propagation and pending-callback retention on both compilers. Refresh the upstream matrix after finalizer delivery, including the remaining Sys.opaque allocation-count difference.

- 2026-11-18 (codex/1): Preserve pending finalizers when an active FFI mutator prevents a collection. Verify concurrent last-owner release and exactly-once delivery after the gate reopens.

- 2026-11-18 (codex/1): Count incoming edges to leaf objects when the collector evaluates leaf finalizers. A byte buffer and its owning ref now finalize in reverse registration order in one discovery.

- 2026-11-18 (codex/1): Fix trial-map rehashing on page-rounded capacities. The 1,500-target finalizer regression now completes with exactly one callback per target.

- 2026-11-18 (codex/1): Deliver last callbacks when the weak registry confirms permanent death. The compatibility suite now runs the full lifecycle and alarm reference fixture.

- 2026-11-18 (codex/1): Implement ordinary callback discovery and resurrection at explicit major collections. Registration pins protect reuse without adding lock traffic to ordinary drops. Preserve the last use of Sys.opaque_identity across collection.

- 2026-11-18 (codex/1): Specify lock ordering and the empty-registry drop path for finalizers after checking existing allocator, cycle-candidate and weak-lock traffic.

- 2026-11-18 (codex/1): Define the proposed ARC finalizer lifecycle, including resurrection, trial deletion, weak clearing, callback delivery and alarm re-registration.

- 2026-11-18 (codex/1): The 14 Dune suites, 26 Ninja checks, 16 ASan/UBSan checks and installed core-stdlib driver smoke test pass on Ubuntu 24.04 arm64 with OCaml 5.5.2 and on macOS arm64 with OCaml 5.5.0. The macOS installed driver also passes the three-module Map.Make(String) registration test with the compatibility stdlib.

- 2026-11-18 (codex/1): The Ninja shared-library rule links libm for the math primitives it includes. Its C host can link the resulting shared library directly on Linux.

- 2026-11-18 (codex/1): The driver returns a diagnostic naming an unavailable external tool, including xcrun when an iOS build runs on a Linux host.

- 2026-11-18 (codex/1): The Linux PAL and libc bindings request the default glibc interfaces before including headers. Strict C11 builds use these interfaces for the monotonic clock, anonymous mappings and mutex attributes.

- 2026-11-18 (codex/1): Each standalone test executable declares its module explicitly so Dune 3.14 can also build the suite.

- 2026-11-18 (codex/1): The compatibility build compiles 72/72 interfaces and implementations. All 11 repository API fixtures pass on both stock OCaml and ocamlcc, including structural comparison and finalizer registration. Of 119 upstream files, 67 pass, ten fail and 42 are skipped.

- 2026-11-18 (codex/1): Bindgen reserves legal record member names before escaping C and C++ keywords and resolving collisions. The header and conversion shim share the resulting field names.

- 2026-11-18 (codex/1): Gc.finalise and Gc.finalise_last raise a catchable Failure when called on the ARC runtime. Code that needs external resource cleanup can handle the failure at registration time.

- 2026-11-18 (codex/1): A staged Dune installation supplies the vendored QBE executable and core stdlib and runtime sources relative to the compiler prefix. The installed driver can build multi-unit executables outside the checkout.

- 2026-11-18 (codex/1): Dune builds the vendored QBE needed by the driver integration suite. A fresh OCaml 5.5 checkout can run dune runtest before any Ninja targets.

- 2026-11-18 (codex/1): A load acquires its owned reference while replacement of that slot is excluded. Exchanges transfer slot ownership to their caller, and successful compare-and-set releases the displaced reference after unlocking.

- 2026-11-18 (codex/1): Polymorphic predicates propagate unordered floating-point comparisons through lists, records and arrays. Stdlib.compare supplies the total ordering that places NaN before numbers.

- 2026-11-18 (codex/1): Structural predicates raise Invalid_argument when they reach a functional value, including two references to the same closure. Physical equality is available through (==).

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
