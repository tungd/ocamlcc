# Change Log

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
