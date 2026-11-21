---
type: Concept
title: Perceus ARC and freestanding slab allocator
description: Static Perceus reference counting with reuse analysis, zero-leak error-return exceptions, weak references, and freestanding slab allocation.
tags: [arc, memory, allocator, perceus, phase-2]
status: stable
generated:
  by: codex/1
  at: 2026-11-22
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: arc-pass
    resource: ../lib/arc_pass.ml
    title: Static Perceus ARC and reuse pass
  - id: arc-runtime
    resource: ../runtime/arc.c
    title: Freestanding ARC runtime and slab allocator
---

# Perceus ARC & Freestanding Slab Allocator

Phase 2 replaces libc `malloc`/`free` with a freestanding slab allocator and static Perceus reference counting with zero-leak error-return exceptions and weak references.

## Freestanding Slab Allocator & Thread Safety (`runtime/arc.c`)
- **Size classes and slab reclamation.** The 12 classes span 16 to 2048 bytes. Slabs have size and alignment of 64 KiB. PAL maps whole pages and trims the address range to keep one aligned slab. The `SlabPage` header starts at its base, so `slab_free` recovers the owner by masking the slot address. In the default runtime, the allocator lock protects the shared full and partial lists and per-slab freelists. Empty slabs return to PAL when their class has another slab, preserving one warm slab. Slots preserve 16-byte alignment.
- **Per-thread magazines in the default runtime.** A thread can cache up to 16 small slots per size class, including slots from different slabs. Local hits use a thread-local pointer and bypass the shared lock and pthread key lookup. A refill takes a batch under the lock. A spill returns half the magazine under one lock acquisition and unmaps retired slabs after unlocking. Cached slots pin their own slab until returned and are excluded from the live-object and allocation-word counters. The pthread key destructor drains the magazines at thread exit. The shared path handles threads that cannot create a cache and releases from later thread destructors. Native tests check reuse across slabs and reclamation after thread exit.
- **Optional single-thread ARC.** `ninja -j1 single_thread_runtime` produces `build/rt-single/libocamlrt.a` and the objects for `ocamlcc build --runtime-objects-dir build/rt-single`. The first OS thread to enter through a generated binding, the mutator gate, module initialization, or standalone collection owns this runtime for its lifetime. Those entry points reject a different thread. Callers of raw C runtime APIs must use the owner thread. That thread updates the slab lists and freelists without locking and uses load/store updates for reference counts and allocation counters. The counters still support atomic snapshots and the header and C signatures are shared with the default profile. `ninja -j1 test_single_thread_rc` checks array ownership, weak upgrades, reuse, allocation accounting, slab reclamation, and rejection of a second entrant.
- **Inline single-thread ARC.** Pass `--inline-single-thread-rc` to
  `ocamlcc build --runtime-objects-dir build/rt-single` after building the
  single-thread runtime. The option also works with `ocamlcc compile` when
  the resulting object is linked against that runtime. Generated module
  initializers use a single-thread entry symbol, which makes runtime-profile
  mismatches visible during executable linking. Mortal heap retains
  update the header directly. Shared releases inline the decrement when
  the object is already buffered for cycle collection or its string,
  float, float-array, or custom tag needs no registration. First-time
  cycle registration and final releases use the runtime. The native test
  also runs the cycle-collection fixture with inlining enabled.
- **Atomic refcounts & counters**: `ArcHeader.refcount` is `_Atomic uint32_t`, updated via C11 `<stdatomic.h>` (`arc_retain`, `arc_release`, `arc_drop_reuse`, `drop_child_val`, `arc_alloc_array`, plus CAS-based `arc_try_retain` for weak-ref upgrades); `g_live_objects`, `g_reuse_hits`, and `g_next_oo_id` are `_Atomic int64_t`.
- **Large blocks**: allocations `> 2048` bytes round up to `16 KB` page alignment and release directly via `pal_page_free`.
- **O(1)-stack tail drop**: `release_subtree` tail-iterates on the last dying child (`tail`) and uses a `256`-entry stack buffer plus lazy `pal_page_alloc` overflow pages (`DropPage`) for deep non-tail trees. `cc_roots_add` is invoked before `atomic_fetch_sub` when `rc > 1`, preventing any race with a concurrent final drop.

