/*
 * fiber.c — Wren-style stackful coroutines, shadow stack, and cooperative
 * kqueue/epoll scheduler (design doc §4.4).
 */
#include "fiber.h"

#include "arc.h"

#define FIBER_STACK_BYTES (256u * 1024u)
#define SHADOW_INIT_BYTES (16u * 1024u)

typedef struct SchedState {
    Fiber *ready_head;
    Fiber *ready_tail;
    Fiber *timer_head;
    Fiber *io_head;
    int    poller_fd;
    int    main_io_pending;
    int    main_io_ready;
} SchedState;

static _Thread_local Fiber tls_main_fiber = {
    .c_stack = NULL,
    .c_stack_bytes = 0,
    .shadow_base = NULL,
    .shadow_sp = NULL,
    .shadow_end = NULL,
    .caller = NULL,
    .entry_closure = 0,
    .result = 0,
    .exn_slot = 0,
    .pending_exn = 0,
    .wake_ns = 0,
    .wait_fd = -1,
    .wait_events = 0,
    .is_scheduled = 0,
    .waiter_head = NULL,
    .sched_next = NULL,
    .state = FIBER_RUNNING
};

static _Thread_local Fiber     *tls_current_fiber = NULL;
static _Thread_local SchedState tls_sched = { NULL, NULL, NULL, NULL, -1, 0, 0 };

static inline Fiber *current_fiber(void)
{
    if (tls_current_fiber == NULL)
        tls_current_fiber = &tls_main_fiber;
    return tls_current_fiber;
}

static inline int64_t tag_int(int64_t n)
{
    return (int64_t)(((uint64_t)n << 1) | 1ull);
}

static void shadow_init(Fiber *f)
{
    uint64_t *buf = (uint64_t *)pal_page_alloc(SHADOW_INIT_BYTES);
    if (buf == NULL)
        pal_abort();
    f->shadow_base = buf;
    f->shadow_sp = buf;
    f->shadow_end = buf + (SHADOW_INIT_BYTES / sizeof(uint64_t));
}

void arc_fiber_push(int64_t val)
{
    Fiber *cur = current_fiber();
    if (cur->shadow_base == NULL)
        shadow_init(cur);
    if (cur->shadow_sp == cur->shadow_end) {
        size_t old_slots = (size_t)(cur->shadow_end - cur->shadow_base);
        size_t old_bytes = old_slots * sizeof(uint64_t);
        size_t new_bytes = old_bytes * 2u;
        uint64_t *nb = (uint64_t *)pal_page_alloc(new_bytes);
        if (nb == NULL)
            pal_abort();
        pal_memcpy(nb, cur->shadow_base, old_bytes);
        pal_page_free(cur->shadow_base, old_bytes);
        cur->shadow_base = nb;
        cur->shadow_sp = nb + old_slots;
        cur->shadow_end = nb + (new_bytes / sizeof(uint64_t));
    }
    *cur->shadow_sp++ = (uint64_t)val;
}

void arc_fiber_pop(int64_t n)
{
    if (n <= 0)
        return;
    Fiber *cur = current_fiber();
    if (cur->shadow_base == NULL ||
        (size_t)(cur->shadow_sp - cur->shadow_base) < (size_t)n)
        pal_abort();
    cur->shadow_sp -= (size_t)n;
}

void arc_fiber_push_reuse(void *tok)
{
    Fiber *cur = current_fiber();
    if (cur->reuse_base == NULL) {
        void **buf = (void **)pal_page_alloc(SHADOW_INIT_BYTES);
        if (buf == NULL)
            pal_abort();
        cur->reuse_base = buf;
        cur->reuse_sp = buf;
        cur->reuse_end = buf + (SHADOW_INIT_BYTES / sizeof(void *));
    }
    if (cur->reuse_sp == cur->reuse_end) {
        size_t old_slots = (size_t)(cur->reuse_end - cur->reuse_base);
        size_t old_bytes = old_slots * sizeof(void *);
        size_t new_bytes = old_bytes * 2u;
        void **nb = (void **)pal_page_alloc(new_bytes);
        if (nb == NULL)
            pal_abort();
        pal_memcpy(nb, cur->reuse_base, old_bytes);
        pal_page_free(cur->reuse_base, old_bytes);
        cur->reuse_base = nb;
        cur->reuse_sp = nb + old_slots;
        cur->reuse_end = nb + (new_bytes / sizeof(void *));
    }
    *cur->reuse_sp++ = tok;
}

