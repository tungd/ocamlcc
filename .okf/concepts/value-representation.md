---
type: Concept
title: Value representation
description: Tagged 63-bit immediates vs. heap ARC objects, and the tagged-arithmetic codegen tricks.
tags: [value-representation, codegen, arc]
status: stable
generated:
  by: codex/1
  at: 2026-11-23
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: lib-codegen
    resource: ../lib/codegen.ml
    title: Lambda-to-QBE code generator
  - id: runtime-arc
    resource: ../runtime/arc.c
    title: ARC runtime and string length metadata
  - id: runtime-builtins
    resource: ../runtime/builtins.c
    title: Runtime I/O builtins
---

# Design

The least-significant bit discriminates values (§4.2 of the design doc)[^design-doc]:

- `val land 1 = 1` — immediate: unboxed 63-bit integer, bool, constant
  constructor. Tagged form of integer `n` is `2n + 1`.
- `val land 1 = 0` — pointer to a heap-allocated
  [ARC object](/concepts/perceus-arc.md).

This is a deliberate break from OCaml's tagged-pointer scheme: no boxing
overhead across the C ABI, which is what makes the planned Swift/Kotlin
header generation clean.

## Tagged immediate binders

ANF preserves the frontend's value kinds on let bindings, mutable slots,
static-catch parameters, and function returns. A tuple projection into a
`Pintval` binding skips the field retain even when Lambda lowered it as a
pointer projection. ARC treats `Pintval` slots and handler parameters as
unmanaged and carries the return fact to saturated local and imported calls.
Promoted local refs whose initializer is immediate can still contain a heap
value after a pointer store. The promotion leaves those slots eligible for
ordinary ARC inference.

# Codegen arithmetic

The QBE code generator uses the tagging invariant to minimize instructions:

| Operation | Lowering |
|-----------|----------|
| `x + y` | `a + b - 1` (two ops: tagged sums satisfy `tag(x)+tag(y)-1 = tag(x+y)`) |
| `x - y` | `a - b + 1` |
| `x + k`, `x - k` for constant `k` | One add or subtract of `2k` |
| `k - x` for constant `k` | One subtract from `2k + 2` |
| `x * y` | untag both (`sar 1`), multiply, retag (`shl 1`, `+ 1`) |
| `x / y` | untag both, signed `div` (QBE truncates toward zero like OCaml), retag |
| `x = y` … comparisons | compare tagged values directly — `2x+1` is monotone, so signed order is preserved |
| `not x` (boolean negation) | `4 - a` (`false = 1`, `true = 3`) |
| `-x` (`Pnegint`) | `2 - a` |

Constant adjustments use 64-bit wrapping arithmetic, which preserves OCaml's
63-bit wraparound after tagging.

A comparison produces a raw QBE `0/1`. Conditional branches can use it
directly, including across intervening calls. A tagged boolean uses
`2r + 1` and stays available for returns, stores, and other value uses.
QBE codegen removes the retagging instructions when the branch was their
only consumer.

Untag is an arithmetic shift right (`sar`), correct for negatives: for
tagged `-1` (bit pattern `-1`), `sar 1` still yields `-1`.

# Boxed floats, float arrays, and boxed integers

Polymorphically passed `float`, `float array` / all-float records, `int32`,
`int64`, and `nativeint` values use 16-byte-aligned heap or immortal static
ARC objects (`val land 1 = 0`) with unscanned payloads (`scan_fields = 0`):

| Type | `ArcHeader.tag` | `reserved` | Payload |
|------|-----------------|------------|---------|
| `float` | `ARC_TAG_FLOAT (253)` | `0` | unboxed 64-bit IEEE 754 `double` |
| `float array` / float record | `ARC_TAG_FLOAT_ARRAY (254)` | `0` | unboxed `double[len]` (`byte_size = 8 * len`) |
| `int32` | `ARC_TAG_CUSTOM (255)` | `ARC_CUSTOM_INT32 (0)` | sign-extended 32-bit value |
| `int64` | `ARC_TAG_CUSTOM (255)` | `ARC_CUSTOM_INT64 (1)` | 64-bit signed integer |
| `nativeint` | `ARC_TAG_CUSTOM (255)` | `ARC_CUSTOM_NATIVEINT (2)` | 64-bit native signed integer |

