/* ARC ownership, storage reuse, exceptions, and finalizer dispatch. */
#include "arc_internal.h"

#define LOCAL_DROP_CAP   256u
#define DROP_PAGE_SIZE   (16u * 1024u)
#define DROP_PAGE_CAP    ((DROP_PAGE_SIZE - sizeof(void *)) / sizeof(ArcHeader *))
typedef struct DropPage {
    struct DropPage *prev;
    ArcHeader *items[1];
} DropPage;

extern void ocamlcc_c_mutex_free(void *p);
extern void ocamlcc_c_cond_free(void *c);
extern void ocamlcc_c_thread_free(void *p);

_Atomic int g_cc_waiting = 0;
_Atomic int g_active_mutators = 0;
_Thread_local int tls_os_mutator_active = 0;
#ifdef OCAMLCC_SINGLE_THREAD_RC
static ForeignRelease *pending_foreign_releases;
static unsigned foreign_release_depth;
#else
static _Thread_local ForeignRelease *pending_foreign_releases;
static _Thread_local unsigned foreign_release_depth;
#endif

/* Keep TLS address materialization in the cold calls. Optimizers can
 * otherwise hoist it out of the branch even when accesses are guarded. */
static __attribute__((noinline)) void before_fiber_release(
    int deferred, ForeignRelease *head, ForeignRelease *tail)
{
    if (!deferred)
        foreign_release_depth++;
    if (head != NULL) {
        tail->next = pending_foreign_releases;
        pending_foreign_releases = head;
    }
}

/* A callback may call a generated binding, collect, or release another view.
 * Finish the outer ARC traversal and leave the collector and FFI gates first. */
static void drain_foreign_releases(void)
{
    if (tls_os_mutator_active || foreign_release_depth)
        return;
    foreign_release_depth++;
    int64_t saved_exn = ocamlcc_get_exn();
    ocamlcc_set_exn(0);
    while (pending_foreign_releases) {
        ForeignRelease *owner = pending_foreign_releases;
        pending_foreign_releases = owner->next;
        owner->release(owner->base, owner->context);
        int entered = arc_mutator_enter();
        int64_t callback_exn = ocamlcc_get_exn();
        ocamlcc_set_exn(0);
        arc_release_val(callback_exn);
        arc_release(owner);
        arc_mutator_leave(entered);
    }
    ocamlcc_set_exn(saved_exn);
    foreign_release_depth--;
}

static __attribute__((noinline)) void finish_subtree_foreign_releases(
    int deferred, ForeignRelease *head, ForeignRelease *tail)
{
    if (head != NULL) {
        tail->next = pending_foreign_releases;
        pending_foreign_releases = head;
    }
    if (deferred)
        foreign_release_depth--;
    if (pending_foreign_releases)
        drain_foreign_releases();
}

void defer_foreign_releases(void)
{
    foreign_release_depth++;
}

void resume_foreign_releases(void)
{
    foreign_release_depth--;
    if (pending_foreign_releases)
        drain_foreign_releases();
}

/* Module-init re-entrancy: generated init functions call each other's
 * ocamlcc_init_<Mod> unconditionally, so mutually dependent modules recurse
 * into the same slot on the current thread. Track the slots this thread has
 * claimed; a re-entrant hit means "already initializing here" and must skip
 * (return 0), never spin — spinning would self-deadlock on the -2 marker.
 * Only a slot marked -2 by a *different* thread is worth waiting on. */
#define OCAMLC_INIT_MAX_DEPTH 64
static _Thread_local _Atomic int64_t *tls_init_slots[OCAMLC_INIT_MAX_DEPTH];
static _Thread_local int tls_init_depth = 0;

static int tls_init_slot_active(_Atomic int64_t *slot)
{
    for (int i = 0; i < tls_init_depth; i++)
        if (tls_init_slots[i] == slot)
            return 1;
    return 0;
}

static void tls_init_slot_push(_Atomic int64_t *slot)
{
    if (tls_init_depth < OCAMLC_INIT_MAX_DEPTH)
        tls_init_slots[tls_init_depth++] = slot;
}

static void tls_init_slot_pop(_Atomic int64_t *slot)
{
    for (int i = tls_init_depth - 1; i >= 0; i--) {
        if (tls_init_slots[i] == slot) {
            tls_init_slots[i] = tls_init_slots[--tls_init_depth];
            tls_init_slots[tls_init_depth] = NULL;
            return;
        }
    }
}

#ifdef OCAMLCC_SINGLE_THREAD_RC
_Atomic unsigned g_rc_owner_claimed;
_Thread_local int tls_rc_owner;
#endif


int64_t ocamlcc_init_try_enter(_Atomic int64_t *slot)
{
    check_rc_thread();
    if (tls_init_slot_active(slot))
        return 0; /* re-entrant same-thread init; caller proceeds unblocked */
    for (;;) {
        int64_t v = atomic_load_explicit(slot, memory_order_acquire);
        if (v != 0 && v != -2)
            return 0;
        if (v == -2) {
            cpu_relax();
            continue;
        }
        int64_t expected = 0;
        if (atomic_compare_exchange_strong_explicit(
                slot, &expected, -2, memory_order_acq_rel, memory_order_acquire)) {
            tls_init_slot_push(slot);
            return 1;
        }
    }
}

void ocamlcc_init_finish(_Atomic int64_t *slot, int64_t val)
{
    int64_t store_val = (ocamlcc_get_exn() != 0) ? 0 : val;
    atomic_store_explicit(slot, store_val, memory_order_release);
    tls_init_slot_pop(slot);
}

int arc_mutator_enter(void)
{
    if (tls_os_mutator_active != 0)
        return 0;
    check_rc_thread();
    for (;;) {
        while (atomic_load_explicit(&g_cc_waiting, memory_order_acquire) != 0)
            cpu_relax();
        atomic_fetch_add_explicit(&g_active_mutators, 1, memory_order_acq_rel);
        if (atomic_load_explicit(&g_cc_waiting, memory_order_seq_cst) == 0)
            break;
        atomic_fetch_sub_explicit(&g_active_mutators, 1, memory_order_release);
    }
    tls_os_mutator_active = 1;
    return 1;
}