void arc_fiber_pop_reuse(int64_t n)
{
    if (n <= 0)
        return;
    Fiber *cur = current_fiber();
    if (cur->reuse_base == NULL ||
        (size_t)(cur->reuse_sp - cur->reuse_base) < (size_t)n)
        pal_abort();
    cur->reuse_sp -= (size_t)n;
}

void fiber_destroy(Fiber *f)
{
    if (f == NULL || f == &tls_main_fiber)
        return;
    if (f->reuse_base != NULL) {
        while (f->reuse_sp > f->reuse_base) {
            f->reuse_sp--;
            arc_free_reuse(*f->reuse_sp);
        }
        size_t rbytes = (size_t)(f->reuse_end - f->reuse_base) * sizeof(void *);
        pal_page_free(f->reuse_base, rbytes);
        f->reuse_base = NULL;
        f->reuse_sp = NULL;
        f->reuse_end = NULL;
    }
    if (f->shadow_base != NULL) {
        while (f->shadow_sp > f->shadow_base) {
            f->shadow_sp--;
            arc_release_val((int64_t)*f->shadow_sp);
        }
        size_t sbytes = (size_t)(f->shadow_end - f->shadow_base) * sizeof(uint64_t);
        pal_page_free(f->shadow_base, sbytes);
        f->shadow_base = NULL;
        f->shadow_sp = NULL;
        f->shadow_end = NULL;
    }
    if (f->entry_closure != 0) {
        int64_t clos = f->entry_closure;
        f->entry_closure = 0;
        arc_release_val(clos);
    }
    if (f->result != 0) {
        int64_t r = f->result;
        f->result = 0;
        arc_release_val(r);
    }
    if (f->exn_slot != 0) {
        int64_t ex = f->exn_slot;
        f->exn_slot = 0;
        arc_release_val(ex);
    }
    if (f->pending_exn != 0) {
        int64_t ex = f->pending_exn;
        f->pending_exn = 0;
        arc_release_val(ex);
    }
    if (f->c_stack != NULL) {
        pal_page_free(f->c_stack, f->c_stack_bytes);
        f->c_stack = NULL;
        f->c_stack_bytes = 0;
    }
    f->state = FIBER_DONE;
}

static void fiber_swap_to(Fiber *next)
{
    Fiber *prev = current_fiber();
    prev->exn_slot = ocamlcc_get_exn();
    ocamlcc_set_exn(next->exn_slot);
    tls_current_fiber = next;
    next->state = FIBER_RUNNING;
    pal_ctx_swap(&prev->ctx, &next->ctx);
}

static int ensure_poller(void)
{
    if (tls_sched.poller_fd < 0) {
        tls_sched.poller_fd = pal_poller_create();
        if (tls_sched.poller_fd < 0)
            pal_abort();
    }
    return tls_sched.poller_fd;
}

static void sched_push_ready(Fiber *f)
{
    f->state = FIBER_RUNNABLE;
    f->sched_next = NULL;
    if (tls_sched.ready_tail != NULL)
        tls_sched.ready_tail->sched_next = f;
    else
        tls_sched.ready_head = f;
    tls_sched.ready_tail = f;
}

static Fiber *sched_pop_ready(void)
{
    Fiber *f = tls_sched.ready_head;
    if (f == NULL)
        return NULL;
    tls_sched.ready_head = f->sched_next;
    if (tls_sched.ready_head == NULL)
        tls_sched.ready_tail = NULL;
    f->sched_next = NULL;
    return f;
}

