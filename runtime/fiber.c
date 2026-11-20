/*
 * fiber.c — Wren-style stackful coroutine context, shadow stack, and minimal
 * PAL TLS/poller bridge (scheduler, timers & fd waiters live in Stdlib__fiber).
 */
#include "fiber.h"

#include "arc.h"

#include <pthread.h>
#include <stdlib.h>

#define FIBER_GUARD_BYTES (16u * 1024u)
#define FIBER_STACK_BYTES (256u * 1024u)
#define SHADOW_INIT_BYTES (16u * 1024u)
#define POLLER_BATCH_CAP  64

typedef struct FiberThreadState {
    Fiber   main_fiber;
    int64_t sched_val;
    int     poller_fd;
} FiberThreadState;

static _Thread_local FiberThreadState *tls_state = NULL;
static _Thread_local Fiber            *tls_current_fiber = NULL;

/* Once a stackful fiber is published, execution on that fiber must check
 * TLS. A main-stack frame never becomes abandonable, even across the first
 * fiber creation on this or another thread. */
static _Atomic unsigned g_stackful_fibers_created;

static pthread_once_t g_fiber_tls_once = PTHREAD_ONCE_INIT;
static pthread_key_t  g_fiber_tls_key;
static int            g_fiber_tls_key_ok = 0;

static void fiber_free_buffers(Fiber *f)
{
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
}

static void fiber_tls_cleanup(void *arg)
{
    FiberThreadState *s = (FiberThreadState *)arg;
    if (s == NULL)
        return;
    int64_t sv = s->sched_val;
    s->sched_val = 0;
    fiber_free_buffers(&s->main_fiber);
    /* Detach TLS pointers and release OCaml scheduler state afterwards so any
     * finalizer touching arc_fiber_current() allocates fresh TLS safely. */
    tls_state = NULL;
    tls_current_fiber = NULL;
    if (s->poller_fd >= 0) {
        pal_poller_close(s->poller_fd);
        s->poller_fd = -1;
    }
    free(s);
    if (sv != 0)
        arc_release_val(sv);
}

static void fiber_tls_key_init(void)
{
    if (pthread_key_create(&g_fiber_tls_key, fiber_tls_cleanup) == 0)
        g_fiber_tls_key_ok = 1;
}

static FiberThreadState *fiber_thread_state(void)
{
    FiberThreadState *s = tls_state;
    if (s != NULL)
        return s;
    s = (FiberThreadState *)calloc(1, sizeof(FiberThreadState));
    if (s == NULL)
        pal_abort();
    s->main_fiber.state = FIBER_RUNNING;
    s->poller_fd = -1;
    tls_state = s;
    pthread_once(&g_fiber_tls_once, fiber_tls_key_init);
    if (g_fiber_tls_key_ok)
        (void)pthread_setspecific(g_fiber_tls_key, s);
    return s;
}

#define tls_main_fiber (fiber_thread_state()->main_fiber)

Fiber *arc_fiber_current(void)
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

static inline Fiber *shadow_fiber(void)
{
    if (atomic_load_explicit(&g_stackful_fibers_created, memory_order_relaxed) == 0)
        return NULL;
    Fiber *cur = tls_current_fiber;
    return cur != NULL && cur->c_stack != NULL ? cur : NULL;
}

void arc_fiber_push(int64_t val)
{
    Fiber *cur = shadow_fiber();
    if (cur == NULL)
        return;
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
    Fiber *cur = shadow_fiber();
    if (cur == NULL)
        return;
    if (cur->shadow_base == NULL ||
        (size_t)(cur->shadow_sp - cur->shadow_base) < (size_t)n)
        pal_abort();
    cur->shadow_sp -= (size_t)n;
}

void arc_fiber_push_reuse(void *tok)
{
    Fiber *cur = shadow_fiber();
    if (cur == NULL)
        return;
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
    Fiber *cur = shadow_fiber();
    if (cur == NULL)
        return;
    if (cur->reuse_base == NULL ||
        (size_t)(cur->reuse_sp - cur->reuse_base) < (size_t)n)
        pal_abort();
    cur->reuse_sp -= (size_t)n;
}

void fiber_destroy(Fiber *f)
{
    if (f == NULL || (tls_state != NULL && f == &tls_state->main_fiber))
        return;
    fiber_free_buffers(f);
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
    Fiber *prev = arc_fiber_current();
    prev->exn_slot = ocamlcc_get_exn();
    ocamlcc_set_exn(next->exn_slot);
    tls_current_fiber = next;
    next->state = FIBER_RUNNING;
    pal_ctx_swap(&prev->ctx, &next->ctx);
}

static int ensure_poller(void)
{
    FiberThreadState *s = fiber_thread_state();
    if (s->poller_fd < 0) {
        s->poller_fd = pal_poller_create();
        if (s->poller_fd < 0)
            pal_abort();
    }
    return s->poller_fd;
}

static void __attribute__((noreturn)) fiber_trampoline(void)
{
    Fiber *self = arc_fiber_current();
    int64_t clos = self->entry_closure;
    int64_t arg = self->result;
    self->result = 0;

    int64_t res = ocamlcc_apply1_raw(clos, arg);

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

    Fiber *caller = self->caller;
    self->caller = NULL;
    fiber_swap_to(caller);
    pal_abort();
}