#ifdef OCAMLCC_SINGLE_THREAD_RC
/* Generated modules with inline refcounts require this profile at link time. */
int ocamlcc_arc_enter_single_thread(void)
{
    return arc_mutator_enter();
}
#endif

void arc_mutator_leave(int entered)
{
    if (entered) {
        tls_os_mutator_active = 0;
        atomic_fetch_sub_explicit(&g_active_mutators, 1, memory_order_release);
        if (pending_foreign_releases) drain_foreign_releases();
    }
}

_Atomic int64_t g_live_objects = 0;
static _Atomic int64_t g_reuse_hits = 0;
_Atomic uint64_t g_alloc_words = 0;
static _Atomic int64_t g_gc_collections = 0;
/* The generated fast path can skip TLS while the current thread's slot
 * is known to be empty. Threads publish a count before writing a nonzero
 * slot and remove their count only after clearing it. */
_Atomic uint32_t ocamlcc_exn_active;

#ifdef OCAMLCC_SINGLE_THREAD_RC
int64_t ocamlcc_exn_slot;

int64_t ocamlcc_get_exn(void) { return ocamlcc_exn_slot; }

void ocamlcc_set_exn(int64_t exn)
{
    bool was_active = ocamlcc_exn_slot != 0;
    ocamlcc_exn_slot = exn;
    if (was_active != (exn != 0))
        atomic_store_explicit(&ocamlcc_exn_active, exn != 0, memory_order_relaxed);
}
#else
static _Thread_local int64_t tls_exn_slot;
static pthread_once_t g_exn_cleanup_once = PTHREAD_ONCE_INIT;
static pthread_key_t g_exn_cleanup_key;
static bool g_exn_cleanup_ready;

static void exn_thread_cleanup(void *unused)
{
    (void)unused;
    /* A non-null key owns one count even if the platform has already
     * destroyed the thread-local storage by the time this callback runs. */
    tls_exn_slot = 0;
    atomic_fetch_sub_explicit(&ocamlcc_exn_active, 1u, memory_order_release);
}

static void exn_create_cleanup_key(void)
{
    g_exn_cleanup_ready = pthread_key_create(&g_exn_cleanup_key, exn_thread_cleanup) == 0;
}

static __attribute__((noinline)) int64_t get_thread_exception(void)
{
    return tls_exn_slot;
}

int64_t ocamlcc_get_exn(void)
{
    if (atomic_load_explicit(&ocamlcc_exn_active, memory_order_relaxed) == 0u)
        return 0;
    return get_thread_exception();
}

static __attribute__((noinline)) void set_thread_exception(int64_t exn)
{
    bool was_active = tls_exn_slot != 0;
    if (!was_active && exn != 0) {
        pthread_once(&g_exn_cleanup_once, exn_create_cleanup_key);
        if (g_exn_cleanup_ready)
            pthread_setspecific(g_exn_cleanup_key, &g_exn_cleanup_once);
        atomic_fetch_add_explicit(&ocamlcc_exn_active, 1u, memory_order_relaxed);
    }
    tls_exn_slot = exn;
    if (was_active && exn == 0) {
        if (g_exn_cleanup_ready)
            pthread_setspecific(g_exn_cleanup_key, NULL);
        atomic_fetch_sub_explicit(&ocamlcc_exn_active, 1u, memory_order_release);
    }
}

void ocamlcc_set_exn(int64_t exn)
{
    if (exn != 0 || atomic_load_explicit(&ocamlcc_exn_active, memory_order_relaxed) != 0u)
        set_thread_exception(exn);
}
#endif

static size_t exn_append_bytes(char *buf, size_t cap, size_t pos,
                               const char *src, size_t len)
{
    if (pos + 1u >= cap)
        return pos;
    size_t avail = cap - 1u - pos;
    size_t n = (len < avail) ? len : avail;
    if (n > 0u)
        pal_memcpy(buf + pos, src, n);
    return pos + n;
}

static size_t exn_append_cstr(char *buf, size_t cap, size_t pos, const char *s)
{
    size_t len = 0;
    while (s[len] != '\0')
        len++;
    return exn_append_bytes(buf, cap, pos, s, len);
}

static size_t exn_append_i64(char *buf, size_t cap, size_t pos, int64_t v)
{
    char tmp[32];
    size_t n = 0;
    uint64_t u;
    if (v < 0) {
        pos = exn_append_bytes(buf, cap, pos, "-", 1u);
        u = (uint64_t)(-(v + 1)) + 1ull;
    } else {
        u = (uint64_t)v;
    }
    do {
        tmp[n++] = (char)('0' + (u % 10ull));
        u /= 10ull;
    } while (u > 0ull);
    for (size_t i = n; i > 0u; i--)
        pos = exn_append_bytes(buf, cap, pos, &tmp[i - 1u], 1u);
    return pos;
}

