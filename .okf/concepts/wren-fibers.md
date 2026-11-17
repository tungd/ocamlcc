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

- Each fiber (`ARC_TAG_FIBER = 250`) is an ARC-managed heap object owning a contiguous **shadow value stack** holding live heap pointers and reuse tokens across suspension points, a `256 KB` stack + callee-saved register `PalContext`, a per-fiber saved `exn_slot` swapped into the thread-local `tls_exn_slot` on context switch, and a caller link for asymmetric yield and cooperative scheduling. `tls_main_fiber`, `tls_current_fiber`, and `tls_sched` are `_Thread_local` so each OS thread runs an independent cooperative scheduler, and `PAL_USE_EPOLL`'s `g_watches` registry is synchronized by `g_watch_lock`.
- **Static yield-effect inference** (`compute_yield_info` in `lib/arc_pass.ml`) computes the fixed point of functions that can transitively yield or spawn/await; only those calls are bracketed by `ShadowPush`/`ShadowPop`, keeping leaf and pure functions at full register speed (design doc §7 mitigation).
- **Deterministic cleanup** — when a suspended or abandoned fiber's refcount hits zero, `fiber_destroy` in `runtime/fiber.c` walks its shadow-stack slots and releases each live value and open reuse token before freeing the C stack and shadow buffer.
- **Event poller** — non-blocking I/O suspends the active fiber and parks file descriptors or millisecond timers with `pal_poll_wait` (backed by `kqueue` on Darwin/BSD and `epoll` on Linux in `runtime/pal.c`). The epoll path keeps a per-poller, per-fd watch registry (`PalWatch` in `runtime/pal.c`): epoll keys registrations by fd alone, so two fibers watching the same fd (one READ, one WRITE) share one `EPOLLONESHOT` registration with both interest bits and per-direction udata — a plain `EPOLL_CTL_MOD` overwrite silently lost the first fiber's wakeup. `pal_poller_watch` also reports failures (`epoll_ctl` errors were swallowed as success), and `pal_poller_wait` re-arms a surviving interest after a one-shot fire or deregisters the fd when both watchers are done. **Verified by shim syntax-check only** (`cc -fsyntax-only -DPAL_USE_EPOLL` with a stub `sys/epoll.h`); this host runs kqueue and cannot execute the epoll path.

## Scheduling-mode guards

The two fiber kinds have disjoint operation sets, and crossing them corrupted the runtime (leaked stranded fibers, use-after-free of queued coroutines):

- **Coroutines** (`Fiber.create` / `resume` / `suspend`): `Fiber.suspend` transfers to the resumer.
- **Scheduler fibers** (`Fiber.spawn` / `yield` / `sleep_ms` / `fd_wait_*` / `await` / `run_all`): scheduler-queued, `+1` retained by the queue.

Cross-calls now raise `Invalid_argument` (`ocamlcc_fiber_raise_invalid` in `runtime/arc.c`, checked by the `CheckExn` emitted because these Ccalls are registered `raises = true` in the [C-call ABI registry](/concepts/perceus-arc.md)): `Fiber.suspend` inside a spawned fiber (it would strand the fiber off every scheduler queue, leaking it and its payload), `Fiber.yield`/`sleep_ms`/`fd_wait_*` inside a coroutine (they would queue the coroutine without scheduler ownership and return the resume payload to the resumer), and `Fiber.await` across modes in either direction (waiter handoff routes through the scheduler ready queue, which is only sound between scheduler fibers; awaiting a live coroutine from main can never complete). Regression probes in `examples/fiber_test.ml` (`cross=1,1,1,1,1`, all `delta=0`).

No OCaml 5 multicore domains and no multi-shot effects: one cooperative scheduler, explicit single-shot coroutines (`Stdlib.Fiber`, design doc §2 non-goals).

# Status

Implemented and verified across `fiber_test` and `fiber_io` (`runtime/pal_ctx.S` for Darwin/Linux `arm64` and `x86_64`, `runtime/pal.c` `kqueue`/`epoll`, `runtime/fiber.c`, `stdlib/stdlib__fiber.ml`, and `ShadowPush`/`ShadowPop` lowering in `lib/arc_pass.ml` and `lib/codegen.ml`) with zero ARC leaks.
