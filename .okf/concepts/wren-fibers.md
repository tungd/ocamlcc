---
type: Concept
title: Wren-style stackful fibers
description: Cooperative concurrency — shadow-stack fibers with static yield-effect inference, kqueue/epoll I/O polling, and deterministic ARC cleanup (Phase 3).
tags: [fibers, concurrency, runtime, phase-3]
status: stable
generated:
  by: codex/1
  at: 2026-11-23
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
  - id: stdlib-fiber
    resource: ../stdlib/stdlib__fiber.ml
    title: OCaml cooperative fiber scheduler, timers, and I/O waiter queue
  - id: lib-arc-pass
    resource: ../lib/arc_pass.ml
    title: Yield-effect inference and ShadowPush/ShadowPop pass
---

# Design

Phase 3 implements Wren-style stackful coroutines (§4.4 of the design doc)[^design-doc], split between a small C coroutine/TLS/poller kernel (`runtime/fiber.c`) and the OCaml cooperative scheduler (`stdlib/stdlib__fiber.ml`)[^stdlib-fiber]:

- Each coroutine fiber (`ARC_TAG_FIBER = 250`) is an ARC-managed heap object owning a contiguous **shadow value stack** holding live heap pointers across suspension points, a separate stack of open reuse tokens, a guard-paged `256 KB` C stack + callee-saved register `PalContext`, a per-fiber saved `exn_slot` swapped into the thread-local `tls_exn_slot` on context switch, and a caller link (`caller`). `FiberThreadState` (`tls_state`) and `tls_current_fiber` are `_Thread_local` so each OS thread holds its own `main_fiber`, `poller_fd`, and OCaml `sched_val` handle (accessed via `ocamlcc_fiber_sched_get`/`set`).
- **OCaml scheduler** (`stdlib/stdlib__fiber.ml`) builds scheduled tasks (`Fiber.spawn`/`yield`/`sleep_ms`/`fd_wait_read`/`fd_wait_write`/`await`/`run_all`) as acyclic task records wrapping raw coroutines (`ocamlcc_fiber_create`/`resume`/`suspend`). It maintains per-thread FIFO ready queues, deadline timer lists, and I/O registrations over `ocamlcc_monotonic_ns` and the PAL poller. When the scheduler becomes completely idle on the main fiber, `release_if_idle` resets `sched_val` to `None` so steady-state `arc_live_objects` returns to zero.
- **Static yield-effect inference** (`Arc_analysis.Program_facts`) computes the fixed point of functions that can transitively yield or spawn/await (propagating transitively through `Stdlib__fiber` helpers calling `ocamlcc_fiber_suspend`/`resume`); only those calls are bracketed by `ShadowPush`/`ShadowPop`, keeping leaf and pure functions at full register speed (design doc §7 mitigation).
- **Shadow stacks are for stackful fibers.** QBE loads the runtime’s monotonic process flag before each group of generated shadow operations, including over-application. Until the first stackful fiber is created, the zero branch skips every push and pop call. Runtime helpers used by C callers also return before touching TLS. Main-stack frames keep their ownership in place, including across the first creation. Stackful frames still record live values and reuse tokens for abandonment cleanup. The native runtime test covers a main-stack scope that straddles first creation.
- **Deterministic cleanup** — when a suspended or abandoned coroutine's refcount hits zero, `fiber_destroy` in `runtime/fiber.c` walks its shadow-stack slots and releases each live value and open reuse token before freeing the C stack and shadow buffer; OCaml task waiter/timer/ready links are normal ARC-managed lists. **Thread-exit teardown** (`fiber_tls_cleanup`, the `pthread_key` destructor for `tls_state`): snapshots and clears `s->sched_val`, frees the main fiber's buffers, detaches `tls_state`/`tls_current_fiber` (`= NULL`), closes `s->poller_fd`, frees `s`, and only then releases `sched_val` — so a custom finalizer run during cleanup (or another `pthread_key` destructor running afterwards) gets fresh TLS safely instead of dereferencing freed memory. Pinned by `test_tls_cleanup_queued_fibers` in `tests/stdlib_runtime.c`.
- **Event poller** — descriptor waits use `kqueue` on Darwin/BSD and `epoll` on Linux. Both backends index the registry by poller and descriptor and reuse watch and waiter slots. Kernel events carry a slot generation so events from an earlier watch cannot wake a new waiter using that slot.

