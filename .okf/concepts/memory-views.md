---
type: Implementation Brief
title: Bigarray memory views and native buffer interoperability
description: Keep automatic ARC while making Bigarray scalar loops and C buffer sharing efficient on ARM64 and AMD64 Linux and macOS.
tags: [memory, bigarray, ffi, compiler, performance]
status: draft
generated:
  by: codex/1
  at: 2026-11-18T17:08:44Z
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
  - id: lowering-test
    resource: ../../test/bigarray_lowering_test.ml
    title: Bigarray access metadata before and after ARC
  - id: codegen
    resource: ../../lib/codegen_expr.ml
    title: Boxed scalar arithmetic and C calls
  - id: bindgen
    resource: ../../lib/c_bindgen.ml
    title: Generated C types, marshalling, and ownership
  - id: tests
    resource: ../../tests/stdlib_runtime.c
    title: Native runtime lifetime regressions
  - id: c-host
    resource: ../../tests/bigarray_bindgen/host.c
    title: Generated Bigarray view ownership across two shared libraries
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
view API supports exported views and imports of caller-owned storage. Bindgen
supports concrete Array1 and Array2 signatures. A typed float64 Array1 store can consume
an unboxed load and product. Other generated ranks and scalar operations are follow-up slices. No elapsed-time or speedup threshold has been specified.

# Current behavior

Source inspection on 2026-11-18 establishes the following implementation
baseline; it does not establish a timing baseline.

| Area | Current behavior | Consequence |
|---|---|---|
| Storage | `ArcBigarray` points to an ARC-owned `ArcBigarrayBuffer` with PAL-allocated or imported contiguous storage. | Numeric elements have no individual ARC headers or counts. |
| Views | `ba_view` retains the backing and adjusts the data pointer; sub, slice, reshape, and layout changes use shared storage. | A view can outlive its original wrapper without copying the payload. View creation still allocates a descriptor. |
| Scalar reads | `ba_read` boxes floats, `int32`, `int64`, native integers, and complex results; immediate integer kinds remain tagged values. | A typed float64 Array1 load feeding a specialized store uses a double-returning helper. |
| Scalar arithmetic | A multiply feeding a concrete float64 Array1 store uses QBE double operands and result. | Ordinary OCaml calls and escaping results use the boxed value ABI. |
| Primitive lowering | Bigarray reads and writes carry operation, rank, element kind, layout and bounds-check mode through ANF and ARC. | QBE code generation can inspect each access before choosing its runtime helper. |
| C bindings | Bindgen maps direct, fully typed Array1 and Array2 parameters and results to retained C view handles. | Subviews preserve aliasing across the call and can outlive the input handle. |
| Release | Last backing-owner release frees PAL storage or schedules the imported owner’s callback on the releasing thread. | Stable addresses and predictable ownership do not guarantee bounded release time. |

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
| Pass an owned view back into OCaml | The generated shim checks the runtime, declared rank, kind and layout before acquiring an argument reference for the callee. The caller retains its own reference. |

The runtime test exports a subview at a nonzero offset, observes a C write
through a sibling, then drops all OCaml strong owners and collects. The last C
owner still has valid data and dimensions. Releasing it clears the weak slot
for the exported wrapper and restores the starting live-object count.[^tests]

On 2026-11-18 the runtime fixture passed on ARM64 macOS (native and
ASan/UBSan), ARM64 Linux in a local VM, and AMD64 Linux under emulation.
The AMD64 macOS fixture cross-linked on the ARM64 host, which could not
execute x86_64 macOS binaries. A C++17 consumer compiled and linked
against the installed header on ARM64 macOS.

## Generated Array1 and Array2 bindings

A C-layout `Array2.slice_left matrix i` fixes the zero-based row index
and returns an owned `Array1` over the same storage. A C caller can release
the matrix immediately and read or write the row until it releases the row
handle. An out-of-bounds index reports an OCaml exception through
`ocamlcc_error_t` and leaves the caller’s matrix usable.[^c-host]

With the compatibility stdlib, `ocamlcc build --shared --emit-header` emits
a self-contained header. For a module named `Vectors`, inspect a returned
handle with `ocamlcc_Vectors_view_info`, retain it with
`ocamlcc_Vectors_view_retain`, and release it with
`ocamlcc_Vectors_view_release`. The same helpers work when the library
also exports C stubs. Keep the producing library loaded while using its views.

Each independently linked runtime has its own ARC heap. A typed shim
checks the origin of each argument along with its rank, kind and layout
before marshalling. Modules linked to the same runtime can exchange a view.
Passing one between independent heaps reports an error and preserves the
caller’s owner.[^bindgen]

The two-library C fixture passed on ARM64 Linux and ARM64 macOS, including
an ASan/UBSan run on macOS. It passes a C-created view into OCaml, checks
that writes through a returned subview reach the parent, and reads the
subview after releasing the parent. A C++17 host on macOS also retained
and released a view using the generated and installed headers together.[^c-host]

## Foreign storage imported into OCaml

Use `ocamlcc_bigarray_view_import(&buffer, release, context)` with the
linked runtime. From a generated shared-library header, use the producing
module’s helper, for example `ocamlcc_Vectors_view_import`. Both return one
owned view on success. The caller transfers a mutable contiguous allocation
or an owned reference to a native buffer. Its release callback receives the
original base pointer and the supplied context, including when a subview at
a nonzero offset is the last owner.[^view-api][^bindgen]