Both `ARC_TAG_ARRAY` and `ARC_TAG_FLOAT_ARRAY` store `byte_size = 8 * len`, so
`Array.length` reads `byte_size >> 3` uniformly. Polymorphic `Pgenarray`
primitives dispatch at runtime on `hdr->tag` (`arc_alloc_array`,
`ocamlcc_gen_makearray`, `ocamlcc_gen_array_get`, `ocamlcc_gen_array_set`).
Structural comparison (`val_compare_raw`) and `caml_hash` handle all three tags,
normalizing `-0.0` to `+0.0` and canonicalizing `NaN` in `caml_hash` while
preserving OCaml semantics (`nan = nan` is `false` under `(=)`, `compare nan x`
is `-1`, `compare nan nan = 0`).

# Strings and output

String payloads are byte sequences, not C strings: `ArcHeader.reserved` stores
the payload length, so embedded NUL bytes are ordinary content. The compiler
passes that length to the C `print_string`/`print_endline` builtins, which write
exactly that many bytes; the ARC wrappers do the same for `print_char`, including
`'\000'`. String output therefore preserves embedded NULs instead of stopping
at the first one.

[^design-doc]: The tagging scheme and header layout are specified in
  `docs/design.md` §4.2.

# Function comparison

Structural predicates raise Invalid_argument when they reach a functional value, including two references to the same closure. Physical equality is available through (==).

# NaN in structural comparisons

Polymorphic predicates propagate unordered floating-point comparisons through lists, records and arrays. Stdlib.compare supplies the total ordering that places NaN before numbers.

## Local numeric values

ANF keeps typed flat-float array reads, writes, and arithmetic in double
temporaries. Float comparisons and conversions can use those temporaries
directly. Local boxed-integer arithmetic similarly carries the native word
width through arithmetic, shifts, and conversions. A chain boxes its result
where an ordinary OCaml value is required. Checked array operations preserve
bounds exceptions, and boxed-integer division preserves zero-divisor and
signed overflow behavior.

## Checked byte stores

Selected Stdlib `Bytes` word setters with the native byte order lower to
checked stores. The compiler resolves the exact standard-library binding and
honors explicit no-inline calls. A 32-bit or 64-bit scalar used only by a
store can remain unboxed through conversion and the write. A use that needs
an OCaml value keeps the ordinary box. The store checks the complete byte
range before writing, including at unaligned offsets.

On macOS ARM64, two paired eight-second runs of the same 8,388,705-byte
tterm replay measured 15.53 to 18.60 MiB/s on single-thread ARC.
Average apply time per iteration fell from 409.16 to 327.42 ms and
allocation from 605.42 to 473.09 MB. A separate million-store probe
reported 3,000,026 words before the change and 26 after, including
measurement overhead.

## Checked byte loads

The selected Stdlib `Bytes.get_int32_ne` and `Bytes.get_int64_ne` bindings
lower to checked word loads, as do the `_le` bindings on little-endian
targets. Explicit no-inline calls still use the Stdlib entry point.
Scalar consumers such as `Int32.to_int` and `Int64.to_int` can read the
native word directly. Uses that need an OCaml value receive a box.
The bounds check covers all bytes of the unaligned word. Conversion to
`int` preserves signed 32-bit extension and 63-bit truncation of 64-bit words.

On macOS ARM64 a probe reading one million pairs of checked words reported
6,000,017 allocated words before and 17 after, including measurement overhead.
Two paired runs against the same tterm production replay snapshot measured
36.13 to 37.89 MiB/s and 147.62 to 135.20 MB of allocation per replay.

## Mutable numeric slots

Local refs promoted to `MutLet` can use raw QBE stack storage for floats,
int32, int64, and nativeint. The initializer and all writes must produce
private values of the same representation. Reads can feed scalar operations
or produce a boxed result on scope exit. A zero-write exit from a literal
initializer still returns a static constant. Slots that observe a boxed value
inside the scope, capture it, or receive an externally owned box keep ordinary
boxing and ownership. Raw slots stay out of ARC and fiber shadow roots.

## Numeric self-tail loops

A function with direct self-tail calls can carry typed numeric inputs through
the loop header as QBE doubles, words, or longs. It unboxes the incoming
arguments at the ordinary boxed entry. A fresh scalar result moves over the
backedge directly. A separate ownership value preserves the original box
when the input is forwarded or returned, including zero-iteration calls.
A loop that needs a selected input as a boxed value, or whose self calls
leave the tail position, uses ordinary boxed calls. Loop returns keep the
ordinary OCaml ABI and numeric checks preserve their exception paths.

Float-only record fields pass raw doubles through a load, arithmetic, and
store. A fresh float result consumed only by an adjacent boxed field store
can update the old box when it is uniquely owned, mortal, and unmarked by
weak references. Otherwise the runtime allocates a distinct box and releases
the displaced field. A result that escapes still materializes an ordinary box.
