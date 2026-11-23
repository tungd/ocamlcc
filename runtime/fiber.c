/*
 * fiber.c — Wren-style stackful coroutine context, shadow stack, and minimal
 * PAL TLS/poller bridge (scheduler, timers & fd waiters live in Stdlib__fiber).
 */
#include "fiber.h"

#include "arc.h"

#ifndef OCAMLCC_SINGLE_THREAD_RC
#include <pthread.h>
#endif
#include <stdbool.h>
#include <stdlib.h>

#define FIBER_GUARD_BYTES (16u * 1024u)
#define FIBER_STACK_BYTES (256u * 1024u)
#define SHADOW_INIT_BYTES (16u * 1024u)

typedef struct FiberThreadState {
    Fiber   main_fiber;
    int64_t sched_val;
    int     poller_fd;
} FiberThreadState;

#ifdef OCAMLCC_SINGLE_THREAD_RC
static FiberThreadState main_state = {
    .main_fiber = { .state = FIBER_RUNNING },
    .poller_fd = -1,
};
static FiberThreadState *const current_state = &main_state;
static Fiber *current_fiber = &main_state.main_fiber;
static uint64_t current_effect_owner;
#else
static _Thread_local FiberThreadState *current_state;
static _Thread_local Fiber *current_fiber;
static _Thread_local uint64_t current_effect_owner;
#endif
static _Atomic uint64_t                g_next_effect_owner = 1;

/* Once a stackful fiber is published, execution on that fiber must check
 * TLS. A main-stack frame never becomes abandonable, even across the first
 * fiber creation on this or another thread. */
_Atomic uint32_t ocamlcc_stackful_fibers_created;

#ifndef OCAMLCC_SINGLE_THREAD_RC
static pthread_once_t g_fiber_tls_once = PTHREAD_ONCE_INIT;
static pthread_key_t  g_fiber_tls_key;
static int            g_fiber_tls_key_ok = 0;
#endif

static void fiber_drain_reuse(Fiber *f)
{
    if (f->reuse_base != NULL) {
        while (f->reuse_sp > f->reuse_base)
            arc_free_reuse(*--f->reuse_sp);
    }
}

static void fiber_free_reuse_buffer(Fiber *f)
{
    if (f->reuse_base == NULL)
        return;
    size_t bytes = (size_t)(f->reuse_end - f->reuse_base) * sizeof(*f->reuse_base);
    pal_page_free(f->reuse_base, bytes);
    f->reuse_base = NULL;
    f->reuse_sp = NULL;
    f->reuse_end = NULL;
}

static void fiber_free_shadow_buffer(Fiber *f)
{
    if (f->shadow_base == NULL)
        return;
    size_t bytes = (size_t)(f->shadow_end - f->shadow_base) * sizeof(*f->shadow_base);
    pal_page_free(f->shadow_base, bytes);
    f->shadow_base = NULL;
    f->shadow_sp = NULL;
    f->shadow_end = NULL;
}

static void fiber_free_buffers(Fiber *f)
{
    fiber_drain_reuse(f);
    fiber_free_reuse_buffer(f);
    if (f->shadow_base != NULL) {
        while (f->shadow_sp > f->shadow_base)
            arc_release_val((int64_t)*--f->shadow_sp);
        fiber_free_shadow_buffer(f);
    }
}

#ifndef OCAMLCC_SINGLE_THREAD_RC
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
    current_state = NULL;
    current_fiber = NULL;
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

#endif

static FiberThreadState *fiber_thread_state(void)
{
#ifdef OCAMLCC_SINGLE_THREAD_RC
    return current_state;
#else
    FiberThreadState *s = current_state;
    if (s != NULL)
        return s;
    s = (FiberThreadState *)calloc(1, sizeof(FiberThreadState));
    if (s == NULL)
        pal_abort();
    s->main_fiber.state = FIBER_RUNNING;
    s->poller_fd = -1;
    current_state = s;
    pthread_once(&g_fiber_tls_once, fiber_tls_key_init);
    if (g_fiber_tls_key_ok)
        (void)pthread_setspecific(g_fiber_tls_key, s);
    return s;
#endif
}