void ocamlcc_format_exn(int64_t ex, char *buf, size_t cap)
{
    if (buf == NULL || cap == 0u)
        return;
    if (ex == 0 || (ex & 1) != 0) {
        size_t pos = exn_append_cstr(buf, cap, 0u, "OCaml exception");
        buf[pos] = '\0';
        return;
    }
    const ArcHeader *eh = (const ArcHeader *)(uintptr_t)ex - 1;
    int64_t ctor = 0;
    if (eh->tag == 248u) {
        ctor = ex;
    } else if (eh->tag == 0u && arc_scan_count(eh) >= 1u) {
        ctor = ((const int64_t *)(uintptr_t)ex)[0];
    }
    size_t pos = 0;
    if (ctor != 0 && (ctor & 1) == 0) {
        const ArcHeader *ch = (const ArcHeader *)(uintptr_t)ctor - 1;
        if (ch->tag == 248u && ch->byte_size >= 8u) {
            int64_t name_v = ((const int64_t *)(uintptr_t)ctor)[0];
            if (name_v != 0 && (name_v & 1) == 0) {
                const ArcHeader *nh = (const ArcHeader *)(uintptr_t)name_v - 1;
                if (nh->tag == (uint16_t)ARC_TAG_STRING) {
                    pos = exn_append_bytes(buf, cap, pos,
                                           (const char *)(uintptr_t)name_v,
                                           (size_t)nh->reserved);
                }
            }
        }
    }
    if (pos == 0u)
        pos = exn_append_cstr(buf, cap, pos, "OCaml exception");
    if (eh->tag == 0u && arc_scan_count(eh) >= 2u) {
        int64_t arg = ((const int64_t *)(uintptr_t)ex)[1];
        if (arg != 0 && (arg & 1) == 0) {
            const ArcHeader *ah = (const ArcHeader *)(uintptr_t)arg - 1;
            if (ah->tag == (uint16_t)ARC_TAG_STRING) {
                pos = exn_append_cstr(buf, cap, pos, ": ");
                pos = exn_append_bytes(buf, cap, pos,
                                       (const char *)(uintptr_t)arg,
                                       (size_t)ah->reserved);
            }
        } else if ((arg & 1) != 0) {
            pos = exn_append_cstr(buf, cap, pos, "(");
            pos = exn_append_i64(buf, cap, pos, arg >> 1);
            pos = exn_append_cstr(buf, cap, pos, ")");
        }
    }
    buf[pos] = '\0';
}

static int64_t alloc_dummy_common(int64_t size_val, uint16_t tag, uint16_t scan)
{
    int64_t n = size_val >> 1;
    if (n < 0 || n > 0xffff)
        pal_abort();
    uint32_t bsz = (n == 0) ? 8u : (uint32_t)((uint64_t)n * 8u);
    int64_t *blk = (int64_t *)arc_alloc(tag, scan, bsz);
    for (int64_t i = 0; i < n; i++)
        blk[i] = (tag == (uint16_t)ARC_TAG_FLOAT_ARRAY) ? 0 : 1;
    return (int64_t)(uintptr_t)blk;
}

int64_t caml_alloc_dummy(int64_t size_val)
{
    int64_t n = size_val >> 1;
    return alloc_dummy_common(size_val, 0u, (n > 0) ? (uint16_t)n : 0u);
}

int64_t caml_alloc_dummy_float(int64_t size_val)
{
    return alloc_dummy_common(size_val, (uint16_t)ARC_TAG_FLOAT_ARRAY, 0u);
}

int64_t caml_alloc_dummy_lazy(int64_t size_val)
{
    return caml_alloc_dummy(size_val);
}

int64_t caml_update_dummy(int64_t dummy_val, int64_t new_val)
{
    if (!is_heap_ptr(dummy_val) || !is_heap_ptr(new_val))
        pal_abort();
    ArcHeader *dhdr = (ArcHeader *)(uintptr_t)dummy_val - 1;
    ArcHeader *nhdr = (ArcHeader *)(uintptr_t)new_val - 1;
    if (nhdr->byte_size > dhdr->byte_size)
        pal_abort();

    /* Release any previously held scanned children on [dummy]. */
    uint16_t old_count = arc_scan_count(dhdr);
    if (dhdr->tag == (uint16_t)ARC_TAG_CLOSURE) {
        ArcClosure *dc = (ArcClosure *)(uintptr_t)dummy_val;
        for (uint16_t i = 0; i < old_count; i++)
            arc_release_val((int64_t)dc->env[i]);
    } else if (dhdr->tag == (uint16_t)ARC_TAG_ARRAY) {
        int64_t *da = (int64_t *)(uintptr_t)dummy_val;
        uint32_t n = array_pointer_slots(dhdr);
        for (uint32_t i = 0; i < n; i++)
            arc_release_val(da[i]);
    } else if (!is_unscanned_leaf_tag(dhdr->tag)) {
        int64_t *df = (int64_t *)(uintptr_t)dummy_val;
        for (uint16_t i = 0; i < old_count; i++)
            arc_release_val(df[i]);
    }

    arc_lock(&g_cc_lock);
    cc_roots_remove_locked(dhdr);
    arc_unlock(&g_cc_lock);

    pal_memcpy((void *)(uintptr_t)dummy_val, (const void *)(uintptr_t)new_val,
               nhdr->byte_size);
    dhdr->tag = nhdr->tag;
    uint16_t new_count = arc_scan_count(nhdr);
    uint16_t count = new_count;
    arc_lock(&g_weak_lock);
    if (arc_has_spare_scan_bit(dhdr))
        count |= atomic_load_explicit(&dhdr->scan_fields, memory_order_relaxed)
                 & ARC_FLAG_WEAK_TARGET;
    atomic_store_explicit(&dhdr->scan_fields, count, memory_order_relaxed);
    arc_unlock(&g_weak_lock);
    if (nhdr->tag == (uint16_t)ARC_TAG_CUSTOM ||
        nhdr->tag == (uint16_t)ARC_TAG_STRING)
        dhdr->reserved = nhdr->reserved;
    /* Preserve dhdr->byte_size so slab_free returns it to its original class. */

    /* Retain newly-copied scanned children because [dummy] now owns a ref. */
    if (dhdr->tag == (uint16_t)ARC_TAG_CLOSURE) {
        ArcClosure *dc = (ArcClosure *)(uintptr_t)dummy_val;
        for (uint16_t i = 0; i < new_count; i++)
            arc_retain_val((int64_t)dc->env[i]);
    } else if (dhdr->tag == (uint16_t)ARC_TAG_ARRAY) {
        int64_t *da = (int64_t *)(uintptr_t)dummy_val;
        uint32_t n = array_pointer_slots(nhdr);
        for (uint32_t i = 0; i < n; i++)
            arc_retain_val(da[i]);
        for (uint32_t i = nhdr->byte_size / 8u; i < dhdr->byte_size / 8u; i++)
            da[i] = 1;
    } else if (!is_unscanned_leaf_tag(dhdr->tag)) {
        int64_t *df = (int64_t *)(uintptr_t)dummy_val;
        for (uint16_t i = 0; i < new_count; i++)
            arc_retain_val(df[i]);
    }
    return 1;
}