The single-thread runtime uses one static magazine per size class under
the existing mutator ownership rule. It accesses cached slots without
pthread TLS or allocator locking. A full process-owned magazine returns
its older half in one batch so old cached slots age out as frees continue.
Thread-local magazines retain their existing spill order and drain at thread exit.

## Middle-End ARC Pass (`lib/arc_pass.ml`)
- **Ownership**: `Let`-bindings and function parameters start owned (`+1` rc); `Pure` global functions and static literals/immediates omit refcount traffic; closure captures (`env`), self-refs, and `LetJoin`/`While`/`For` outer references are **borrowed** (with `frame_borrowed` distinguished so exceptional unwinding cleans them up cleanly).
- **Pure-defs analysis** (`Anf.pure_defs`, shared by `arc_pass` and `codegen`): a function (or whole mutual `let rec` group) whose free variables are only its own parameters plus already-collected pure functions is an immortal static function — its binding gets no refcount traffic (no `Release`, no `DropReuse`), and codegen defines it with `has_closure = false` and groups mutual tail calls into trampoline SCCs. The analysis recurses into function bodies and every branch/join region (`LetJoin` rhs, `If`, `Switch`, `TryWith`, `While`, `For`, `StaticCatch`), so non-capturing helpers nested inside other functions are static too; a spine-only walk used to own+release them, forcing codegen to synthesize an immortal `clos.N` wrapper purely to feed `arc_release_val`. Regression-tested in `test/pure_nested_test.ml` (fronted through `Frontend.compile_implementation`, asserting non-capturing funs are never `Release`d).
- **Borrowed OCaml parameters.** Static functions can use an alternate entry for read-only pointer arguments. The ARC pass follows saturated forwarding to other borrowed parameters and solves recursive groups to a fixed point. Direct callers can select the worker when they already keep the arguments live. The owning entry handles closure calls and imports without a borrowed entry. Mixed calls transfer arguments in the owning positions. Unknown and potentially suspending calls keep the conservative convention.
- **Field and array ownership.** Lambda's immediate field stores lower to a single store. Overwriting a pointer-capable field or array moves the old value out before publishing the new value and releases the old owner on the heap path. Pointer-capable reads test the loaded value before retaining. Generic arrays still dispatch on the runtime layout, and checked stores release a rejected pointer-capable argument on the exception path.
- **Codegen heap proofs.** Fresh block, array, closure, and boxed numeric allocations produce non-null heap values. Copies and joins keep that fact when all inputs are known heap values. Checked byte and array allocations establish it only after the success check. ARC operations on proven heap values skip the tag and null guard. Unknown values combine both tests into one branch.