## Owned values and stack teardown

The fiber runtime describes its owning slots once for ordinary destruction
and trial deletion. The slots include shadow roots, the entry closure,
the resume or suspend payload, both saved exception values, and the effect
handlers. Each occupied slot is a separate edge, including handler slots
that share a closure.

Ordinary destruction releases shadow roots from the top of the stack and
clears each fixed slot before releasing its value. During trial deletion,
the fiber runtime tears down reuse tokens and buffers while the collector
records edges to surviving objects. The collector releases those outgoing
references after unlocking the cycle-root table and keeps foreign callbacks
deferred until the collection gate is released. The native runtime fixture
checks ordinary disposal and a cycle through a shared handler with a leaf
capture.

## Scheduling-mode guards

The two fiber kinds have disjoint operation sets:

- **Coroutines** (`Fiber.create` / `resume` / `suspend`): `Fiber.suspend` transfers to the resumer; `Fiber.resume` temporarily saves and clears `sched_state.active` so coroutines created inside spawned tasks can suspend cleanly without being confused for the enclosing spawned task.
- **Scheduler fibers** (`Fiber.spawn` / `yield` / `sleep_ms` / `fd_wait_*` / `await` / `run_all`): scheduler-queued tasks driving coroutines with `CmdDone`/`CmdYield`/`CmdSleep`/`CmdWaitFd`/`CmdPark` commands.

Cross-calls raise `Invalid_argument`: `Fiber.suspend` inside a spawned fiber or on `main`, `Fiber.yield`/`sleep_ms`/`fd_wait_*`/`await` inside a coroutine, self-`Fiber.await`, and cyclic `Fiber.await` chains. Regression probes in `examples/fiber_test.ml` (`cross=1,1,1,1,1`, `edges=[FS] 3,45,1,1,1 delta=0`).

- **Finalizer dispatch owns the fiber**: `ocamlcc_poll_finalizers` is registered `yields = false`, and `run_finalizers` (`runtime/arc.c`) sets `owns_finalizer_dispatch` on the current fiber while a callback runs. Every suspension entry point checks `owns_finalizer_dispatch` via `ocamlcc_fiber_suspend` or `ocamlcc_fiber_can_yield` and raises `Invalid_argument` rather than stranding unshadowed dispatcher frames. Pinned by `test_finalizer_no_suspend` in `tests/stdlib_runtime.c` and `test_sched_edges` in `examples/fiber_test.ml`.

No OCaml 5 multicore domains and no multi-shot effects: one cooperative scheduler, explicit single-shot coroutines (`Stdlib.Fiber`, design doc §2 non-goals).

## Descriptor deadlines and cancellation

`Fiber.fd_wait` takes a `Fiber.Direction.t` and returns a
`Fiber.Wait_result.t` of `Ready`, `Timed_out`, or `Cancelled`. It uses
monotonic deadlines and a one-way `Fiber.Cancel.t` on the scheduler thread.
The scheduler checks cancellation before polling and delivers readiness
returned by the poll before expiring deadlines. A zero timeout polls once.
Expiry or cancellation unregisters only that waiter.

`Fiber.t` keeps the task's typed outcome in a completion cell. The
scheduler stores private, result-independent handles and wakes waiters
after a task completes. Descriptor waiters likewise resume with a private
completion cell that holds no reference back to the task.
`ninja -j1 test_fiber_wait` exercises typed task completion, deadline
expiry, zero-timeout readiness, and cancellation with a second waiter
still registered under both ARC profiles.

