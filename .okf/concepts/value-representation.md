---
type: Concept
title: Value representation
description: Tagged 63-bit immediates vs. heap ARC objects, and the tagged-arithmetic codegen tricks.
tags: [value-representation, codegen, arc]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-16
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

# Codegen arithmetic

`lib/codegen.ml` exploits the tagging invariant to minimize instructions:

| Operation | Lowering |
|-----------|----------|
| `x + y` | `a + b - 1` (two ops: tagged sums satisfy `tag(x)+tag(y)-1 = tag(x+y)`) |
| `x - y` | `a - b + 1` |
| `x * y` | untag both (`sar 1`), multiply, retag (`shl 1`, `+ 1`) |
| `x / y` | untag both, signed `div` (QBE truncates toward zero like OCaml), retag |
| `x = y` … comparisons | compare tagged values directly — `2x+1` is monotone, so signed order is preserved |
| `not x` (boolean negation) | `4 - a` (`false = 1`, `true = 3`) |
| `-x` (`Pnegint`) | `2 - a` |

**Booleans as values**: a comparison produces the raw QBE `0/1`. In
condition position (`jnz`) that raw result is used directly; in value
position it is retagged (`2r + 1`), so tagged `false = 1`, `true = 3`. A
`let`-bound boolean used later as a condition is untagged with `sar 1`
before the branch.

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