- **Local immutable aggregates.** The Lambda pass replaces an immutable block of one to four fields with its component bindings when all uses project fields or inspect the known constructor. Strict bindings expose the final allocation under inlined argument bindings and sequences. Conditional and match expressions with a common constructor and field count pass their components through a static join. Tuple, option, and result payloads still evaluate once, even when unused. Escaping values and closure captures retain the aggregate and its ordinary ownership.
- **Local field borrows.** ARC can fuse an immutable pointer projection into a local access or load it once as a borrowed view when a loop reads it. Liveness keeps the receiver through the last view use and protects it across intervening calls and unwinds. Branches inside the loop can read the view. The loop condition on this optimization preserves early receiver retirement and constructor reuse in ordinary matches. Mutable fields fuse only with an adjacent reader. Escaping projections and projections passed to calls with unknown ownership keep the owning path.
- **Field & mutation balance**: Field reads with Lambda’s `Immediate` kind and `Pintarray` reads produce tagged immediates, so codegen omits the retain and ARC treats the result as unmanaged. Other pointer-capable field and array reads retain their results. `test/immediate_access_test.ml` checks both paths. `SetField`/`ArraySet`/`Assign` release overwritten values; a `MutLet` slot is released exactly once, where it leaves scope (function-exit `Halt`, `Raise`, or `StaticRaise` to a narrower handler).
- **C-call ABI registry** (`lib/ccalls.ml`): runtime primitives lowered to `Ccall` are classified in one typed table — `argc`, `raises` (stores to `ocamlcc_exn_slot`, so call sites inside `TryWith` get `CheckExn` unwinding), and `yields` (can suspend the fiber, so call sites join the shadow-stack protocol). `anf.ml`'s external lowering consults it: registered `caml_*` primitives lower to `Ccall`, unknown `caml_*` primitives are rejected at compile time, and user externals lower through their declared native ABI. The old hardcoded `ce_may_raise_fn`/`is_yielding_ccall` name lists (which drifted — `Weak.get_copy` was missed once) are gone; `runtime/arc.c`'s `caml_blit_bytes`/`caml_blit_string`/`caml_fill_bytes` raise `Invalid_argument "index out of bounds"` on out-of-bounds (like real OCaml) instead of `pal_abort`, and are registered as raising. ABI contract pinned by `test/ccalls_test.ml`; end-to-end by the `invarg=` probes in `examples/stdlib_test.ml` (which also probe `caml_floatarray_blit`/`caml_floatarray_fill` — both delegate to `caml_array_blit`/`caml_array_fill`, so they are registered `raises = true` and `returns_imm`: an out-of-bounds fill must be caught by the enclosing `TryWith` (`CheckExn` emitted) and must not poison `ocamlcc_exn_slot` for the next checked call, pinned by the `i_fa_oob`/`i_fa_ok` probes).
- **Comparison contract** (`val_compare_raw` in `runtime/arc.c`): structural comparison is bounded — a C-recursion depth limit (10 000) plus a shared step budget (10⁸) raise `Invalid_argument "compare: cyclic structure"` instead of smashing the stack on cyclic records (even under ASan `-O1` stack-frame instrumentation) or spinning forever on tail-cyclic lists. Unscanned leaf blocks (`ARC_TAG_FLOAT`, `ARC_TAG_FLOAT_ARRAY`, `ARC_TAG_CUSTOM`) compare by numeric/element value and are excluded from `is_cycle_candidate_obj`, `release_subtree` child walks, and `cc_visit_children` via `is_unscanned_leaf_tag`. Float/custom unary and binary ops return owned `rc=1` boxes (`is_imm_binop` / `is_imm_unop`), `FloatField` returns a fresh `rc=1` box, `SetFloatField` borrows the source float, and `Pfloatarray`/`Pgenarray` array construction/mutation release consumed `ARC_TAG_FLOAT` inputs after copying their unboxed `double` payloads. Exception-constructor id blocks (tag 248: field 0 = name string, field 1 = OID) compare **structurally** (name string, then OID) like real OCaml, deterministically, instead of by raw heap address. `pipe`/`fd_read`/`fd_write` raise on failure (`Sys_error "pipe failed"` / `Invalid_argument "index out of bounds"` on out-of-bounds reads/writes) instead of `pal_abort`, and are registered `raises = true` in the C-call ABI registry so `TryWith` unwinds correctly; OS errors on read/write still return the negative count for the Fiber I/O machinery to poll.
- **Immediate static joins and local slots.** A static handler argument needs ARC only when an incoming exit can pass a managed value. The pass intersects those facts per binder, follows local definitions and nested exits, and uses the handler facts when inferring the result of a catch or join. A local mutable slot uses the immediate convention when its initializer and every assignment are proven unmanaged and no closure captures the slot. That removes retains on reads, releases on writes or scope exit, and fiber shadow roots for that slot. A possible heap write keeps the owning slot path. `test/arc_immediates_test.ml` checks the emitted roots for immediate and mixed paths.
- **Generated ARC guards.** QBE lowers explicit retain and release operations, including owning-slot cleanup, to a tag test followed by a null check on the potential heap path. Tagged immediates and zero bypass the runtime call. The non-null heap path calls `arc_retain` or `arc_release`. The value helpers still serve C entry points and other runtime operations.
- **Mutable-slot scope invariant**: For owning slots, `Halt`s that flow into a `LetJoin` rhs, `While`/`For` condition/body, or a loop-exit continuation are *not* scope exits, so they must not emit `ReleaseMut` for slots that remain in scope. `env.no_release_muts` (set to `env.muts` when descending into those regions) defers such slots to the continuation that still uses them; `Halt` releases `env.muts - env.no_release_muts`. Muts introduced *inside* the region still release at its own `Halt`. Regression-tested at the middle-end level in `test/arc_mutlet_test.ml` (drives hand-written `Lmutlet` Lambda terms through `Anf.of_lambda` + `Arc_pass.run` and counts `ReleaseMut` per slot).
- **Native C externals.** User declarations use the compiler-libs native symbol and argument/result representations. Unboxed floats cross as C `double`, unboxed int32 as a 32-bit word, and unboxed int64, nativeint, and untagged OCaml int as 64-bit words on the supported targets. ARC keeps the boxed argument owners live through the call. A potentially raising call checks the exception slot before boxing its numeric result. A declaration with `[@@noalloc]` promises that the C entry point will neither allocate nor raise and skips the call-site exception check. User C primitives follow the existing non-suspending FFI contract. Registered runtime primitives retain their ocamlcc boxed ABI.

