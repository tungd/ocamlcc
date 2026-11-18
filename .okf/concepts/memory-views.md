---
type: Implementation Brief
title: Bigarray memory views and native buffer interoperability
description: Keep automatic ARC while making Bigarray scalar loops and C buffer sharing efficient on ARM64 and AMD64 Linux and macOS.
tags: [memory, bigarray, ffi, compiler, performance]
status: draft
generated:
  by: codex/1
  at: 2026-11-18T04:57:21Z
sources:
  - id: scope
    resource: Conversation on 2026-11-18 about ARC, Bigarray, memory views, and desktop target scope
    title: User direction and deferred MCU work
  - id: view-api
    resource: ../../runtime/ocamlcc_bigarray.h
    title: Public C view handle and borrowed descriptor
  - id: bigarray
    resource: ../../runtime/bigarray.inc
    title: Bigarray storage, scalar access, and shared views
  - id: runtime
    resource: ../../runtime/arc.c
    title: ARC backing ownership and reclamation
  - id: lowering
    resource: ../../lib/anf.ml
    title: Bigarray primitive lowering
  - id: codegen
    resource: ../../lib/codegen_expr.ml
    title: Boxed scalar arithmetic and C calls
  - id: bindgen
    resource: ../../lib/c_bindgen.ml
    title: Generated C types, marshalling, and ownership
  - id: tests
    resource: ../../tests/stdlib_runtime.c
    title: Native runtime lifetime regressions
---

# Objective and scope

Preserve ordinary OCaml programming with automatic ARC. Users opt into
Bigarray for contiguous numerical data, reusable buffers, and native-library
interoperation, as they do with stock OCaml. Improve that path without adding
Rust-style ownership syntax or requiring a new region system.[^scope]

Target ARM64 and AMD64 on Linux and macOS. Keep QBE and the current 64-bit
value representation. MCU support, RV32, other backend choices, and embedded
runtime profiles remain future work. This brief does not remove existing
support for other platforms; they are outside this implementation scope.

Here, a **memory view** means a Bigarray descriptor or a C-facing descriptor
referring to existing Bigarray storage. It is not a new OCaml collection or a
language-wide borrowing feature. Reuse `Array1`, `Array2`, `Array3`, and
`Genarray` APIs and their existing slicing/layout semantics.

The user selected the architecture and platform scope above. The runtime C
view API is implemented. Generated bindings, foreign imports and scalar
specialization are proposed follow-up slices. No elapsed-time or speedup threshold
has been specified.

# Current behavior

Source inspection on 2026-11-18 establishes the following implementation
baseline; it does not establish a timing baseline.

| Area | Current behavior | Consequence |
|---|---|---|
| Storage | `ArcBigarray` points to an ARC-owned `ArcBigarrayBuffer` with PAL-allocated data. | Numeric elements have no individual ARC headers or counts. |
| Views | `ba_view` retains the backing and adjusts the data pointer; sub, slice, reshape, and layout changes use shared storage. | A view can outlive its original wrapper without copying the payload. View creation still allocates a descriptor. |
| Scalar reads | `ba_read` boxes floats, `int32`, `int64`, native integers, and complex results; immediate integer kinds remain tagged values. | Preallocating a Bigarray does not currently make its scalar processing loop allocation-free. |
| Scalar arithmetic | Existing floating arithmetic uses boxed inputs/results around QBE arithmetic. | Optimizing only the Bigarray load leaves allocation in the arithmetic chain. |
| Primitive lowering | `Pbigarrayref` and `Pbigarrayset` discard kind/layout metadata when lowered to generic C calls. | Preserve useful primitive information before implementing specialized code generation. |
| C bindings | Bindgen supports basic types, options, tuples, records, and abstract handles, but has no dedicated Bigarray view type. | General record/string marshalling is not the desired buffer-sharing path. |
| Release | Last backing-owner release calls `pal_page_free`; ordinary ARC can synchronously destroy object graphs. | Stable addresses and predictable ownership do not guarantee bounded release time. |