int64_t caml_update_dummy_lazy(int64_t dummy_val, int64_t new_val)
{
    return caml_update_dummy(dummy_val, new_val);
}

DEFINE_IMMORTAL_STR(g_inv_arg_finalise, "Gc.finalise");
DEFINE_IMMORTAL_STR(g_inv_arg_oob_str, "index out of bounds");
DEFINE_IMMORTAL_STR(g_inv_arg_fiber_str,
                    "Fiber: coroutine/scheduler cross-call");

void raise_invalid_arg_imm(const char *imm_str)
{
    int64_t *blk = (int64_t *)arc_alloc(0u, 2u, 16u);
    blk[0] = (int64_t)(uintptr_t)ocamlcc_global_Invalid_argument;
    blk[1] = (int64_t)(uintptr_t)imm_str;
    ocamlcc_set_exn((int64_t)(uintptr_t)blk);
}

void ocamlcc_raise_invalid_arg_oob(void)
{
    raise_invalid_arg_imm(g_inv_arg_oob_str.str);
}

void ocamlcc_fiber_raise_invalid(void)
{
    raise_invalid_arg_imm(g_inv_arg_fiber_str.str);
}

DEFINE_IMMORTAL_STR(g_sys_err_pipe_str, "pipe failed");

void ocamlcc_raise_sys_error_pipe(void)
{
    int64_t *blk = (int64_t *)arc_alloc(0u, 2u, 16u);
    blk[0] = (int64_t)(uintptr_t)ocamlcc_global_Sys_error;
    blk[1] = (int64_t)(uintptr_t)g_sys_err_pipe_str.str;
    ocamlcc_set_exn((int64_t)(uintptr_t)blk);
}

void arc_retain(void *obj)
{
    ArcHeader *hdr = (ArcHeader *)obj - 1;
    uint32_t rc = atomic_load_explicit(&hdr->refcount, memory_order_relaxed);
    if (rc != ARC_IMMORTAL)
        refcount_add(hdr, rc, 1u);
}

typedef struct DropWorklist {
    ArcHeader *local[LOCAL_DROP_CAP];
    uint32_t   local_len;
    DropPage  *overflow;
    uint32_t   overflow_len;
} DropWorklist;

static void work_push(DropWorklist *w, ArcHeader *hdr)
{
    if (w->local_len < LOCAL_DROP_CAP) {
        w->local[w->local_len++] = hdr;
        return;
    }
    if (w->overflow == NULL || w->overflow_len == (uint32_t)DROP_PAGE_CAP) {
        DropPage *pg = (DropPage *)pal_page_alloc(DROP_PAGE_SIZE);
        if (pg == NULL)
            pal_abort();
        pg->prev = w->overflow;
        w->overflow = pg;
        w->overflow_len = 0;
    }
    w->overflow->items[w->overflow_len++] = hdr;
}

static ArcHeader *work_pop(DropWorklist *w)
{
    if (w->overflow != NULL) {
        ArcHeader *hdr = w->overflow->items[--w->overflow_len];
        if (w->overflow_len == 0) {
            DropPage *prev = w->overflow->prev;
            pal_page_free(w->overflow, DROP_PAGE_SIZE);
            w->overflow = prev;
            w->overflow_len = (prev != NULL) ? (uint32_t)DROP_PAGE_CAP : 0u;
        }
        return hdr;
    }
    if (w->local_len > 0)
        return w->local[--w->local_len];
    return NULL;
}

static inline void drop_child_val(DropWorklist *w, int64_t val, ArcHeader **tail)
{
    if (!is_heap_ptr(val))
        return;
    ArcHeader *chdr = (ArcHeader *)(uintptr_t)val - 1;
    uint32_t rc = atomic_load_explicit(&chdr->refcount, memory_order_relaxed);
    if (rc == ARC_IMMORTAL)
        return;
    if (rc > 1u)
        cc_roots_add(chdr);
    if (refcount_drop_last(chdr, rc)) {
        if (*tail != NULL)
            work_push(w, *tail);
        *tail = chdr;
    }
}

/* Releases children of [root] with O(1) stack on right-spines / tail fields.
 * Frees every dead descendant; frees [root] iff [free_root] is non-zero. */