- **Internal closure application.** Generated OCaml calls use the raw apply helpers inside the OS-thread mutator boundary. Exact arities one through four dispatch directly with register arguments. Partial, over-, and larger applications use the generic dispatcher. The C host apply API, generated FFI shims, standalone main, and exported unit initializers establish the mutator boundary.
- **Over-application shadowing**: a call with more args than the callee's known arity is split by `lib/codegen_expr.ml` into a first exact-arity call plus an `apply_closure` over the tail. Both fragments can suspend, and the split frame has no arc-pass shadow window of its own, so every intermediate is registered on the fiber shadow stack by hand: the tail args (`rest_vals`) are compiled *before* the first (possibly suspending) call and pushed across it (an abandoned fiber would otherwise leak them — the frame that owns them never reaches its scope-exit release), popped once the first call returns; `clos_res` is pushed across `apply_closure` (whose runtime counterpart `ocamlcc_apply_n_raw` in `runtime/closure.c` shadows its own tail args and intermediate results across each internal invoke). The error path releases `rest_vals` after the pop, keeping push/pop/release balanced. End-to-end pinned by the `oapp=` probe in `examples/fiber_test.ml`: a coroutine abandoned inside the first (suspending) call of an over-applied function must release the tail argument (`Weak.check` cleared, delta 0).
- **Local ref promotion.** After Lambda inlining and flattening of strict right-hand sides, the compiler can replace a one-field mutable block with a stack slot. All uses must be field-0 reads, writes, or integer updates, including through immutable aliases. A closure capture or other use of the block address keeps the heap representation. Immediate slots bypass ARC and shadow roots. Pointer-capable slots retain their normal ownership and unwind cleanup. `test/local_refs_test.ml` exercises both lowered representations.
- **In-place reuse.** `DropReuse` pairs dead unique heap blocks with downstream `AllocReuse`. Independent tokens can reach different constructors in the same branch, and a claimed constructor can also accept a fallback token. The runtime selects a matching slab size class and frees the unused token. Each outstanding token is shadowed across suspending calls and freed on unmatched branches and exceptional exits. This allows the two-cell unroll in upstream `List.map` to reuse the complete unique spine. Shared spines remain readable and map builds new cells for them.