These behaviors are in `runtime/bigarray.inc`, `runtime/arc.c`, `lib/anf.ml`,
`lib/codegen_expr.ml`, and `lib/c_bindgen.ml`.[^bigarray][^runtime][^lowering][^codegen][^bindgen]

# Ownership and view contracts

## OCaml views

Retain the existing shared-backing model. Each live view owns a reference to
the backing; dropping one view does not invalidate siblings. Data pointers
remain stable while the backing is owned. Payload reclamation happens once,
after its final owner releases it. Numeric payload cleanup does not walk the
elements.

Preserve aliasing: writes through a mutable view are visible through other
views of the same range. Preserve bounds, C/Fortran indexing, reshape element
counts, and overlapping `blit` behavior. Validate size/offset calculations
against overflow and actual backing extent. An empty view has zero accessible
bytes even if its allocator reserves a nonzero physical allocation.

Do not add an eager `dispose` operation that frees storage beneath live views.
Users control critical-path allocation by constructing and retaining reusable
buffers and views before the loop, then releasing ownership at a chosen point.

## C access to OCaml buffers

Include `ocamlcc_bigarray.h` from the installed package’s `runtime/` directory
and link the ocamlcc runtime. `ocamlcc_bigarray_view_acquire(value)` borrows a
live ocamlcc value and returns an opaque owner for a Bigarray. For another
valid value it returns `NULL` and leaves the OCaml exception slot alone.
Each successful acquire or retain requires one release.[^view-api]

`ocamlcc_bigarray_view_info(view)` returns the start of the contiguous view,
its logical byte length, element kind, layout, rank and dimensions. Dimensions
follow OCaml axis order for both layouts. The descriptor borrows its pointers
from the retained wrapper. An empty subview has zero accessible bytes. A
rank-zero Bigarray contains one element.[^bigarray]

| Operation | Ownership |
|---|---|
| Borrow data or dimensions | Keep a view owner alive through the last use of either pointer. |
| Give a second C caller ownership | Pass the result of `ocamlcc_bigarray_view_retain(view)`. Each caller releases its own reference. |
| Start asynchronous work | Hold an owner until completion or cancellation has stopped access. Synchronize writes across aliases. |
| Release an owner | Call `ocamlcc_bigarray_view_release(view)`. Acquisition, retain and release participate in the runtime mutator gate. |
| Pass an owned view back into OCaml | Planned bindgen work must give the OCaml callee its own reference and preserve the caller’s owner. |

The runtime test exports a subview at a nonzero offset, observes a C write
through a sibling, then drops all OCaml strong owners and collects. The last C
owner still has valid data and dimensions. Releasing it clears the weak slot
for the exported wrapper and restores the starting live-object count.[^tests]

On 2026-11-18 the runtime fixture passed on ARM64 macOS (native and
ASan/UBSan), ARM64 Linux in a local VM, and AMD64 Linux under emulation.
The AMD64 macOS fixture cross-linked on the ARM64 host, which could not
execute x86_64 macOS binaries. A C++17 consumer compiled and linked
against the installed header on ARM64 macOS.

## Foreign storage imported into OCaml

An imported buffer needs a backing owner independent of the C call's stack.
Support a native owner retained for the backing lifetime, or an explicitly
transferred allocation with a matching release callback/context. The backing
stores the original allocation information; a slice's offset pointer must
never be passed to the allocation's deallocator.

Make ownership transfer occur on successful import only; error paths leave
the caller's ownership intact. Release the foreign owner exactly once when
all OCaml and C views are gone. Specify which thread can invoke the callback;
a practical default is the final releasing thread, with thread-affine native
resources using their own dispatch adapter. Callbacks must not throw across
the C boundary or depend on an OCaml finalizer eventually running. The collector
currently releases outgoing references while holding its collection lock and
excluding other mutators. Detach any reentrant native cleanup there and run it
after the gate reopens.[^runtime]