Set `OcamlccBigarrayInfo.byte_length` to the available capacity and supply
a non-null, element-aligned data pointer, including for an empty view.
Dimensions are copied in Bigarray axis order. Ranks 0 through 16 and both
layouts are supported. Rank zero describes one element. Each dimension must
fit a nonnegative OCaml int, and the byte count must fit the capacity.
The returned descriptor reports the logical bytes used by the shape.
Invalid input returns `NULL`, preserves the caller’s ownership and exception
state, and leaves the callback uncalled.[^bigarray][^tests]

Keep the callback, its context and any library providing them alive until
delivery. The thread dropping the last backing owner runs the callback once,
after the outer ARC traversal finishes and the thread has left the cycle
collection lock and FFI mutator gate. This also applies when a collected cycle
held the last view. A callback may reenter generated bindings and collect.
It must return normally. Thread-affine owners can dispatch their native
release to the required thread.[^runtime][^c-host]

OCaml can store a view in a closure or a global, so imported storage must
stay writable and live beyond the call. To share a reference-counted native
buffer, transfer one retained reference as the context and drop it in the
callback. Copy read-only or call-scoped data into owned writable storage.

The C host on ARM64 Linux and macOS imported a matrix, dropped both C
handles, and wrote into the original allocation through a row saved by
OCaml. A second case collected the last view in a cycle and started another
collection from its release callback. The native descriptor tests also
passed under ASan/UBSan on macOS and on emulated AMD64 Linux.[^c-host][^tests]

# Unboxed scalar processing

For a float64 Array1 store with known C or Fortran layout, the compiler
propagates the demand for a double into its value expression. Direct float64
Array1 reads return doubles and multiplication produces a QBE double.
Other operands cross the ordinary OCaml value ABI and are unboxed at use.
The compiler also follows named `let` bindings backwards within a
straight-line chain. A load or multiply stays unboxed when all of its uses
feed scalar operations in that chain. A binding with a boxed use, such as
returning it or capturing it in a closure, keeps one shared OCaml value.
An inline `if` feeding the scalar expression selects a branch result through
a QBE double phi. Only the selected branch runs. If a branch returns a boxed
float from a call, the compiler loads the double before releasing the box.
The conditional loop measured 3 ARC words for 128 elements and for zero
iterations. A conditional assigned to a named binding still uses the boxed
join path.
Raw temporaries stay out of ARC cleanup and the fiber shadow stack.
The backing owners follow ordinary ARC liveness.[^lowering][^codegen]

The read and write helpers share the runtime’s rank, layout and bounds
checks. The regression exercises overlapping views, partial writes on a
short destination, Fortran indexing, NaN, signed zero and a callback that
mutates the source and collects between the load and multiply. A separate
case checks that the returned product and the closure capture share the
same box.[^bigarray][^tests]

Using `Gc.minor_words ()` around the loop on ARM64 macOS, the same test
measured 771 ARC words before specialization and 3 afterward for 128
elements. Both the direct expression and the loop with named `cell` and
`product` bindings reproduced this change in their respective revisions.
The zero-iteration control measured 3 words in each build.
The first counter read allocates its own three-word result. The views and
factor are already allocated at entry. The ARM64 Linux fixture also measured
3 words for both sizes, and the generated scale function produced the
expected values on emulated AMD64 Linux. These counts cover allocation
during the loop and measurement, with no elapsed-time measurement.[^c-host]

Kind and layout remain independent in ANF. A float32 Array3 read can retain
its kind even when its layout is polymorphic. The lowering test inspects both
the frontend-to-ANF and post-ARC metadata.[^lowering-test]

Start with float64 and immediate-integer loops, then extend to float32 and
boxed-integer kinds. Keep complex and other unsupported specialized cases on
the correct generic path until implemented; report coverage by kind instead
of claiming all Bigarray access is allocation-free.

The compiler specializes the load, multiply, and store in this loop:

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
2. **Generated Bigarray bindings (Array1 and Array2 implemented).** Concrete element, kind
   and layout types are required. Type aliases resolve through compiler-libs.
   A function or module value returns one owned C handle. Null inputs, metadata
   mismatches and OCaml exceptions use the existing `ocamlcc_error_t` convention.
   The shared-library fixture releases its parent and reads the returned slice,
   then verifies the original live-object count. Nested view types, Array3
   and Genarray remain unsupported.[^bindgen]
3. **Foreign backing ownership (implemented).** The runtime and generated
   headers accept caller-owned mutable storage with a release callback. Tests
   cover rejected transfers, escaping rows and cycle-owned views.
4. **Typed scalar lowering (float64 Array1 scale implemented).** Direct
   expressions and straight-line local bindings use the scalar path. Further
   work covers additional operations, named conditional results, and other kinds.
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
[^lowering]: `Pbigarrayref`/`Pbigarrayset` lowering in `lib/anf.ml` preserves kind, layout, rank and access mode in generic and specialized access nodes.
[^lowering-test]: `test/bigarray_lowering_test.ml` checks typed and polymorphic source programs through `Arc_pass.run`.
[^codegen]: `lib/codegen_expr.ml` emits QBE double operands and helper calls for specialized float64 stores and the boxed value ABI for general operations.
[^bindgen]: `lib/c_bindgen.ml` defines the supported C types, opaque ownership helpers, and generated exception/mutator handling.
[^tests]: `tests/stdlib_runtime.c` and `tests/stdlib/bigarray/main.ml` exercise existing shared-backing lifetime and source-level behavior.
[^c-host]: `tests/bigarray_bindgen/run.sh` builds the two libraries and runs the ownership and scale-allocation assertions in `host.c`.