static void sched_remove_io(Fiber *target)
{
    Fiber **pp = &tls_sched.io_head;
    while (*pp != NULL) {
        if (*pp == target) {
            *pp = target->sched_next;
            target->sched_next = NULL;
            target->wait_fd = -1;
            target->wait_events = 0;
            return;
        }
        pp = &(*pp)->sched_next;
    }
}

static void sched_drain_timers(void)
{
    uint64_t now = pal_monotonic_ns();
    Fiber **pp = &tls_sched.timer_head;
    while (*pp != NULL) {
        Fiber *f = *pp;
        if (f->wake_ns <= now) {
            *pp = f->sched_next;
            f->sched_next = NULL;
            sched_push_ready(f);
        } else {
            pp = &f->sched_next;
        }
    }
}

static int sched_next_timer_timeout_ms(void)
{
    if (tls_sched.timer_head == NULL)
        return -1;
    uint64_t earliest = tls_sched.timer_head->wake_ns;
    for (Fiber *f = tls_sched.timer_head->sched_next; f != NULL; f = f->sched_next) {
        if (f->wake_ns < earliest)
            earliest = f->wake_ns;
    }
    uint64_t now = pal_monotonic_ns();
    if (earliest <= now)
        return 0;
    uint64_t diff_ns = earliest - now;
    uint64_t ms = (diff_ns + 999999ull) / 1000000ull;
    if (ms > (uint64_t)INT32_MAX)
        return INT32_MAX;
    return (int)ms;
}

static void sched_poll(int timeout_ms)
{
    sched_drain_timers();
    if (tls_sched.io_head == NULL && !tls_sched.main_io_pending) {
        if (timeout_ms > 0) {
            int pfd = ensure_poller();
            PalPollEvent ev;
            (void)pal_poller_wait(pfd, &ev, 1, timeout_ms);
            sched_drain_timers();
        }
        return;
    }
    if (tls_sched.ready_head != NULL)
        timeout_ms = 0;
    int pfd = ensure_poller();
    PalPollEvent evs[32];
    int n = pal_poller_wait(pfd, evs, 32, timeout_ms);
    for (int i = 0; i < n; i++) {
        Fiber *wf = (Fiber *)evs[i].udata;
        if (wf == &tls_main_fiber) {
            tls_sched.main_io_pending = 0;
            tls_sched.main_io_ready = 1;
        } else if (wf != NULL && wf->state == FIBER_WAITING_IO) {
            sched_remove_io(wf);
            sched_push_ready(wf);
        }
    }
    sched_drain_timers();
}

static int sched_step(void)
{
    sched_poll(0);
    Fiber *next = sched_pop_ready();
    if (next != NULL) {
        next->caller = current_fiber();
        fiber_swap_to(next);
        if (next->state == FIBER_DONE)
            arc_release(next);
        return 1;
    }
    if (tls_sched.io_head != NULL || tls_sched.timer_head != NULL ||
        tls_sched.main_io_pending) {
        int tms = sched_next_timer_timeout_ms();
        sched_poll(tms);
        return 1;
    }
    return 0;
}

static void __attribute__((noreturn)) fiber_trampoline(void)
{
    Fiber *self = current_fiber();
    int64_t clos = self->entry_closure;
    int64_t arg = self->result;
    self->result = 0;

    int64_t res = ocamlcc_apply1(clos, arg);

    self->entry_closure = 0;
    arc_release_val(clos);

    int64_t cur_exn = ocamlcc_get_exn();
    if (cur_exn != 0) {
        self->pending_exn = cur_exn;
        ocamlcc_set_exn(0);
        self->result = 1;
    } else {
        self->result = res;
    }
    self->state = FIBER_DONE;

    while (self->waiter_head != NULL) {
        Fiber *w = self->waiter_head;
        self->waiter_head = w->sched_next;
        w->sched_next = NULL;
        sched_push_ready(w);
    }

    Fiber *caller = self->caller;
    self->caller = NULL;
    fiber_swap_to(caller);
    pal_abort();
}