static __attribute__((noinline)) void release_subtree_slow(ArcHeader *root,
                                                           int free_root)
{
#ifdef OCAMLCC_SINGLE_THREAD_RC
    const memory_order cc_order = memory_order_relaxed;
#else
    const memory_order cc_order = memory_order_acquire;
#endif
    ForeignRelease *foreign_head = NULL, *foreign_tail = NULL;
    int defer_nested_releases = 0;
    DropWorklist w;
    w.local_len = 0;
    w.overflow = NULL;
    w.overflow_len = 0;

    ArcHeader *cur = root;
    while (cur != NULL) {
        ArcHeader *tail = NULL;
        uint16_t tag = cur->tag;
        if (tag == ARC_TAG_CLOSURE) {
            ArcClosure *c = (ArcClosure *)(cur + 1);
            uint32_t n = arc_scan_count(cur);
            for (uint32_t i = 0; i < n; i++)
                drop_child_val(&w, (int64_t)c->env[i], &tail);
        } else if (tag == ARC_TAG_PAP) {
            ArcPap *p = (ArcPap *)(cur + 1);
            drop_child_val(&w, (int64_t)(uintptr_t)p->orig, &tail);
            uint64_t n = p->n_applied;
            for (uint64_t i = 0; i < n; i++)
                drop_child_val(&w, p->args[i], &tail);
        } else if (tag == ARC_TAG_ARRAY) {
            int64_t *arr = (int64_t *)(cur + 1);
            uint32_t n = array_pointer_slots(cur);
            for (uint32_t i = 0; i < n; i++)
                drop_child_val(&w, arr[i], &tail);
        } else if (tag == ARC_TAG_WEAK) {
            weak_unlink((ArcWeakArray *)(cur + 1));
        } else if (tag == ARC_TAG_FIBER) {
            /* Destroying a fiber can recursively drop its shadow roots. */
            before_fiber_release(defer_nested_releases, foreign_head, foreign_tail);
            defer_nested_releases = 1;
            foreign_head = NULL;
            foreign_tail = NULL;
            fiber_destroy((Fiber *)(cur + 1));
        } else if (tag == ARC_TAG_CUSTOM) {
            void *p = (void *)(uintptr_t)(*(uint64_t *)(cur + 1));
            if (cur->reserved == ARC_CUSTOM_MUTEX)
                ocamlcc_c_mutex_free(p);
            else if (cur->reserved == ARC_CUSTOM_COND)
                ocamlcc_c_cond_free(p);
            else if (cur->reserved == ARC_CUSTOM_THREAD) {
                OcamlccThreadCtx *t = p;
                drop_child_val(&w, t->fn, &tail);
                drop_child_val(&w, t->result, &tail);
                drop_child_val(&w, t->exn, &tail);
                ocamlcc_c_thread_free(p);
            } else if (cur->reserved == ARC_CUSTOM_BIGARRAY) {
                ArcBigarray *a = (void *)(cur + 1);
                drop_child_val(&w, (int64_t)(uintptr_t)a->backing, &tail);
            } else if (cur->reserved == ARC_CUSTOM_BIGARRAY_BUFFER) {
                ArcBigarrayBuffer *b = (void *)(cur + 1);
                if (b->owner) {
                    if (foreign_head == NULL)
                        foreign_tail = b->owner;
                    b->owner->next = foreign_head;
                    foreign_head = b->owner;
                } else {
                    pal_page_free(b->data, b->bytes);
                }
            }
        } else if (!is_unscanned_leaf_tag(tag)) {
            int64_t *fields = (int64_t *)(cur + 1);
            uint32_t n = arc_scan_count(cur);
            for (uint32_t i = 0; i < n; i++)
                drop_child_val(&w, fields[i], &tail);
        }

        if (might_be_weak_target(cur))
            clear_weak_target(cur);

        if (((atomic_load_explicit(&cur->reserved, memory_order_relaxed) &
              CC_BUFFERED) != 0u && is_cycle_candidate_obj(cur)) ||
            atomic_load_explicit(&g_cc_active, cc_order) != 0) {
            arc_lock(&g_cc_lock);
            cc_roots_remove_locked(cur);
            arc_unlock(&g_cc_lock);
        }

        account_objects(&g_live_objects, -1);
        if (cur != root || free_root)
            slab_free(cur);

        cur = (tail != NULL) ? tail : work_pop(&w);
    }
    if (foreign_head != NULL || defer_nested_releases)
        finish_subtree_foreign_releases(defer_nested_releases, foreign_head, foreign_tail);
}

static inline void release_subtree(ArcHeader *root, int free_root)
{
    /* Ordinary blocks with a zero scan count have no owned children,
     * regardless of their payload size. Only inspect fields on the final drop. */
    uint16_t tag = root->tag;
    if ((tag == ARC_TAG_STRING || tag == ARC_TAG_FLOAT || tag == ARC_TAG_FLOAT_ARRAY ||
         (tag < ARC_TAG_ARRAY &&
          (arc_scan_count(root) == 0u || is_small_immediate_block(root)) &&
          (atomic_load_explicit(&root->reserved, memory_order_relaxed) & CC_BUFFERED) == 0u)) &&
        !might_be_weak_target(root)) {
        account_objects(&g_live_objects, -1);
        if (free_root)
            slab_free(root);
    } else {
        release_subtree_slow(root, free_root);
    }
}

void arc_release(void *obj)
{
    ArcHeader *hdr = (ArcHeader *)obj - 1;
    uint32_t rc = atomic_load_explicit(&hdr->refcount, memory_order_relaxed);
    if (rc == ARC_IMMORTAL)
        return;
    if (rc > 1u)
        cc_roots_add(hdr);
    if (refcount_drop_last(hdr, rc)) {
        release_subtree(hdr, 1);
    }
}

void arc_retain_val(int64_t val)
{
    if (is_heap_ptr(val))
        arc_retain((void *)(uintptr_t)val);
}

int64_t ocamlcc_opaque_identity(int64_t val)
{
    arc_retain_val(val);
    return val;
}

void arc_release_val(int64_t val)
{
    if (is_heap_ptr(val))
        arc_release((void *)(uintptr_t)val);
}

void *arc_drop_reuse(int64_t val)
{
    if (!is_heap_ptr(val))
        return NULL;
    ArcHeader *hdr = (ArcHeader *)(uintptr_t)val - 1;
    uint32_t rc = atomic_load_explicit(&hdr->refcount, memory_order_relaxed);
    if (rc == ARC_IMMORTAL)
        return NULL;
    if (rc > 1u)
        cc_roots_add(hdr);
    if (refcount_drop_last(hdr, rc)) {
        release_subtree(hdr, 0);
        return (void *)hdr;
    }
    return NULL;
}

static int reuse_fits(const ArcHeader *hdr, uint32_t byte_size)
{
    if (hdr == NULL)
        return 0;
    if ((uint64_t)sizeof(ArcHeader) + (uint64_t)byte_size > (uint64_t)UINT32_MAX)
        pal_abort();
    int old_cls = size_class_for((uint32_t)sizeof(ArcHeader) + hdr->byte_size);
    int new_cls = size_class_for((uint32_t)sizeof(ArcHeader) + byte_size);
    return old_cls >= 0 && old_cls == new_cls;
}