## Zero-Leak Exceptions, Cycle Collection & Weak Clearing
- **Zero-leak exceptions & `in_tail` tracking**: `tls_exn_slot` (`_Thread_local int64_t`, accessed via `ocamlcc_get_exn` / `ocamlcc_set_exn`) carries raised exception blocks per OS thread (swapped per fiber on `fiber_swap_to`); `CheckExn`/`Unwind` execute local frame cleanup before branching to enclosing `TryWith` handlers or returning `1` to callers. `Arc_pass` tracks `env.in_tail` (`false` inside `LetJoin` rhs, `TryWith` body, and `While`/`For` loops) so `is_pure_tail` never suppresses `CheckExn` or shadow push/pop on a `Halt` that flows into a downstream join point or loop continuation (regression-tested in `test/arc_checkexn_join_test.ml`). The raising analysis treats unknown and over-applied calls, yielding `Ccall`s, `Weak` `Ccall`s, structural/total-order comparison `Ccall`s (`caml_equal`/`caml_notequal`/`caml_compare`/`caml_lessthan`/`caml_lessequal`/`caml_greaterthan`/`caml_greaterequal`, which raise `Invalid_argument` on cyclic structures or functional values), `Binop ((Div | Mod), _, _)`, safe indexing (`StringGet`/`BytesSet`/`ArrayGet`/`ArraySet` with `safe = true`), `CreateBytes`, and `MakeArrayInit` as potentially raising so enclosing `TryWith` handlers retain live values, `CheckExn` unwinds frame values/reuse tokens, and `arc_alloc_bytes`/`arc_alloc_array`/`ocamlcc_weak_*` raise `Invalid_argument` (releasing consumed `init` on invalid array length) instead of aborting. `TryWith` preserves `env.frame_borrowed` alongside `catch_owned` in `try_owned` so raising inside joined expressions keeps borrowed references alive across handler and continuation execution.
- **Exception checks on the slow path.** A failed inline bounds check raises and enters the same ARC cleanup as a checked call. Success continues directly after the access. A fixed-point analysis follows saturated local calls and imported raising facts. Unknown calls and automatic finalizer callbacks remain potentially raising.
- **Recursive closures**: the [compiler pipeline](/concepts/compiler-pipeline.md) gives saturated recursive calls one shared dispatcher closure. Its environment owns the captures once, and optional wrappers for first-class uses in the enclosing body own that dispatcher independently. Direct tail transitions borrow the captures. The collector still covers cyclic structures and recursive groups that use sibling closures as values.
- **Cycle collector (`ocamlcc_arc_collect`)**: opt-in Bacon-Rajan trial-deletion collector over candidate roots in `g_cc_roots` (protected by `g_cc_lock` + `g_cc_active`), using a local `TrialMap` table so trial decrements never mutate live `ArcHeader.refcount` values concurrently; `drop_child_val` inside `release_subtree` registers surviving decremented children, and `cc_roots_remove_locked` (guarded by `is_cycle_candidate_obj(hdr)` so `ArcHeader.reserved` aliasing on custom blocks/strings/leaves cannot corrupt `g_cc_roots` when `g_cc_active != 0`) unregisters dying candidates (including `ARC_TAG_FIBER`, fixing a dangling-root double-free on fiber drops) before `slab_free`. **`ArcHeader.reserved` is `_Atomic uint32_t`**: `release_subtree` reads `(reserved & CC_BUFFERED)` *without* `g_cc_lock` to skip the lock on unbuffered drops, while another thread's `cc_roots_remove_locked` may swap-move that same header from the tail of `g_cc_roots` and rewrite its `reserved` — with a plain `uint32_t` that was a C11 data race (UB) even though `CC_BUFFERED` itself stayed set; all collector-side accesses (`cc_roots_add`, `cc_roots_remove_locked`, the root reset loop in `ocamlcc_arc_collect`) use relaxed atomics, and the lock-free read is `memory_order_relaxed` (advisory: the authoritative path re-checks under `g_cc_lock`). Pinned from both sides by the ThreadSanitizer suite: `ninja tsan_test` builds the runtime with `-fsanitize=thread` and runs `tests/cc_reserved_race.c` (4 workers buffering/dropping cycle candidates against a collector thread, which TSan reported as a data race on `reserved` before the fix) plus the `mt_ffi` concurrency stress under TSan. `caml_update_dummy` likewise calls `cc_roots_remove_locked(dhdr)` under `g_cc_lock` before mutating `dhdr->tag`/`dhdr->reserved`, preventing buffered dummies updated to strings or custom blocks from remaining in `g_cc_roots` as dangling/aliased roots. **Concurrency boundary & FFI mutator gate**: `ocamlcc_apply1..4` and `ocamlcc_apply_n` enter/leave an OS-thread mutator gate (`arc_mutator_enter` / `arc_mutator_leave` over `g_active_mutators` + `g_cc_waiting`, while `fiber_trampoline` and recursive PAP dispatch call `ocamlcc_apply*_raw` so fiber stack swaps never corrupt thread mutator state); `ocamlcc_arc_collect` (serialized by `g_cc_collect_lock`) drains active FFI mutators when called from outside `ocamlcc_apply*`, or safely skips (returns `0`) when called from inside an active FFI call while other mutator threads are running, preventing AB-BA deadlocks and trial-deletion use-after-free. C hosts holding raw cycle-candidate pointers directly outside `ocamlcc_apply*` must not concurrently mutate or drop them via `arc_release_val` during collection; generated `C_bindgen` FFI shims (`lib/c_bindgen.ml`) wrap `<mod>_init`, opaque `_retain`/`_release`, and every exported `<mod>_<val>` entrypoint (covering argument marshalling, `ocamlcc_apply*`, result unmarshalling, exception release, and `arc_release_val(res)`) inside `arc_mutator_enter()` / `arc_mutator_leave()`. **Fibers are cycle candidates**: the trial treats a fiber's shadow-stack slots, entry closure, resume/suspend payload, and per-fiber exception slots as owning child edges (`cc_visit_children`), so cycles through a suspended fiber's shadow stack (`record -> fiber -> record`) are collected; queued scheduler fibers keep the scheduler's `+1` from `spawn` and survive every trial, and collected fibers have their reuse tokens, stacks, and buffers torn down explicitly in the dead pass while leaf releases and `slab_free` run outside `g_cc_lock`. Regression-probed by `test_fiber_shadow_cycle` in `examples/cycle_collect.ml` and concurrent collector + 8-worker cycle stress in `tests/mt_ffi_host.c`.
- **Module-init slots & re-entrancy**: each compilation unit owns an `ocamlcc_global_<Mod>` slot (`0` = uninitialized, `-2` = claimed by an in-flight init, any other value = published module value). `ocamlcc_init_try_enter` CASes `0 → -2` and returns `1` to run the initializer; a `_Thread_local` active-slot stack (`tls_init_slots`, depth ≤ `OCAMLC_INIT_MAX_DEPTH = 64`) makes same-thread re-entrancy return `0` instead of spinning — mutually dependent units (`.mli`-mediated, e.g. `mut_a`/`mut_b` in `test/driver_test.ml`) recurse into each other's `ocamlcc_init_<Mod>` while the outer initializer is still running, and without this the inner call would spin forever on its own `-2` claim. A slot marked `-2` by a *different* thread is still spun on until published. `ocamlcc_init_finish` publishes the initializer result (or `0` when `ocamlcc_get_exn()` holds a raised exception, so a later initialization attempt can retry) and pops the thread-local claim.
- **Channel I/O buffers & Bigarray raw path**: `CamlinternalChannel` (`stdlib/camlinternalChannel.ml`) implements 4096-byte buffered `in_channel` and `out_channel` over raw POSIX fd wrappers (`ocamlcc_raw_fd_{read,write,lseek,size,close,isatty}` validating `Bytes` slices against `ArcHeader.reserved`, plus `ocamlcc_stdio_flush`). `CamlinternalChannel.unsafe_input_bigarray` / `unsafe_output_bigarray` transfer chunks through `ocamlcc_ba_of_bytes_slice` / `ocamlcc_ba_to_bytes` in `runtime/bigarray.inc`, which validate the Bigarray extent with `ba_channel_range` and slice the `Bytes` buffer against its `ArcHeader.reserved` rather than probing `(ArcHeader *)a->data - 1` (since `ArcBigarray.data` is a raw PAL page or foreign C pointer with no `ArcHeader`). Regression-tested in `tests/stdlib_runtime.c` (`test_bigarray_channel_io`) and `tests/stdlib/channels/`.
- **Weak arrays (`ARC_TAG_WEAK = 249`).** Weak registrations mark small heap targets before the weak slot can be observed. Both ARC retirement and cycle collection skip the weak lock and target hash for an unmarked small object. The hint uses the spare high bit of the atomic scan-count field, preserving the 16-byte header. The runtime reads the logical count with `arc_scan_count`. Large objects retain their full count and the existing weak-table check. Reuse clears the hint, shallow copying keeps each object's own hint, and dummy updates preserve an existing registration. Last finalizers and ordinary weak slots share registration; weak blits copy already-registered targets. Locked clearing still removes every matching slot before freeing the storage. Concurrent weak upgrades take an owned reference only while the target is alive.