int64_t ocamlcc_fiber_create(int64_t closure)
{
    size_t total_bytes = (size_t)FIBER_GUARD_BYTES + (size_t)FIBER_STACK_BYTES;
    uint8_t *cstack = (uint8_t *)pal_page_alloc(total_bytes);
    if (cstack == NULL)
        pal_abort();
    if (pal_page_protect_none(cstack, FIBER_GUARD_BYTES) != 0) {
        pal_page_free(cstack, total_bytes);
        pal_abort();
    }

    Fiber *f = (Fiber *)arc_alloc((uint16_t)ARC_TAG_FIBER, 0u, (uint32_t)sizeof(Fiber));
    pal_memset(f, 0, sizeof(*f));
    f->c_stack = cstack;
    f->c_stack_bytes = total_bytes;
    shadow_init(f);
    arc_retain_val(closure);
    f->entry_closure = closure;
    f->state = FIBER_SUSPENDED;
    pal_ctx_make(&f->ctx, cstack + total_bytes, fiber_trampoline);
    if (atomic_load_explicit(&g_stackful_fibers_created, memory_order_relaxed) == 0)
        atomic_store_explicit(&g_stackful_fibers_created, 1u, memory_order_relaxed);
    return (int64_t)(uintptr_t)f;
}

int64_t ocamlcc_fiber_resume(int64_t fiber_val, int64_t send_val)
{
    Fiber *f = (Fiber *)(uintptr_t)fiber_val;
    if (f == NULL || f->state != FIBER_SUSPENDED || f->caller != NULL) {
        ocamlcc_fiber_raise_invalid();
        return 1;
    }

    arc_retain(f);
    arc_retain_val(send_val);
    if (f->result != 0)
        arc_release_val(f->result);
    f->result = send_val;
    f->caller = arc_fiber_current();

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

/* poll_finalizers is registered yields = false, so the dispatcher fiber has
 * no shadow-stack window around finalizer callbacks: every suspension entry
 * point checks owns_finalizer_dispatch and refuses instead of stranding. */
static int finalizer_owns_current_fiber(void)
{
    Fiber *cur = arc_fiber_current();
    return cur != NULL && cur->owns_finalizer_dispatch != 0;
}

int64_t ocamlcc_fiber_suspend(int64_t send_val)
{
    Fiber *cur = arc_fiber_current();
    if (finalizer_owns_current_fiber() ||
        cur == &tls_main_fiber || cur->caller == NULL) {
        ocamlcc_fiber_raise_invalid();
        return 1;
    }

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

int64_t ocamlcc_fiber_is_main(int64_t unit)
{
    (void)unit;
    return arc_fiber_current() == &tls_main_fiber ? 3 : 1;
}

int64_t ocamlcc_fiber_can_yield(int64_t unit)
{
    (void)unit;
    if (finalizer_owns_current_fiber()) {
        ocamlcc_fiber_raise_invalid();
        return 1;
    }
    return 1;
}

int64_t ocamlcc_fiber_sched_get(int64_t unit)
{
    (void)unit;
    FiberThreadState *s = fiber_thread_state();
    if (s->sched_val == 0)
        return 1; /* None */
    arc_retain_val(s->sched_val);
    return s->sched_val;
}

int64_t ocamlcc_fiber_sched_set(int64_t opt_val)
{
    FiberThreadState *s = fiber_thread_state();
    int64_t old = s->sched_val;
    arc_retain_val(opt_val);
    s->sched_val = (opt_val == 1) ? 0 : opt_val;
    if (opt_val == 1)
        arc_release_val(opt_val);
    if (old != 0)
        arc_release_val(old);
    return 1;
}

int64_t ocamlcc_monotonic_ns(int64_t unit)
{
    (void)unit;
    return tag_int((int64_t)pal_monotonic_ns());
}

int64_t ocamlcc_poller_watch(int64_t fd_val, int64_t events_val, int64_t tok_val)
{
    int pfd = ensure_poller();
    int fd = (int)(fd_val >> 1);
    uint32_t ev = (uint32_t)(events_val >> 1);
    if (pal_poller_watch(pfd, fd, ev, (void *)(intptr_t)(tok_val >> 1)) < 0)
        ocamlcc_fiber_raise_invalid();
    return 1;
}

int64_t ocamlcc_poller_unwatch_waiter(int64_t fd_val, int64_t events_val, int64_t tok_val)
{
    FiberThreadState *s = fiber_thread_state();
    if (s->poller_fd < 0)
        return 1;
    (void)pal_poller_unwatch_waiter(
        s->poller_fd, (int)(fd_val >> 1),
        (uint32_t)(events_val >> 1), (void *)(intptr_t)(tok_val >> 1));
    return 1;
}

int64_t ocamlcc_poller_wait(int64_t out_arr_val, int64_t timeout_ms_val)
{
    int pfd = ensure_poller();
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)out_arr_val - 1;
    size_t cap = hdr->byte_size / sizeof(int64_t);
    int64_t *out = (int64_t *)(uintptr_t)out_arr_val;
    int max_ev = (cap == 0u) ? 1 : (cap > POLLER_BATCH_CAP ? POLLER_BATCH_CAP : (int)cap);
    PalPollEvent evs[POLLER_BATCH_CAP];
    int n = pal_poller_wait(pfd, evs, max_ev, (int)(timeout_ms_val >> 1));
    if (n <= 0 || cap == 0u)
        return tag_int(0);
    for (int i = 0; i < n; i++)
        out[i] = tag_int((int64_t)(intptr_t)evs[i].udata);
    return tag_int((int64_t)n);
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

void fiber_init(Fiber *fiber, size_t stack_words)
{
    pal_memset(fiber, 0, sizeof(*fiber));
    (void)stack_words;
    fiber->state = FIBER_SUSPENDED;
}

void fiber_free(Fiber *fiber)
{
    fiber_destroy(fiber);
}