static Fiber *alloc_fiber_obj(int64_t closure, int scheduled)
{
    uint8_t *cstack = (uint8_t *)pal_page_alloc(FIBER_STACK_BYTES);
    if (cstack == NULL)
        pal_abort();

    Fiber *f = (Fiber *)arc_alloc((uint16_t)ARC_TAG_FIBER, 0u, (uint32_t)sizeof(Fiber));
    pal_memset(f, 0, sizeof(*f));
    f->c_stack = cstack;
    f->c_stack_bytes = FIBER_STACK_BYTES;
    shadow_init(f);
    arc_retain_val(closure);
    f->entry_closure = closure;
    f->wait_fd = -1;
    f->is_scheduled = scheduled;
    f->state = scheduled ? FIBER_RUNNABLE : FIBER_SUSPENDED;
    pal_ctx_make(&f->ctx, cstack + FIBER_STACK_BYTES, fiber_trampoline);
    return f;
}

int64_t ocamlcc_fiber_create(int64_t closure)
{
    Fiber *f = alloc_fiber_obj(closure, 0);
    return (int64_t)(uintptr_t)f;
}

int64_t ocamlcc_fiber_resume(int64_t fiber_val, int64_t send_val)
{
    Fiber *f = (Fiber *)(uintptr_t)fiber_val;
    if (f == NULL || f->state != FIBER_SUSPENDED || f->caller != NULL)
        pal_abort();

    arc_retain(f);
    arc_retain_val(send_val);
    if (f->result != 0)
        arc_release_val(f->result);
    f->result = send_val;
    f->caller = current_fiber();

    fiber_swap_to(f);

    if (f->pending_exn != 0) {
        int64_t ex = f->pending_exn;
        f->pending_exn = 0;
        if (f->result != 0) {
            arc_release_val(f->result);
            f->result = 0;
        }
        arc_release(f);
        ocamlcc_set_exn(ex);
        return 1;
    }

    int64_t out = f->result;
    f->result = 0;
    arc_release(f);
    return out;
}

int64_t ocamlcc_fiber_suspend(int64_t send_val)
{
    Fiber *cur = current_fiber();
    if (cur == &tls_main_fiber || cur->is_scheduled) {
        /* Fiber.suspend is a coroutine operation; inside a spawned fiber it
           would strand the fiber off every scheduler queue (leaking it and
           its payload). */
        ocamlcc_fiber_raise_invalid();
        return 1;
    }
    if (cur->caller == NULL)
        pal_abort();

    arc_retain_val(send_val);
    if (cur->result != 0)
        arc_release_val(cur->result);
    cur->result = send_val;
    cur->state = FIBER_SUSPENDED;

    Fiber *target = cur->caller;
    cur->caller = NULL;
    fiber_swap_to(target);

    int64_t in = cur->result;
    cur->result = 0;
    return in;
}

int64_t ocamlcc_fiber_is_done(int64_t fiber_val)
{
    Fiber *f = (Fiber *)(uintptr_t)fiber_val;
    if (f == NULL)
        pal_abort();
    return tag_int(f->state == FIBER_DONE ? 1 : 0);
}

int64_t ocamlcc_fiber_spawn(int64_t closure)
{
    Fiber *f = alloc_fiber_obj(closure, 1);
    f->result = 1; /* tagged unit arg passed to (fun () -> ...) */
    arc_retain(f); /* scheduler queue owns +1 */
    sched_push_ready(f);
    return (int64_t)(uintptr_t)f;
}