### Cycle-root registration on drops

The first shared drop of a cycle candidate registers it under the root
lock. Further drops see the atomic buffered bit and bypass the lock.
A trial excludes competing mutators before it clears the bit, and insertion
still checks again under the lock. Retirement checks the buffered bit before
classifying the object and uses the locked removal path when required.

An immutable block can be part of a cycle created by a write to another block.
If a trial first sees that cycle as reachable, the next shared drop through
the immutable member must still register it. The native runtime test exercises
this sequence, and the concurrent root-table stress test exercises duplicate
drops and swap-moved root indices.

**Weak copies.** A shallow duplicate starts with its own weak-target state.
`Weak.get_copy` uses the same copy path as `Obj.dup` and preserves the logical
layout while taking ownership of copied pointer fields. Runtime-managed
objects such as fibers and unsplittable custom handles retain their existing
alias behavior.

# Ownership of atomic field values

A load acquires its owned reference while replacement of that slot is excluded. Exchanges transfer slot ownership to their caller, and successful compare-and-set releases the displaced reference after unlocking.

## Borrowed mutable-slot snapshots

A local mutable slot can lend its value to consumers such as byte operations
and pattern tests when the snapshot stays inside the frame and each read
precedes any overwrite on its path. A snapshot across a possible overwrite
keeps a reference to the original value. When both arms of a conditional
leave their result owned by the same slot, the continuation can read the slot
once after the join. This covers a buffer growth arm that stores the new
buffer and a fast arm that keeps the existing buffer.

