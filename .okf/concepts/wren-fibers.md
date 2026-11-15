---
type: Concept
title: Wren-style stackful fibers
description: Cooperative concurrency — shadow-stack fibers with static yield-effect inference, kqueue/epoll I/O polling, and deterministic ARC cleanup (Phase 3).
tags: [fibers, concurrency, runtime, phase-3]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-15
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: rt-fiber
    resource: ../runtime/fiber.c
    title: Wren-style fiber runtime and scheduler
  - id: rt-pal-ctx
    resource: ../runtime/pal_ctx.S
    title: Assembly context switch for arm64 and x86_64
  - id: rt-pal
    resource: ../runtime/pal.c
    title: POSIX PAL and kqueue/epoll event poller
  - id: lib-arc-pass
    resource: ../lib/arc_pass.ml
    title: Yield-effect inference and ShadowPush/ShadowPop pass
---

# Design

Phase 3 implements Wren-style stackful coroutines (§4.4 of the design doc)[^design-doc]:

- Each fiber (`ARC_TAG_FIBER = 250`) is an ARC-managed heap object owning a contiguous **shadow value stack** holding live heap pointers and reuse tokens across suspension points, a `64 KB` stack + callee-saved register `PalCtx`, a per-fiber `ocamlcc_exn_slot`, and a caller link for asymmetric yield and cooperative scheduling.
- **Static yield-effect inference** (`compute_yield_info` in `lib/arc_pass.ml`) computes the fixed point of functions that can transitively yield or spawn/await; only those calls are bracketed by `ShadowPush`/`ShadowPop`, keeping leaf and pure functions at full register speed (design doc §7 mitigation).
- **Deterministic cleanup** — when a suspended or abandoned fiber's refcount hits zero, `fiber_destroy` in `runtime/fiber.c` walks its shadow-stack slots and releases each live value and open reuse token before freeing the C stack and shadow buffer.
- **Event poller** — non-blocking I/O suspends the active fiber and parks file descriptors or millisecond timers with `pal_poll_wait` (backed by `kqueue` on Darwin/BSD and `epoll` on Linux in `runtime/pal.c`).

No OCaml 5 multicore domains and no multi-shot effects: one cooperative scheduler, explicit single-shot coroutines (`Stdlib.Fiber`, design doc §2 non-goals).

# Status

Implemented and verified across `fiber_test` and `fiber_io` (`runtime/pal_ctx.S` for Darwin/Linux `arm64` and `x86_64`, `runtime/pal.c` `kqueue`/`epoll`, `runtime/fiber.c`, `stdlib/stdlib__fiber.ml`, and `ShadowPush`/`ShadowPop` lowering in `lib/arc_pass.ml` and `lib/codegen.ml`) with zero ARC leaks.
