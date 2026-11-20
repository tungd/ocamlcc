/*
 * fiber.h — Wren-style stackful coroutine context & shadow stack
 * (scheduler, timers, and I/O waiters live in stdlib/stdlib__fiber.ml).
 *
 * Each Fiber is an ARC-managed heap object (ARC_TAG_FIBER) owning a C
 * execution stack and a shadow value stack for live ARC references across
 * suspension points. Dropping an abandoned suspended fiber cleanly releases
 * all shadowed references from sp down to base before freeing the stacks.
 */
#ifndef OCAMLCC_FIBER_H
#define OCAMLCC_FIBER_H

#include "pal.h"

#include <stddef.h>
#include <stdint.h>

typedef enum FiberState {
    FIBER_SUSPENDED,
    FIBER_RUNNING,
    FIBER_DONE
} FiberState;

typedef struct Fiber {
    PalContext    ctx;
    uint8_t      *c_stack;       /* NULL for root main-thread fiber */
    size_t        c_stack_bytes;
    uint64_t     *shadow_base;   /* pal_page_alloc buffer */
    uint64_t     *shadow_sp;     /* live slots: [shadow_base, shadow_sp) */
    uint64_t     *shadow_end;
    void        **reuse_base;    /* pal_page_alloc buffer for open reuse tokens */
    void        **reuse_sp;
    void        **reuse_end;
    struct Fiber *caller;        /* link back to resuming fiber */
    int64_t       entry_closure; /* owned closure while executing */
    int64_t       result;        /* owned return / yield / resume payload */
    int64_t       exn_slot;      /* saved per-fiber ocamlcc_exn_slot */
    int64_t       pending_exn;   /* owned uncaught exception on FIBER_DONE */
    int           owns_finalizer_dispatch; /* set during an unreleased callback */
    FiberState    state;
} Fiber;

Fiber *arc_fiber_current(void);

/* Compiler shadow-stack ABI (calls inserted around yielding call sites). */
void arc_fiber_push(int64_t val);
void arc_fiber_pop(int64_t n);
void arc_fiber_push_reuse(void *tok);
void arc_fiber_pop_reuse(int64_t n);

/* Called by ARC release_subtree when ARC_TAG_FIBER refcount hits 0. */
void fiber_destroy(Fiber *fiber);

/* Low-level coroutine & TLS/poller hooks backed by C PAL. */
int64_t ocamlcc_fiber_create(int64_t closure);
int64_t ocamlcc_fiber_resume(int64_t fiber_val, int64_t send_val);
int64_t ocamlcc_fiber_suspend(int64_t send_val);
int64_t ocamlcc_fiber_is_done(int64_t fiber_val);

int64_t ocamlcc_fiber_is_main(int64_t unit);
int64_t ocamlcc_fiber_can_yield(int64_t unit);
int64_t ocamlcc_fiber_sched_get(int64_t unit);
int64_t ocamlcc_fiber_sched_set(int64_t opt_val);
int64_t ocamlcc_monotonic_ns(int64_t unit);
int64_t ocamlcc_poller_watch(int64_t fd_val, int64_t events_val, int64_t tok_val);
int64_t ocamlcc_poller_unwatch_waiter(int64_t fd_val, int64_t events_val, int64_t tok_val);
int64_t ocamlcc_poller_wait(int64_t out_arr_val, int64_t timeout_ms_val);

/* Non-blocking pipe / fd test primitives backed by PAL. */
int64_t ocamlcc_pipe(int64_t unit);
int64_t ocamlcc_fd_read(int64_t fd_val, int64_t bytes_val, int64_t off_val, int64_t len_val);
int64_t ocamlcc_fd_write(int64_t fd_val, int64_t bytes_val, int64_t off_val, int64_t len_val);
int64_t ocamlcc_fd_close(int64_t fd_val);

#endif /* OCAMLCC_FIBER_H */
