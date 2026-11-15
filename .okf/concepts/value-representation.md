---
type: Concept
title: Value representation
description: Tagged 63-bit immediates vs. heap ARC objects, and the tagged-arithmetic codegen tricks.
tags: [value-representation, codegen, arc]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-13
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: lib-codegen
    resource: ../lib/codegen.ml
    title: Lambda-to-QBE code generator
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

[^design-doc]: The tagging scheme and header layout are specified in
  `docs/design.md` §4.2.