int64_t ocamlcc_fiber_yield(int64_t unit)
{
    (void)unit;
    Fiber *cur = current_fiber();
    if (cur == &tls_main_fiber) {
        sched_poll(0);
        Fiber *next = sched_pop_ready();
        if (next != NULL) {
            next->caller = &tls_main_fiber;
            fiber_swap_to(next);
            if (next->state == FIBER_DONE)
                arc_release(next);
        }
        return 1;
    }
    if (cur->caller == NULL || !cur->is_scheduled) {
        /* Fiber.yield is a scheduler operation; inside a coroutine it would
           queue the coroutine without scheduler ownership and return the
           resume payload to the resumer. */
        ocamlcc_fiber_raise_invalid();
        return 1;
    }
    sched_push_ready(cur);
    Fiber *target = cur->caller;
    cur->caller = NULL;
    fiber_swap_to(target);
    return 1;
}

int64_t ocamlcc_fiber_sleep_ms(int64_t ms_val)
{
    int64_t ms = ms_val >> 1;
    if (ms <= 0)
        return ocamlcc_fiber_yield(1);

    uint64_t deadline = pal_monotonic_ns() + (uint64_t)ms * 1000000ull;
    Fiber *cur = current_fiber();
    if (cur == &tls_main_fiber) {
        for (;;) {
            uint64_t now = pal_monotonic_ns();
            if (now >= deadline)
                break;
            if (!sched_step()) {
                uint64_t rem_ms = (deadline - now + 999999ull) / 1000000ull;
                if (rem_ms > (uint64_t)INT32_MAX)
                    rem_ms = (uint64_t)INT32_MAX;
                int pfd = ensure_poller();
                PalPollEvent ev;
                (void)pal_poller_wait(pfd, &ev, 1, (int)rem_ms);
            } else {
                sched_drain_timers();
            }
        }
        return 1;
    }

    if (cur->caller == NULL || !cur->is_scheduled) {
        ocamlcc_fiber_raise_invalid();
        return 1;
    }
    cur->wake_ns = deadline;
    cur->state = FIBER_WAITING_TIMER;
    cur->sched_next = tls_sched.timer_head;
    tls_sched.timer_head = cur;

    Fiber *target = cur->caller;
    cur->caller = NULL;
    fiber_swap_to(target);
    return 1;
}

static int64_t fiber_fd_wait(int64_t fd_val, uint32_t events)
{
    int fd = (int)(fd_val >> 1);
    int pfd = ensure_poller();
    Fiber *cur = current_fiber();

    if (cur == &tls_main_fiber) {
        tls_sched.main_io_pending = 1;
        tls_sched.main_io_ready = 0;
        if (pal_poller_watch(pfd, fd, events, &tls_main_fiber) < 0)
            pal_abort();
        while (!tls_sched.main_io_ready)
            (void)sched_step();
        tls_sched.main_io_ready = 0;
        return 1;
    }

    if (cur->caller == NULL || !cur->is_scheduled) {
        ocamlcc_fiber_raise_invalid();
        return 1;
    }
    cur->wait_fd = fd;
    cur->wait_events = events;
    cur->state = FIBER_WAITING_IO;
    if (pal_poller_watch(pfd, fd, events, cur) < 0)
        pal_abort();
    cur->sched_next = tls_sched.io_head;
    tls_sched.io_head = cur;

    Fiber *target = cur->caller;
    cur->caller = NULL;
    fiber_swap_to(target);
    return 1;
}

int64_t ocamlcc_fiber_fd_wait_read(int64_t fd_val)
{
    return fiber_fd_wait(fd_val, PAL_POLL_READ);
}

int64_t ocamlcc_fiber_fd_wait_write(int64_t fd_val)
{
    return fiber_fd_wait(fd_val, PAL_POLL_WRITE);
}