void *arc_alloc_reuse(void *reuse_tok, uint16_t tag, uint16_t scan_fields, uint32_t byte_size)
{
    if (reuse_tok == NULL)
        return arc_alloc(tag, scan_fields, byte_size);

    ArcHeader *hdr = (ArcHeader *)reuse_tok;
    if (reuse_fits(hdr, byte_size)) {
        atomic_init(&hdr->refcount, 1u);
        hdr->tag = tag;
        atomic_init(&hdr->scan_fields, raw_scan_fields(tag, scan_fields, byte_size));
        hdr->byte_size = byte_size;
        hdr->reserved = 0;
        account_objects(&g_live_objects, 1);
        account_objects(&g_reuse_hits, 1);
        return hdr + 1;
    }

    slab_free(hdr);
    return arc_alloc(tag, scan_fields, byte_size);
}

void *arc_alloc_reuse_or(void *primary, void *fallback, uint16_t tag,
                         uint16_t scan_fields, uint32_t byte_size)
{
    if (reuse_fits((const ArcHeader *)primary, byte_size)) {
        arc_free_reuse(fallback);
        return arc_alloc_reuse(primary, tag, scan_fields, byte_size);
    }
    arc_free_reuse(primary);
    return arc_alloc_reuse(fallback, tag, scan_fields, byte_size);
}

void arc_free_reuse(void *reuse_tok)
{
    if (reuse_tok != NULL)
        slab_free((ArcHeader *)reuse_tok);
}

int64_t arc_live_objects(void)
{
    return atomic_load_explicit(&g_live_objects, memory_order_relaxed);
}

int64_t arc_reuse_hits(void)
{
    return atomic_load_explicit(&g_reuse_hits, memory_order_relaxed);
}

int64_t ocamlcc_arc_live(int64_t unit)
{
    (void)unit;
    return tag_int(arc_live_objects());
}

int64_t ocamlcc_arc_reuse(int64_t unit)
{
    (void)unit;
    return tag_int(arc_reuse_hits());
}

int64_t ocamlcc_arc_slab_count(int64_t unit)
{
    (void)unit;
    return tag_int(atomic_load_explicit(&g_active_slabs, memory_order_relaxed));
}

Finalizer *finalizers; /* newest first, protected by g_cc_lock */
static Finalizer *last_finalizers; /* protected by g_weak_lock */
static Finalizer *pending_finalizers; /* owned by the active dispatcher */
/* READY publishes a nonempty queue from a callback that released dispatch.
 * A taker may deliver those registrations without a successful new trial. */
enum DispatchState { DISPATCH_IDLE, DISPATCH_ACTIVE, DISPATCH_READY };
static _Atomic enum DispatchState finalizer_dispatch;
/* Includes registrations already claimed by a dispatcher. */
/* Generated code reads this count to bypass automatic polls on idle paths. */
_Atomic uint64_t ocamlcc_finalizer_count;
_Atomic uint32_t ocamlcc_automatic_finalizer_raised;
static _Atomic uint64_t last_finalizer_poll;

void append_pending(Finalizer *ready)
{
    if (ready == NULL)
        return;
    /* Exceptions may have left earlier callbacks pending. */
    Finalizer **end = &pending_finalizers;
    while (*end != NULL)
        end = &(*end)->next;
    *end = ready;
}

/* ------------------------------------------------------------------ */
/* Predefined OCaml exception constructors (process-wide singletons)   */
/* ------------------------------------------------------------------ */