Private workers can borrow a parameter across calls that leave the caller's
owner in place. C primitives and native externals borrow their OCaml
arguments under the C ABI. OCaml calls disqualify only values in owning
argument positions. Saturated local calls can forward to another worker's
borrowed positions. Functions that can suspend keep the owning convention.

A mutable field can lend its value to the immediately following projection
or other supported local reader. This removes ownership traffic for chains
such as `state.cursor.row`. A snapshot that survives an intervening call or
store keeps its own reference.

## Immediate-only word arrays

An array allocated from immediate elements starts with a zero scan count.
The first pointer store enables scanning before publishing the element. The
mark is sticky and preserves the weak-target bit. Marked arrays scan their
full payload, including indexes beyond 65,535. Generic and address-array
stores, bulk writes, and Obj and atomic field writers maintain the mark.
ARC can skip destruction scans and cycle-root buffering for unmarked
arrays. Raw C allocation keeps conservative scans because callers can
initialize its payload directly.

Recompile objects and stdlib archives built before this store protocol
when using them with this runtime. Earlier generated address-array
stores wrote pointers directly and could miss the scan mark.

A borrowed parameter can receive a byte, scalar, or immediate store. Pointer
stores transfer the new value but borrow the receiver. Worker inference
conservatively excludes other pointer parameters at a pointer overwrite.

Object and archive summaries carry the alternate entry symbol and a mask in
parameter order. The implementation stamp covers both entry points and the
mask. This keeps independently compiled callers tied to the same ownership
contract. Older summaries still select the owning entry.

Subtree retirement batches foreign Bigarray owners in traversal-local storage.
Ordinary releases touch no foreign-release TLS. Fiber destruction enters a
deferred scope before dropping nested roots, and callbacks wait until the
traversal and mutator or collector gate have finished. The single-thread
profile keeps its queue in ordinary static storage. Weak lookup starts only
after the inline header test, with the existing fallback for oversized
headers. Single-thread live-object accounting uses atomic snapshots and
load/store updates without atomic read-modify-write.

A lazy option join can return a view of the immutable payload when every arm
leaves that payload owned by the same local slot. An overwrite before a later
use, or a use that transfers ownership, keeps the owning path.

The fiber and foreign-owner branches call out to cold helpers. This keeps
Darwin's dynamic TLS address lookup outside the ordinary release traversal
even when the C compiler hoists TLS addresses out of conditional blocks.
