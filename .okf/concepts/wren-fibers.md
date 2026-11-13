---
type: Concept
title: Wren-style stackful fibers
description: Planned cooperative concurrency — shadow-stack fibers with deterministic ARC cleanup — Phase 3.
tags: [fibers, concurrency, planned, phase-3]
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

Phase 3 adds Wren-style stackful coroutines (§4.4 of the design doc)[^design-doc]:

- Each fiber is an ARC-managed heap object owning a contiguous **shadow
  value stack** holding live heap pointers across suspension points, plus a
  caller link for asymmetric yield and symmetric transfer.
- **Static yield-effect inference** decides which functions can transitively
  suspend; only those emit shadow-stack spills, keeping leaf/pure functions
  at full register speed (design doc §7 mitigation).
- **Deterministic cleanup** — when a suspended fiber's refcount hits zero,
  its destructor walks shadow-stack slots from `sp` to `base` and drops each
  live reference before freeing the stack buffer. `runtime/fiber.c` already
  implements this walk.
- **Event poller** — non-blocking I/O suspends the active fiber and parks
  descriptors/timers with the platform primitives behind
  [pal_poll_wait](/concepts/platform-abstraction-layer.md) (kqueue on
  macOS/iOS, epoll on Linux/Android).

No OCaml 5 multicore domains and no multi-shot effects: one cooperative
scheduler, explicit channels (design doc §2 non-goals).

# Status

Bootstrap only: the `Fiber` struct and the deterministic shadow-stack drop
walk exist; context switching and the scheduler do not.
