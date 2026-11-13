---
type: Concept
title: Perceus ARC
description: Planned compile-time automatic reference counting with in-place constructor reuse — Phase 2.
tags: [arc, memory, planned, phase-2]
status: draft
generated:
  by: autoagent/1
  at: 2026-11-13
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
---

# Design

Phase 2 replaces the tracing GC with Perceus-style reference counting
(§4.2 of the design doc)[^design-doc]. Objects carry a 16-byte header
(`runtime/arc.h`): non-atomic refcount (`0xFFFFFFFF` = immortal/static),
constructor tag, `scan_fields` count, and `byte_size` for slab reuse.

Key pieces:

- **Static dup/drop insertion** — during ANF lowering, liveness analysis
  inserts `arc_dup` on shared variables and `arc_drop` after last use.
- **In-place reuse** — when a dropped constructor's size matches the next
  allocation, the compiler emits a reuse token that mutates the dead block
  instead of allocating.
- **Slab allocator** — freestanding C allocator over
  [PAL](/concepts/platform-abstraction-layer.md) page hooks.
- **Cycle safety** — mutable structures are statically flagged; cycles break
  via `Weak.t` or an opt-in trial-deletion collector (design doc §7).
- **Zero-leak exceptions** — `raise`/`try...with` lower to an error-return
  channel, so exceptional paths still run the normal epilogue drops (§4.3).

# Status

Bootstrap only: `runtime/arc.c` implements `arc_alloc` / `arc_retain` /
`arc_release` over the header with `malloc`. No compiler-side ARC pass
exists yet; generated code leaks by design in Phase 1.