An unowned pointer valid only during a C call cannot become an ordinary
escaping Bigarray: OCaml code may store it globally or capture it. General
imports therefore require an owner or a copy. Any internal scoped borrow
must actually enforce non-escape; a callback-shaped API alone is insufficient.
Do not expose read-only foreign storage as an ordinary mutable Bigarray.

# Unboxed scalar processing

Preserve kind, layout, rank, and checked/unchecked access information in ANF
where the frontend supplies it. Add a scalar representation path that keeps
Bigarray loads, arithmetic, comparisons, and stores unboxed when their uses
permit it. Address the whole local expression chain, including branch/loop
joins and scalar accumulators, rather than replacing one allocating helper
with another allocating operation.

Start with float64 and immediate-integer loops, then extend to float32 and
boxed-integer kinds. Keep complex and other unsupported specialized cases on
the correct generic path until implemented; report coverage by kind instead
of claiming all Bigarray access is allocation-free.

For example, this existing OCaml expression should use scalar loads,
arithmetic, and a store inside the loop when its types are known:

```ocaml
let scale
    (src : (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t)
    (dst : (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t) factor =
  for i = 0 to Bigarray.Array1.dim src - 1 do
    dst.{i} <- src.{i} *. factor
  done
```

Check bounds according to the source operation; this example does not imply
that `dst` has the same size as `src`. A short destination retains the prefix
written before the exception. Overlapping subviews observe earlier writes
in loop order. Keep buffer owners alive through the
last access, including exceptional exits and any supported suspension paths.

Box where a scalar crosses the ordinary OCaml value ABI: a generic call,
polymorphic container, escaping closure, or other use needing a value. Preserve
sharing/identity of a materialized value where observable. Do not give ARC an
unboxed machine integer or float and let it interpret the bits as a pointer.
Specialized function signatures are optional; local specialization with
correct boxing boundaries is sufficient to begin.

Preserve numerical semantics: float32 writes round as before, float reads
produce OCaml float semantics, integer kinds retain their width/sign behavior,
and NaNs, infinities, signed zero, conversions, and exceptions retain their
specified behavior. Do not enable fast-math as a substitute for specialization.
Unknown kind/layout or unsupported escape patterns retain the generic path.

# Suggested implementation slices

1. **Public runtime view ownership (implemented).** The C handle retains the
   exported wrapper and exposes its data and dimensions across collection.
2. **Generated Bigarray bindings.** Teach typed signature translation about
   Bigarray inputs/results and share the runtime view contract across generated
   modules. Cover `Array1`, `Array2`, `Array3`, and `Genarray` as supported forms;
   reject unsupported signatures explicitly. Keep metadata validation and
   exception/error cleanup inside the existing mutator-gated shim boundary.
3. **Foreign backing ownership.** Add imports with an owner/release policy and
   caller-provided storage, verifying import failure and sibling-view teardown.
4. **Typed scalar lowering.** Preserve primitive metadata, specialize a complete
   float64 loop, and expand kinds while keeping generic fallback behavior.
5. **Integration and reporting.** Update examples, public C ownership comments,
   [stdlib compatibility](/concepts/stdlib-compatibility.md), and the
   [compiler pipeline](/concepts/compiler-pipeline.md) to describe implemented
   behavior and remaining generic paths.

Use the existing `lib/arc_pass.ml`, `lib/ccalls.ml`, `lib/codegen_*.ml`,
`lib/qbe_il.*`, `runtime/arc.h`, and `runtime/bigarray.inc` seams. QBE IL may need
additional scalar load/conversion forms for float32; this does not call for a
backend replacement. Runtime internals can be factored into a dedicated public
buffer header without exposing the private object layout.

The repository can contain concurrent finalizer/compiler work. Inspect the
current diff before edits, preserve unrelated changes, and reconcile shared
runtime and ANF interfaces rather than replacing files from an old snapshot.