int64_t ocamlcc_fiber_await(int64_t fiber_val)
{
    Fiber *f = (Fiber *)(uintptr_t)fiber_val;
    if (f == NULL)
        pal_abort();
    Fiber *cur = current_fiber();

    if (f->state != FIBER_DONE) {
        if (cur == &tls_main_fiber) {
            if (!f->is_scheduled) {
                /* Awaiting a live coroutine from the main fiber can never
                   complete: only Fiber.resume drives coroutines. */
                ocamlcc_fiber_raise_invalid();
                return 1;
            }
            while (f->state != FIBER_DONE) {
                if (!sched_step())
                    pal_abort();
            }
        } else {
            if (!cur->is_scheduled || !f->is_scheduled) {
                /* Waiter handoff routes through the scheduler ready queue,
                   which is only sound between scheduler fibers. */
                ocamlcc_fiber_raise_invalid();
                return 1;
            }
            if (cur->caller == NULL)
                pal_abort();
            cur->state = FIBER_WAITING_IO;
            cur->sched_next = f->waiter_head;
            f->waiter_head = cur;
            Fiber *target = cur->caller;
            cur->caller = NULL;
            fiber_swap_to(target);
        }
    }

    if (f->pending_exn != 0) {
        arc_retain_val(f->pending_exn);
        ocamlcc_set_exn(f->pending_exn);
        return 1;
    }
    arc_retain_val(f->result);
    return f->result;
}

int64_t ocamlcc_fiber_run_all(int64_t unit)
{
    (void)unit;
    if (current_fiber() != &tls_main_fiber)
        pal_abort();
    while (sched_step())
        ;
    return 1;
}

int64_t ocamlcc_pipe(int64_t unit)
{
    (void)unit;
    int fds[2];
    if (pal_pipe(fds) < 0) {
        ocamlcc_raise_sys_error_pipe();
        return 1;
    }
    int64_t *blk = (int64_t *)arc_alloc(0u, 0u, 16u);
    blk[0] = tag_int((int64_t)fds[0]);
    blk[1] = tag_int((int64_t)fds[1]);
    return (int64_t)(uintptr_t)blk;
}

int64_t ocamlcc_fd_read(int64_t fd_val, int64_t bytes_val,
                        int64_t off_val, int64_t len_val)
{
    int fd = (int)(fd_val >> 1);
    int64_t off = off_val >> 1;
    int64_t len = len_val >> 1;
    ArcHeader *hdr = (ArcHeader *)(uintptr_t)bytes_val - 1;
    if (off < 0 || len < 0 ||
        (uint64_t)off + (uint64_t)len > (uint64_t)hdr->reserved) {
        ocamlcc_raise_invalid_arg_oob();
        return 1;
    }
    char *buf = (char *)(uintptr_t)bytes_val + off;
    return tag_int(pal_fd_read(fd, buf, (size_t)len));
}

int64_t ocamlcc_fd_write(int64_t fd_val, int64_t bytes_val,
                         int64_t off_val, int64_t len_val)
{
    int fd = (int)(fd_val >> 1);
    int64_t off = off_val >> 1;
    int64_t len = len_val >> 1;
    ArcHeader *hdr = (ArcHeader *)(uintptr_t)bytes_val - 1;
    if (off < 0 || len < 0 ||
        (uint64_t)off + (uint64_t)len > (uint64_t)hdr->reserved) {
        ocamlcc_raise_invalid_arg_oob();
        return 1;
    }
    const char *buf = (const char *)(uintptr_t)bytes_val + off;
    return tag_int(pal_fd_write(fd, buf, (size_t)len));
}

int64_t ocamlcc_fd_close(int64_t fd_val)
{
    pal_fd_close((int)(fd_val >> 1));
    return 1;
}

/* Legacy/direct helper preserved for fiber_init API compatibility. */
void fiber_init(Fiber *fiber, size_t stack_words)
{
    pal_memset(fiber, 0, sizeof(*fiber));
    (void)stack_words;
    fiber->wait_fd = -1;
    fiber->state = FIBER_SUSPENDED;
}

void fiber_free(Fiber *fiber)
{
    fiber_destroy(fiber);
}
