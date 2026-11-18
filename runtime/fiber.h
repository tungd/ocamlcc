/*
 * fiber.h — Wren-style stackful coroutines and cooperative I/O scheduler
 * (design doc §4.4).
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
    FIBER_RUNNABLE,
    FIBER_RUNNING,
    FIBER_WAITING_IO,
    FIBER_WAITING_TIMER,
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
    struct Fiber *caller;        /* link back to resuming / scheduler fiber */
    int64_t       entry_closure; /* owned closure while executing */
    int64_t       result;        /* owned return / yield / resume payload */
    int64_t       exn_slot;      /* saved per-fiber ocamlcc_exn_slot */
    int64_t       pending_exn;   /* owned uncaught exception on FIBER_DONE */
    uint64_t      wake_ns;       /* monotonic wake time for timer wait */
    int           wait_fd;       /* fd awaited or -1 */
    uint32_t      wait_events;   /* PAL_POLL_READ / PAL_POLL_WRITE */
    int           is_scheduled;  /* 1 = spawn/scheduler fiber, 0 = coroutine */
    struct Fiber *waiter_head;   /* queued fibers in Fiber.await */
    struct Fiber *sched_next;    /* scheduler ready / timer / io queue link */
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

/* OCaml Wren-style coroutine & cooperative scheduler externals. */
int64_t ocamlcc_fiber_create(int64_t closure);
int64_t ocamlcc_fiber_resume(int64_t fiber_val, int64_t send_val);
int64_t ocamlcc_fiber_suspend(int64_t send_val);
int64_t ocamlcc_fiber_is_done(int64_t fiber_val);

int64_t ocamlcc_fiber_spawn(int64_t closure);
int64_t ocamlcc_fiber_yield(int64_t unit);
int64_t ocamlcc_fiber_sleep_ms(int64_t ms_val);
int64_t ocamlcc_fiber_fd_wait_read(int64_t fd_val);
int64_t ocamlcc_fiber_fd_wait_write(int64_t fd_val);
int64_t ocamlcc_fiber_await(int64_t fiber_val);
int64_t ocamlcc_fiber_run_all(int64_t unit);

/* Non-blocking pipe / fd test primitives backed by PAL. */
int64_t ocamlcc_pipe(int64_t unit);
int64_t ocamlcc_fd_read(int64_t fd_val, int64_t bytes_val, int64_t off_val, int64_t len_val);
int64_t ocamlcc_fd_write(int64_t fd_val, int64_t bytes_val, int64_t off_val, int64_t len_val);
int64_t ocamlcc_fd_close(int64_t fd_val);

#endif /* OCAMLCC_FIBER_H */