Fiber *arc_fiber_current(void)
{
    if (current_fiber == NULL)
        current_fiber = &fiber_thread_state()->main_fiber;
    return current_fiber;
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
    if (atomic_load_explicit(&ocamlcc_stackful_fibers_created, memory_order_relaxed) == 0)
        return NULL;
    Fiber *cur = current_fiber;
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

static void fiber_visit_slot(int64_t *slot, FiberValueVisitor visit, void *ctx,
                             bool take)
{
    int64_t value = *slot;
    if (value == 0)
        return;
    if (take)
        *slot = 0;
    visit(value, ctx);
}

static void fiber_visit_fields(Fiber *f, FiberValueVisitor visit, void *ctx,
                               bool take)
{
    int64_t *slots[] = { &f->entry_closure, &f->result, &f->exn_slot, &f->pending_exn };
    for (size_t i = 0; i < sizeof(slots) / sizeof(slots[0]); i++)
        fiber_visit_slot(slots[i], visit, ctx, take);
    for (size_t i = 0; i < FIBER_HANDLER_COUNT; i++)
        fiber_visit_slot(&f->handlers[i], visit, ctx, take);
}

static void fiber_visit_shadow(const Fiber *f, FiberValueVisitor visit, void *ctx)
{
    if (f->shadow_base != NULL) {
        for (const uint64_t *p = f->shadow_base; p < f->shadow_sp; p++)
            visit((int64_t)*p, ctx);
    }
}

void fiber_visit_owned_values(Fiber *f, FiberValueVisitor visit, void *ctx)
{
    fiber_visit_shadow(f, visit, ctx);
    fiber_visit_fields(f, visit, ctx, false);
}

static void fiber_finish_destroy(Fiber *f)
{
    if (f->c_stack != NULL) {
        pal_page_free(f->c_stack, f->c_stack_bytes);
        f->c_stack = NULL;
        f->c_stack_bytes = 0;
    }
    f->state = FIBER_DONE;
}

void fiber_collect_dead(Fiber *f, FiberValueVisitor record, void *ctx)
{
    fiber_drain_reuse(f);
    fiber_visit_shadow(f, record, ctx);
    fiber_visit_fields(f, record, ctx, true);
    fiber_free_shadow_buffer(f);
    fiber_free_reuse_buffer(f);
    fiber_finish_destroy(f);
}

static void fiber_drop_value(int64_t value, void *ctx)
{
    (void)ctx;
    arc_release_val(value);
}

void fiber_destroy(Fiber *f)
{
    if (f == NULL || (current_state != NULL && f == &current_state->main_fiber))
        return;
    fiber_free_buffers(f);
    fiber_visit_fields(f, fiber_drop_value, NULL, true);
    fiber_finish_destroy(f);
}

static void fiber_swap_to(Fiber *next)
{
    Fiber *prev = arc_fiber_current();
    prev->exn_slot = ocamlcc_get_exn();
    ocamlcc_set_exn(next->exn_slot);
    current_fiber = next;
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
    if (atomic_load_explicit(&ocamlcc_stackful_fibers_created, memory_order_relaxed) == 0)
        atomic_store_explicit(&ocamlcc_stackful_fibers_created, 1u, memory_order_relaxed);
    return (int64_t)(uintptr_t)f;
}

static int64_t fiber_resume_owned(Fiber *f, int64_t send_val)
{
    if (f == NULL || f->state != FIBER_SUSPENDED || f->caller != NULL) {
        arc_release_val(send_val);
        ocamlcc_fiber_raise_invalid();
        return 1;
    }

    arc_retain(f);
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

int64_t ocamlcc_fiber_resume(int64_t fiber_val, int64_t send_val)
{
    arc_retain_val(send_val);
    return fiber_resume_owned((Fiber *)(uintptr_t)fiber_val, send_val);
}

/* poll_finalizers is registered yields = false, so the dispatcher fiber has
 * no shadow-stack window around finalizer callbacks: every suspension entry
 * point checks owns_finalizer_dispatch and refuses instead of stranding. */
static int finalizer_owns_current_fiber(void)
{
    Fiber *cur = arc_fiber_current();
    return cur != NULL && cur->owns_finalizer_dispatch != 0;
}

static int effect_fiber(const Fiber *f)
{
    return f->effect_owner != 0;
}

static int64_t fiber_suspend_owned(Fiber *cur, int64_t send_val,
                                   FiberSuspension suspension)
{
    if (cur->result != 0)
        arc_release_val(cur->result);
    cur->result = send_val;
    cur->suspension = suspension;
    cur->state = FIBER_SUSPENDED;

    Fiber *target = cur->caller;
    cur->caller = NULL;
    fiber_swap_to(target);

    int64_t in = cur->result;
    cur->result = 0;
    return in;
}

int64_t ocamlcc_fiber_suspend(int64_t send_val)
{
    Fiber *cur = arc_fiber_current();
    /* A Wren operation belongs to the enclosing Wren coroutine. Forward
     * through any intervening effect delimiters on the way to its caller. */
    for (Fiber *f = cur; f != NULL; f = f->caller) {
        if (f->owns_finalizer_dispatch)
            break;
        if (!effect_fiber(f)) {
            if (f->caller != NULL) {
                arc_retain_val(send_val);
                return fiber_suspend_owned(cur, send_val, FIBER_SUSPEND_WREN);
            }
            break;
        }
    }
    ocamlcc_fiber_raise_invalid();
    return 1;
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
    Fiber *cur = arc_fiber_current();
    while (effect_fiber(cur))
        cur = cur->caller;
    return cur == &fiber_thread_state()->main_fiber ? 3 : 1;
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

/* Effect handlers run on the resumer, outside the captured stack. Each
 * continuation owns one suspended fiber; taking it empties that particular
 * continuation even if the fiber later suspends and produces another. */
static int64_t g_effect_unhandled;
static int64_t g_effect_already_resumed;

int64_t ocamlcc_effect_register_exceptions(int64_t unhandled, int64_t resumed)
{
    int64_t ctor = ((int64_t *)(uintptr_t)unhandled)[0];
    arc_retain_val(ctor);
    arc_retain_val(resumed);
    g_effect_unhandled = ctor;
    g_effect_already_resumed = resumed;
    return 1;
}

static Fiber *effect_take_continuation(int64_t continuation)
{
    _Atomic int64_t *slot = (_Atomic int64_t *)(uintptr_t)continuation;
    int64_t value = atomic_exchange_explicit(slot, 1, memory_order_acq_rel);
    return value == 1 ? NULL : (Fiber *)(uintptr_t)value;
}

int64_t caml_continuation_use_noexc(int64_t continuation)
{
    Fiber *f = effect_take_continuation(continuation);
    return f == NULL ? 1 : (int64_t)(uintptr_t)f;
}

static int64_t effect_capture(Fiber *f)
{
    int64_t *cont = arc_alloc(0, 1, 2 * sizeof(int64_t));
    arc_retain(f);
    atomic_init((_Atomic int64_t *)cont, (int64_t)(uintptr_t)f);
    cont[1] = 1; /* last_fiber is carried by the forwarding frames */
    return (int64_t)(uintptr_t)cont;
}

static void effect_set_handlers(Fiber *f, int64_t retc, int64_t exnc, int64_t effc)
{
    const int64_t next[FIBER_HANDLER_COUNT] = {retc, exnc, effc};
    int64_t old[FIBER_HANDLER_COUNT];
    for (size_t i = 0; i < FIBER_HANDLER_COUNT; i++) {
        arc_retain_val(next[i]);
        old[i] = f->handlers[i];
        f->handlers[i] = next[i];
    }
    for (size_t i = 0; i < FIBER_HANDLER_COUNT; i++)
        arc_release_val(old[i]);
}

int64_t caml_alloc_stack(int64_t retc, int64_t exnc, int64_t effc)
{
    int64_t stack = ocamlcc_fiber_create(1);
    Fiber *f = (Fiber *)(uintptr_t)stack;
    effect_set_handlers(f, retc, exnc, effc);
    /* A newly created OS thread may reuse a departed thread's pthread_t. */
    if (current_effect_owner == 0) {
        current_effect_owner = atomic_fetch_add_explicit(
            &g_next_effect_owner, 1, memory_order_relaxed);
        if (current_effect_owner == 0)
            pal_abort();
    }
    f->effect_owner = current_effect_owner;
    return stack;
}

int64_t caml_continuation_use_and_update_handler_noexc(int64_t cont, int64_t retc,
                                                       int64_t exnc, int64_t effc)
{
    Fiber *f = effect_take_continuation(cont);
    if (f == NULL)
        return 1;
    effect_set_handlers(f, retc, exnc, effc);
    return (int64_t)(uintptr_t)f;
}

static int64_t effect_already_resumed(void)
{
    arc_retain_val(g_effect_already_resumed);
    ocamlcc_set_exn(g_effect_already_resumed);
    return 1;
}

static int64_t effect_drive(Fiber *f, int64_t payload)
{
    if (f->effect_owner != current_effect_owner) {
        arc_release_val(payload);
        ocamlcc_fiber_raise_invalid();
        return 1;
    }
    int64_t result;
    while (1) {
        result = fiber_resume_owned(f, payload);
        if (f->state == FIBER_DONE || f->suspension == FIBER_SUSPEND_EFFECT)
            break;
        payload = fiber_suspend_owned(arc_fiber_current(), result, FIBER_SUSPEND_WREN);
    }

    int64_t exn = ocamlcc_get_exn();
    FiberHandler handler = exn != 0 ? FIBER_EXNC :
        f->state == FIBER_DONE ? FIBER_RETC : FIBER_EFFC;
    if (exn != 0) {
        ocamlcc_set_exn(0);
        result = exn;
    }
    int64_t callback = f->handlers[handler];
    arc_retain_val(callback);
    arc_fiber_push(callback);
    int64_t answer = handler == FIBER_EFFC
        ? ocamlcc_apply3_raw(callback, result, effect_capture(f), 1)
        : ocamlcc_apply1_raw(callback, result);
    arc_fiber_pop(1);
    arc_release_val(callback);
    return answer;
}

/* Resume messages contain a function and its argument. Unit in the
 * function slot denotes injecting an already constructed exception. */
static int64_t effect_reply(int64_t fn, int64_t owned_arg)
{
    int64_t *pair = arc_alloc(0, 2, 2 * sizeof(int64_t));
    arc_retain_val(fn);
    pair[0] = fn;
    pair[1] = owned_arg;
    return (int64_t)(uintptr_t)pair;
}

static int64_t effect_suspend(int64_t effect)
{
    Fiber *cur = arc_fiber_current();
    if (!effect_fiber(cur)) {
        int64_t *exn = arc_alloc(0, 2, 2 * sizeof(int64_t));
        arc_retain_val(g_effect_unhandled);
        arc_retain_val(effect);
        exn[0] = g_effect_unhandled;
        exn[1] = effect;
        ocamlcc_set_exn((int64_t)(uintptr_t)exn);
        return 1;
    }
    if (cur->owns_finalizer_dispatch) {
        ocamlcc_fiber_raise_invalid();
        return 1;
    }
    arc_retain_val(effect);
    return fiber_suspend_owned(cur, effect, FIBER_SUSPEND_EFFECT);
}

int64_t ocamlcc_effect_perform(int64_t effect)
{
    int64_t reply = effect_suspend(effect);
    if (ocamlcc_get_exn() != 0)
        return 1;
    int64_t *pair = (int64_t *)(uintptr_t)reply;
    int64_t fn = pair[0], arg = pair[1];
    arc_retain_val(fn);
    arc_retain_val(arg);
    arc_release_val(reply);
    if (fn == 1) {
        ocamlcc_set_exn(arg);
        return 1;
    }
    arc_fiber_push(fn);
    int64_t result = ocamlcc_apply1_raw(fn, arg);
    arc_fiber_pop(1);
    arc_release_val(fn);
    return result;
}

int64_t ocamlcc_effect_runstack(int64_t stack, int64_t fn, int64_t arg)
{
    Fiber *f = (Fiber *)(uintptr_t)stack;
    arc_retain_val(fn);
    f->entry_closure = fn;
    arc_retain_val(arg);
    return effect_drive(f, arg);
}

int64_t ocamlcc_effect_resume(int64_t stack, int64_t fn, int64_t arg, int64_t last)
{
    (void)last;
    if (stack == 1)
        return effect_already_resumed();
    arc_retain_val(arg);
    return effect_drive((Fiber *)(uintptr_t)stack, effect_reply(fn, arg));
}

int64_t ocamlcc_effect_reperform(int64_t effect, int64_t cont, int64_t last)
{
    (void)last;
    /* Capture the next enclosing stack with the inner continuation still
     * rooted here. Forward its reply to the original perform unchanged. */
    int64_t reply = effect_suspend(effect);
    int64_t exn = ocamlcc_get_exn();
    if (exn != 0) {
        ocamlcc_set_exn(0);
        reply = effect_reply(1, exn);
    }
    Fiber *f = effect_take_continuation(cont);
    if (f == NULL) {
        arc_release_val(reply);
        return effect_already_resumed();
    }
    arc_fiber_push((int64_t)(uintptr_t)f);
    int64_t result = effect_drive(f, reply);
    arc_fiber_pop(1);
    arc_release(f);
    return result;
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

static size_t poller_array_length(int64_t array)
{
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)array - 1;
    return hdr->byte_size / sizeof(int64_t);
}

static int64_t poller_wait(const PalPollEvent *adds, int nadds, int64_t out_array,
                           int timeout_ms)
{
    int pfd = ensure_poller();
    size_t cap = poller_array_length(out_array);
    int64_t *out = (int64_t *)(uintptr_t)out_array;
    int max_ev = cap == 0u ? 1 : (cap > PAL_POLL_BATCH_MAX ? PAL_POLL_BATCH_MAX : (int)cap);
    PalPollEvent evs[PAL_POLL_BATCH_MAX];
    int n = pal_poller_wait_adding(pfd, adds, nadds, evs, max_ev, timeout_ms);
    if (n <= 0 || cap == 0u)
        return tag_int(0);
    for (int i = 0; i < n; i++) {
        int64_t token = (int64_t)(intptr_t)evs[i].udata;
        out[i] = tag_int(evs[i].events == PAL_POLL_INVALID ? -token : token);
    }
    return tag_int((int64_t)n);
}

int64_t ocamlcc_poller_wait(int64_t out_arr_val, int64_t timeout_ms_val)
{
    return poller_wait(NULL, 0, out_arr_val, (int)(timeout_ms_val >> 1));
}

int64_t ocamlcc_poller_wait_adding(int64_t requests, int64_t count, int64_t out_array,
                                  int64_t timeout_ms)
{
    int64_t nadds = count >> 1;
    if (nadds < 0 || nadds > PAL_POLL_BATCH_MAX ||
        (size_t)nadds > poller_array_length(requests) / 3 ||
        (size_t)nadds > poller_array_length(out_array)) {
        ocamlcc_fiber_raise_invalid();
        return tag_int(0);
    }
    const int64_t *request = (const int64_t *)(uintptr_t)requests;
    PalPollEvent adds[PAL_POLL_BATCH_MAX];
    for (int i = 0; i < nadds; i++, request += 3) {
        adds[i] = (PalPollEvent){(int)(request[0] >> 1), (uint32_t)(request[1] >> 1),
                                 (void *)(intptr_t)(request[2] >> 1)};
    }
    return poller_wait(adds, (int)nadds, out_array, (int)(timeout_ms >> 1));
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