#define DEFINE_PREDEF_EXN(name, uid)                                         \
    static const struct __attribute__((aligned(16))) {                       \
        ArcHeader hdr;                                                       \
        char str[sizeof(#name)];                                             \
    } g_predef_str_##name = {                                                \
        { ARC_IMMORTAL, (uint16_t)ARC_TAG_STRING, 0u,                        \
          (uint32_t)sizeof(#name), (uint32_t)(sizeof(#name) - 1u) },         \
        #name                                                                \
    };                                                                       \
    static const struct __attribute__((aligned(16))) {                       \
        ArcHeader hdr;                                                       \
        const void *fields[2];                                               \
    } g_predef_exn_##name = {                                                \
        { ARC_IMMORTAL, 248u, 1u, 16u, 0u },                                 \
        { g_predef_str_##name.str,                                           \
          (const void *)(uintptr_t)(((uint64_t)(-(int64_t)(uid)) << 1) | 1u) } \
    };                                                                       \
    const void *ocamlcc_global_##name = g_predef_exn_##name.fields;          \
    void ocamlcc_init_##name(void) {}

DEFINE_PREDEF_EXN(Match_failure, 1)
DEFINE_PREDEF_EXN(Out_of_memory, 2)
DEFINE_PREDEF_EXN(Invalid_argument, 3)
DEFINE_PREDEF_EXN(Failure, 4)
DEFINE_PREDEF_EXN(Not_found, 5)
DEFINE_PREDEF_EXN(Sys_error, 6)
DEFINE_PREDEF_EXN(End_of_file, 7)
DEFINE_PREDEF_EXN(Division_by_zero, 8)
DEFINE_PREDEF_EXN(Stack_overflow, 9)
DEFINE_PREDEF_EXN(Sys_blocked_io, 10)
DEFINE_PREDEF_EXN(Assert_failure, 11)
DEFINE_PREDEF_EXN(Undefined_recursive_module, 12)

static ArcSpinLock g_gc_ctrl_lock = { 0u };
static _Atomic int64_t g_gc_ctrl[11] = {
    262144, 0, 120, 0, 500, 134217728, 0, 0, 44, 100, 70000
};

int64_t caml_gc_minor_words(int64_t ignored)
{
    (void)ignored;
    uint64_t w = atomic_load_explicit(&g_alloc_words, memory_order_relaxed);
    return ocamlcc_alloc_float((double)w);
}

int64_t caml_gc_counters(int64_t ignored)
{
    (void)ignored;
    double w = (double)atomic_load_explicit(&g_alloc_words, memory_order_relaxed);
    int64_t *tup = (int64_t *)arc_alloc(0u, 3u, 24u);
    tup[0] = ocamlcc_alloc_float(w);
    tup[1] = ocamlcc_alloc_float(0.0);
    tup[2] = ocamlcc_alloc_float(0.0);
    return (int64_t)(uintptr_t)tup;
}

int64_t caml_gc_quick_stat(int64_t ignored)
{
    (void)ignored;
    double words = (double)atomic_load_explicit(&g_alloc_words, memory_order_relaxed);
    int64_t cols = atomic_load_explicit(&g_gc_collections, memory_order_relaxed);
    int64_t live = atomic_load_explicit(&g_live_objects, memory_order_relaxed);
    int64_t slabs = atomic_load_explicit(&g_active_slabs, memory_order_relaxed);
    int64_t heap_w = slabs * (int64_t)(SLAB_SIZE / 8u);
    int64_t *st = (int64_t *)arc_alloc(0u, 18u, 18u * 8u);
    st[0] = ocamlcc_alloc_float(words); /* minor_words */
    st[1] = ocamlcc_alloc_float(0.0);   /* promoted_words */
    st[2] = ocamlcc_alloc_float(0.0);   /* major_words */
    st[3] = tag_int(cols);              /* minor_collections */
    st[4] = tag_int(cols);              /* major_collections */
    st[5] = tag_int(heap_w);            /* heap_words */
    st[6] = tag_int(0);                 /* heap_chunks */
    st[7] = tag_int(live * 2);          /* live_words */
    st[8] = tag_int(live);              /* live_blocks */
    st[9] = tag_int(0);                 /* free_words */
    st[10] = tag_int(0);                /* free_blocks */
    st[11] = tag_int(0);                /* largest_free */
    st[12] = tag_int(0);                /* fragments */
    st[13] = tag_int(cols);             /* compactions */
    st[14] = tag_int(heap_w);           /* top_heap_words */
    st[15] = tag_int(0);                /* stack_size */
    st[16] = tag_int(cols);             /* forced_major_collections */
    st[17] = tag_int(0);                /* live_stacks_words */
    return (int64_t)(uintptr_t)st;
}

int64_t caml_gc_stat(int64_t ignored)
{
    (void)ignored;
    (void)ocamlcc_arc_collect(1);
    atomic_fetch_add_explicit(&g_gc_collections, 1, memory_order_relaxed);
    return caml_gc_quick_stat(1);
}

int64_t caml_gc_get(int64_t ignored)
{
    (void)ignored;
    int64_t *c = (int64_t *)arc_alloc(0u, 11u, 11u * 8u);
    arc_lock(&g_gc_ctrl_lock);
    for (int i = 0; i < 11; i++)
        c[i] = tag_int(atomic_load_explicit(&g_gc_ctrl[i], memory_order_relaxed));
    arc_unlock(&g_gc_ctrl_lock);
    return (int64_t)(uintptr_t)c;
}

int64_t caml_gc_set(int64_t ctrl_val)
{
    const int64_t *c = (const int64_t *)(uintptr_t)ctrl_val;
    arc_lock(&g_gc_ctrl_lock);
    for (int i = 0; i < 11; i++)
        atomic_store_explicit(&g_gc_ctrl[i], c[i] >> 1, memory_order_relaxed);
    arc_unlock(&g_gc_ctrl_lock);
    return 1;
}

int64_t caml_gc_minor(int64_t ignored)
{
    (void)ignored;
    (void)ocamlcc_arc_collect(1);
    atomic_fetch_add_explicit(&g_gc_collections, 1, memory_order_relaxed);
    return 1;
}

int64_t caml_gc_major_slice(int64_t n_val)
{
    (void)n_val;
    (void)ocamlcc_arc_collect(1);
    return tag_int(0);
}

/* Weak clearing is synchronized with ARC destruction and in-place reuse.
 * A cleared slot can never alias the next occupant of the same address. */
static void claim_last_finalizers(void)
{
    Finalizer *ready = NULL;
    Finalizer **tail = &ready;
    arc_lock(&g_weak_lock);
    for (Finalizer **link = &last_finalizers; *link != NULL;) {
        Finalizer *f = *link;
        ArcWeakArray *weak = (ArcWeakArray *)(uintptr_t)f->value;
        if (weak->slots[0] == 0) {
            *link = f->next;
            *tail = f;
            tail = &f->next;
        } else {
            link = &f->next;
        }
    }
    *tail = NULL;
    arc_unlock(&g_weak_lock);
    append_pending(ready);
}

static uint64_t allocation_progress(void)
{
    return atomic_load_explicit(&g_alloc_words, memory_order_relaxed) +
           (uint64_t)atomic_load_explicit(&g_reuse_hits, memory_order_relaxed);
}

static inline int has_finalizers(void)
{
    return atomic_load_explicit(&ocamlcc_finalizer_count, memory_order_relaxed) != 0;
}

static int finalizer_budget_due(void)
{
    uint64_t previous = atomic_load_explicit(&last_finalizer_poll, memory_order_acquire);
    int64_t budget = atomic_load_explicit(&g_gc_ctrl[0], memory_order_relaxed);
    return allocation_progress() - previous >= (uint64_t)(budget > 0 ? budget : 1);
}

int64_t ocamlcc_finalizers_due(void)
{
    /* Pending registrations stay counted through dispatch. An empty
       registry can skip both the dispatch state and allocation budget. */
    if (!has_finalizers())
        return 1;
    enum DispatchState state = atomic_load_explicit(&finalizer_dispatch, memory_order_relaxed);
    return tag_int(state == DISPATCH_READY ||
                   (state == DISPATCH_IDLE && finalizer_budget_due()));
}

static int64_t run_finalizers(int automatic)
{
    if (ocamlcc_get_exn() != 0)
        return automatic ? 1 : caml_gc_minor(1);
    enum DispatchState prior = atomic_exchange_explicit(&finalizer_dispatch, DISPATCH_ACTIVE,
                                                        memory_order_acquire);
    if (prior == DISPATCH_ACTIVE)
        return automatic ? 1 : caml_gc_minor(1);

    /* With a handed-off queue the previous callback may still be waiting
     * inside the mutator gate. Enter before trying a collection so that a
     * competing mutator causes the trial to skip instead of waiting on it. */
    int entered = prior == DISPATCH_READY ? arc_mutator_enter() : 0;
    int due = !automatic || (has_finalizers() && finalizer_budget_due());
    int collected = due && collect_cycles(1) >= 0;
    if (!collected && prior != DISPATCH_READY) {
        atomic_store_explicit(&finalizer_dispatch, DISPATCH_IDLE, memory_order_release);
        return 1;
    }
    if (prior != DISPATCH_READY)
        entered = arc_mutator_enter();
    if (collected) {
        atomic_fetch_add_explicit(&g_gc_collections, 1, memory_order_relaxed);
        claim_last_finalizers();
    }
    Fiber *fiber = arc_fiber_current();
    while (pending_finalizers != NULL) {
        Finalizer *f = pending_finalizers;
        pending_finalizers = f->next;
        /* A compiled unary function consumes its argument. Transfer this
         * registration's pin and keep the borrowed callback alive across it. */
        fiber->owns_finalizer_dispatch = 1;
        int64_t result = ocamlcc_apply1_raw(f->callback, f->last ? 1 : f->value);
        if (f->last)
            arc_release_val(f->value);
        arc_release_val(result);
        arc_release_val(f->callback);
        arc_release(f);
        atomic_fetch_sub_explicit(&ocamlcc_finalizer_count, 1, memory_order_relaxed);
        int raised = ocamlcc_get_exn() != 0;
        /* A caller can skip its TLS check until an automatic callback
         * propagates an exception, even if that callback was the last one. */
        if (automatic && raised)
            atomic_store_explicit(&ocamlcc_automatic_finalizer_raised, 1, memory_order_relaxed);
        /* A released callback still owns its local registration. Only the
         * dispatcher that holds the queue may read it or clear its gate. */
        if (!fiber->owns_finalizer_dispatch &&
            atomic_exchange_explicit(&finalizer_dispatch, DISPATCH_ACTIVE,
                                     memory_order_acquire) == DISPATCH_ACTIVE) {
            arc_mutator_leave(entered);
            return 1;
        }
        fiber->owns_finalizer_dispatch = 0;
        if (raised)
            break;
    }
    if (collected)
        atomic_store_explicit(&last_finalizer_poll, allocation_progress(), memory_order_release);
    arc_mutator_leave(entered);
    atomic_store_explicit(&finalizer_dispatch,
                          pending_finalizers != NULL ? DISPATCH_READY : DISPATCH_IDLE,
                          memory_order_release);
    return 1;
}

int64_t caml_gc_major(int64_t ignored)
{
    (void)ignored;
    return run_finalizers(0);
}

int64_t ocamlcc_poll_finalizers(void)
{
    return run_finalizers(1);
}

int64_t caml_gc_full_major(int64_t ignored)
{
    return caml_gc_major(ignored);
}

int64_t caml_gc_compaction(int64_t ignored)
{
    return caml_gc_major(ignored);
}

int64_t caml_get_minor_free(int64_t ignored)
{
    (void)ignored;
    return tag_int(262144);
}

static int64_t register_finalizer(int64_t fn, int64_t v, int last)
{
    ArcHeader *target = is_heap_ptr(v) ? (ArcHeader *)(uintptr_t)v - 1 : NULL;
    if (target == NULL || target->tag == ARC_TAG_FLOAT ||
        target->tag == ARC_TAG_LAZY || target->tag == ARC_TAG_FORWARD ||
        target->tag == ARC_TAG_FORCING || target->byte_size == 0) {
        raise_invalid_arg_imm(g_inv_arg_finalise.str);
        return 1;
    }
    Finalizer *f = arc_alloc(0, 0, sizeof(*f));
    arc_retain_val(fn);
    f->callback = fn;
    f->last = last;
    atomic_fetch_add_explicit(&ocamlcc_finalizer_count, 1, memory_order_relaxed);
    if (last) {
        f->value = ocamlcc_weak_create(tag_int(1));
        ArcWeakArray *weak = (ArcWeakArray *)(uintptr_t)f->value;
        arc_lock(&g_weak_lock);
        weak->slots[0] = v;
        weak_targets_insert(v);
        f->next = last_finalizers;
        last_finalizers = f;
        arc_unlock(&g_weak_lock);
    } else {
        arc_retain_val(v);
        f->value = v;
        arc_lock(&g_cc_lock);
        f->next = finalizers;
        finalizers = f;
        arc_unlock(&g_cc_lock);
    }
    return 1;
}

int64_t caml_final_register(int64_t fn, int64_t v)
{
    return register_finalizer(fn, v, 0);
}

int64_t caml_final_register_called_without_value(int64_t fn, int64_t v)
{
    return register_finalizer(fn, v, 1);
}

int64_t caml_final_release(int64_t ignored)
{
    (void)ignored;
    Fiber *fiber = arc_fiber_current();
    if (fiber->owns_finalizer_dispatch) {
        fiber->owns_finalizer_dispatch = 0;
        enum DispatchState next = pending_finalizers != NULL ? DISPATCH_READY : DISPATCH_IDLE;
        atomic_store_explicit(&finalizer_dispatch, next, memory_order_release);
    }
    return 1;
}