## Poller registration batches

The scheduler queues new descriptor waits and submits them when it polls.
It polls between rounds of ready tasks and after at most 64 task steps
within a round. On kqueue the pending filters and the blocking readiness
wait use one `kevent` call. If Darwin returns change errors ahead of
readiness, the runtime reports those failures and checks for ready events
with a zero timeout. A failed registration resumes only its waiter with
`Invalid_argument`. Linux applies the additions with `epoll_ctl` before
`epoll_wait`. The default ARC runtime synchronizes the shared watch
registry. The single-thread ARC archive compiles the registry without its
spinlock.

The PAL test combines a closed fd and two waiters on a ready pipe, then
checks that the same pipe remains independently registered on a second
poller. The Fiber test checks invalid-descriptor delivery and zero-timeout
waits across consecutive batches.

## In-memory condition waits

`Fiber.Condition.wait` parks on the calling scheduler thread. It shares
the monotonic deadline and cancellation rules of descriptor waits and
returns `Fiber.Wait_result.t`. Notification uses the ready queue directly.
An unbounded condition wait alone does not keep the poller active.

`signal` schedules the oldest noncancelled waiter on that condition.
`broadcast` schedules all its noncancelled waiters. Notifications sent
with no waiters are discarded. The scheduler retains parked waits when
`run_all` returns for lack of work, so the same thread can notify and
resume them later. An unbounded wait on the main fiber raises
`Invalid_argument` if nothing can drive it forward.

`ninja -j1 test_fiber_wait` covers signals, broadcasts, timeout,
cancellation, and isolation between condition waiters in both ARC profiles.

## Host event loops

`Fiber.step_ready` lets a host callback advance one queued task on the
main fiber. It returns whether it ran a task. It uses only the ready queue,
so a host can drain work without polling file descriptors or running an
idle timer. The regression checks queue order and confirms an available
descriptor stays pending until an ordinary scheduler call polls it.

## Main-fiber sleep

A main-fiber `sleep_ms` supplies its monotonic deadline to every scheduler
step. The scheduler combines it with the deadlines of sleeping tasks and
condition and descriptor waits. The poll returns when the main fiber's
sleep expires even if the watched descriptor stays quiet. The regression
covers a queued watch and an installed watch on a quiet pipe. In each
case it verifies that the requested interval elapses before cancelling
the watcher.

## OCaml 5 effect handlers

The stdlib compatibility build uses the existing guarded C stacks for
`Effect.Deep`, `Effect.Shallow`, and the OCaml effect-pattern syntax. A handler delimiter starts
one fiber. Its value, exception, and effect callbacks execute in the caller.
`perform` hands the effect to that caller, which receives a one-shot
continuation owning the suspended fiber. Resuming atomically takes that
ownership. Deep resumption keeps the fiber’s handler. Shallow resumption
installs the supplied handler and releases the replaced closures. Declining an effect forwards it through enclosing delimiters while
the inner continuation remains rooted on the forwarding stack.

`discontinue` resumes at the perform site with a raised exception so the
captured code can catch it and run cleanup. Dropping a continuation releases
the shadow roots and frees its stack. These are separate lifetime operations.
The cycle collector also visits the fiber's retained handler closures.

An effect fiber can forward a Wren suspension through its delimiters to the
enclosing Wren resumer. A Wren coroutine remains its own effect scope, and a
captured effect stack resumes on the OS thread that created it. The native
runtime regression covers resuming and dropping a Wren coroutine suspended
inside an effect delimiter.

# Status

Implemented and verified across `fiber_test` and `fiber_io` (`runtime/pal_ctx.S` for Darwin/Linux `arm64` and `x86_64`, `runtime/pal.c` `kqueue`/`epoll`, `runtime/fiber.c`, `stdlib/stdlib__fiber.ml`, and `ShadowPush`/`ShadowPop` lowering in `lib/arc_pass.ml` and `lib/codegen.ml`) with zero ARC leaks.