# Behavioral checks and measurements

Extend existing tests to cover the behavior changed by each slice:

- **Lifetime:** original wrapper dies before a subview; chained views; multiple
  C owners; retained native access across explicit collection; asynchronous
  completion/cancellation; foreign deallocator called once, with the base
  allocation and correct context, after the last owner.
- **Validation and cleanup:** empty buffers, zero dimensions, malformed
  dimensions, byte-size/offset overflow, kind/layout mismatch, misalignment,
  failed import ownership, and exceptions during generated calls. Test
  documented error handling rather than dereferencing arbitrary invalid C
  pointers.
- **Representation:** C and Fortran layouts, alias-visible writes, overlapping
  blits, float32/float64 edge values, signed/unsigned widths, boxed escapes,
  branch/loop joins, and generic fallback. Compare source-level results with
  stock OCaml where the public APIs match.
- **Compiler output:** inspect generated IR for representative specialized
  loops and verify that scalar temporaries avoid allocation/retain/release
  calls while buffer ownership remains valid.

Use cumulative allocation counts around warmed, preallocated kernels; a
zero change in live objects alone can hide allocate/free churn. Separately
measure buffer creation, view creation, scalar processing, and final release.
Record input sizes, iteration counts, compiler options, target, allocation
deltas, elapsed-time distributions, and full result paths. Compare actual
before/after results without inventing speedup or frame-time thresholds.

Useful existing commands, run sequentially as applicable to the implementation:

```sh
ninja -j1
python3 tools/stdlib_compat.py --skip-tests
python3 tools/stdlib_regressions.py bigarray
python3 tools/stdlib_regressions.py --stock bigarray
dune runtest -j1
ninja -j1 test
ninja -j1 asan_test
```

The C runtime suite already includes Bigarray lifetime coverage.[^tests]
Extend the bindgen and runtime suites for the new public view ABI. Report
execution coverage separately for ARM64 Linux, AMD64 Linux, ARM64 macOS, and
AMD64 macOS; assembly generation alone does not establish native behavior.
Record unavailable environments rather than treating them as passing.
Do not overlap heavy builds or measurements, and verify an earlier run has
finished before launching the next one.

# Deferred work and timing limits

No autorelease pool, general arena/region system, ownership syntax, global
non-atomic ARC switch, or incremental destruction queue is part of this brief.
Buffer reuse reduces allocation pressure but does not bound arbitrary ARC
destruction, collector work, OS page operations, or native cleanup callbacks.
Users retain buffers across critical work and schedule their release; this
feature does not promise hard real-time execution.

MCU/RV32 support, an MCU runtime profile, and QBE target expansion remain
future work. Arbitrary strided memory views and device-specific allocation
policies can be added separately when a concrete integration needs them.

[^scope]: User direction: ordinary ARC plus opt-in Bigarray, retain QBE, and focus on ARM64/AMD64 Linux/macOS; defer MCU work.
[^view-api]: Public handle ownership, descriptor fields and element kind constants.
[^bigarray]: `ba_view`, `caml_ba_create`, `ba_read`, `ba_write`, and shared-view operations in `runtime/bigarray.inc`.
[^runtime]: `ArcBigarray`, `ArcBigarrayBuffer`, `release_subtree`, and mutator-gate hooks in `runtime/arc.c`.
[^lowering]: `Pbigarrayref`/`Pbigarrayset` lowering in `lib/anf.ml` currently emits C calls without preserving kind/layout information.
[^codegen]: `lib/codegen_expr.ml` emits scalar boxing and generic word-sized C-call arguments/results.
[^bindgen]: `lib/c_bindgen.ml` defines the supported C types, opaque ownership helpers, and generated exception/mutator handling.
[^tests]: `tests/stdlib_runtime.c` and `tests/stdlib/bigarray/main.ml` exercise existing shared-backing lifetime and source-level behavior.
