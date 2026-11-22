/* Bacon–Rajan trial deletion and cycle-root management. */
#include "arc_internal.h"

ArcSpinLock g_cc_lock = { 0u };
static ArcSpinLock g_cc_collect_lock = { 0u };
_Atomic int g_cc_active = 0;
static CCVec g_cc_roots = { NULL, 0, 0, 0 };

void ccvec_push(CCVec *v, ArcHeader *h)
{
    if (v->len == v->cap) {
        size_t new_bytes =
            (v->alloc_bytes == 0u) ? (size_t)LARGE_PAGE_ALIGN : (v->alloc_bytes * 2u);
        ArcHeader **nd = (ArcHeader **)pal_page_alloc(new_bytes);
        if (nd == NULL)
            pal_abort();
        if (v->data != NULL) {
            pal_memcpy(nd, v->data, v->len * sizeof(ArcHeader *));
            pal_page_free(v->data, v->alloc_bytes);
        }
        v->data = nd;
        v->alloc_bytes = new_bytes;
        v->cap = new_bytes / sizeof(ArcHeader *);
    }
    v->data[v->len++] = h;
}

void ccvec_free(CCVec *v)
{
    if (v->data != NULL) {
        pal_page_free(v->data, v->alloc_bytes);
        v->data = NULL;
        v->len = 0;
        v->cap = 0;
        v->alloc_bytes = 0;
    }
}

__attribute__((noinline)) void cc_roots_add_slow(ArcHeader *hdr)
{
    arc_lock(&g_cc_lock);
    if ((atomic_load_explicit(&hdr->reserved, memory_order_relaxed) & CC_BUFFERED) != 0u) {
        arc_unlock(&g_cc_lock);
        return;
    }
    if (g_cc_roots.len >= CC_MAX_ROOTS) {
        arc_unlock(&g_cc_lock);
        return;
    }
    uint32_t idx = (uint32_t)g_cc_roots.len;
    ccvec_push(&g_cc_roots, hdr);
    atomic_store_explicit(
        &hdr->reserved,
        (atomic_load_explicit(&hdr->reserved, memory_order_relaxed) & CC_COLOR_MASK) |
            CC_BUFFERED | (idx << CC_INDEX_SHIFT),
        memory_order_relaxed);
    arc_unlock(&g_cc_lock);
}

void cc_roots_remove_locked(ArcHeader *hdr)
{
    uint32_t state = atomic_load_explicit(&hdr->reserved, memory_order_relaxed);
    if ((state & CC_BUFFERED) == 0u || !is_cycle_candidate_obj(hdr))
        return;
    uint32_t idx = state >> CC_INDEX_SHIFT;
    uint32_t last = (uint32_t)--g_cc_roots.len;
    if (idx != last) {
        ArcHeader *moved = g_cc_roots.data[last];
        g_cc_roots.data[idx] = moved;
        /* release_subtree reads reserved lock-free on other threads, so this
         * swap-move rewrite must be an atomic store to stay C11-defined. */
        atomic_store_explicit(
            &moved->reserved,
            (atomic_load_explicit(&moved->reserved, memory_order_relaxed) & CC_COLOR_MASK) |
                CC_BUFFERED | (idx << CC_INDEX_SHIFT),
            memory_order_relaxed);
    }
    atomic_fetch_and_explicit(&hdr->reserved, CC_COLOR_MASK, memory_order_relaxed);
}

void cc_visit_children(ArcHeader *hdr, CcChildFn fn, void *ctx)
{
    uint16_t tag = hdr->tag;
    if (tag == (uint16_t)ARC_TAG_CLOSURE) {
        ArcClosure *c = (ArcClosure *)(hdr + 1);
        uint32_t n = arc_scan_count(hdr);
        for (uint32_t i = 0; i < n; i++)
            fn((int64_t)c->env[i], ctx);
    } else if (tag == (uint16_t)ARC_TAG_PAP) {
        ArcPap *p = (ArcPap *)(hdr + 1);
        fn((int64_t)(uintptr_t)p->orig, ctx);
        uint64_t n = p->n_applied;
        for (uint64_t i = 0; i < n; i++)
            fn(p->args[i], ctx);
    } else if (tag == (uint16_t)ARC_TAG_ARRAY) {
        int64_t *arr = (int64_t *)(hdr + 1);
        uint32_t n = array_pointer_slots(hdr);
        for (uint32_t i = 0; i < n; i++)
            fn(arr[i], ctx);
    } else if (tag == (uint16_t)ARC_TAG_FIBER) {
        fiber_visit_owned_values((Fiber *)(hdr + 1), fn, ctx);
    } else if (!is_unscanned_leaf_tag(tag)) {
        int64_t *fields = (int64_t *)(hdr + 1);
        uint32_t n = arc_scan_count(hdr);
        for (uint32_t i = 0; i < n; i++)
            fn(fields[i], ctx);
    }
}

static ArcHeader *cc_trial_child(int64_t val, int include_leaves)
{
    if (!is_heap_ptr(val))
        return NULL;
    ArcHeader *chdr = (ArcHeader *)(uintptr_t)val - 1;
    if (include_leaves)
        return atomic_load_explicit(&chdr->refcount, memory_order_relaxed) == ARC_IMMORTAL
            ? NULL : chdr;
    return is_cycle_candidate_obj(chdr) ? chdr : NULL;
}

typedef struct TrialEntry {
    ArcHeader *hdr;
    int64_t    rc;
    uint32_t   color;
} TrialEntry;

typedef struct TrialMap {
    TrialEntry *entries;
    size_t      cap;
    size_t      len;
    size_t      alloc_bytes;
    int         include_leaves;
} TrialMap;

static inline size_t trial_hash(const ArcHeader *h)
{
    uint64_t x = (uint64_t)(uintptr_t)h;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return (size_t)x;
}

static void trial_grow(TrialMap *tm)
{
    size_t new_cap = (tm->cap == 0u) ? 256u : (tm->cap * 2u);
    size_t new_bytes =
        (new_cap * sizeof(TrialEntry) + (size_t)LARGE_PAGE_ALIGN - 1u) &
        ~((size_t)LARGE_PAGE_ALIGN - 1u);
    new_cap = new_bytes / sizeof(TrialEntry);
    TrialEntry *ne = (TrialEntry *)pal_page_alloc(new_bytes);
    if (ne == NULL)
        pal_abort();
    pal_memset(ne, 0, new_bytes);
    if (tm->entries != NULL) {
        for (size_t i = 0; i < tm->cap; i++) {
            if (tm->entries[i].hdr != NULL) {
                size_t j = trial_hash(tm->entries[i].hdr) % new_cap;
                while (ne[j].hdr != NULL)
                    j = (j + 1u) % new_cap;
                ne[j] = tm->entries[i];
            }
        }
        pal_page_free(tm->entries, tm->alloc_bytes);
    }
    tm->entries = ne;
    tm->cap = new_cap;
    tm->alloc_bytes = new_bytes;
}

static TrialEntry *trial_get(TrialMap *tm, ArcHeader *h)
{
    if (tm->entries == NULL || (tm->len + 1u) * 3u > tm->cap * 2u)
        trial_grow(tm);
    /* Page-rounded capacity may not be a power of two. Use the same
       probing rule during lookup and rehash. */
    size_t cap = tm->cap;
    size_t j = trial_hash(h) % cap;
    while (tm->entries[j].hdr != NULL) {
        if (tm->entries[j].hdr == h)
            return &tm->entries[j];
        j = (j + 1u) % cap;
    }
    tm->entries[j].hdr = h;
    tm->entries[j].rc =
        (int64_t)atomic_load_explicit(&h->refcount, memory_order_acquire);
    tm->entries[j].color = CC_COLOR_BLACK;
    tm->len++;
    return &tm->entries[j];
}

static void trial_free(TrialMap *tm)
{
    if (tm->entries != NULL) {
        pal_page_free(tm->entries, tm->alloc_bytes);
        tm->entries = NULL;
        tm->cap = 0;
        tm->len = 0;
        tm->alloc_bytes = 0;
    }
}

typedef struct CCTrialCtx {
    TrialMap *tm;
    CCVec    *work;
} CCTrialCtx;

static void cc_mark_gray_cb(int64_t val, void *ctx)
{
    CCTrialCtx *tc = (CCTrialCtx *)ctx;
    ArcHeader *chdr = cc_trial_child(val, tc->tm->include_leaves);
    if (chdr == NULL)
        return;
    TrialEntry *e = trial_get(tc->tm, chdr);
    e->rc--;
    if (e->color != CC_COLOR_GRAY) {
        e->color = CC_COLOR_GRAY;
        ccvec_push(tc->work, chdr);
    }
}

static void cc_mark_gray(TrialMap *tm, CCVec *work, ArcHeader *start)
{
    TrialEntry *se = trial_get(tm, start);
    se->color = CC_COLOR_GRAY;
    ccvec_push(work, start);
    CCTrialCtx tc = { tm, work };
    while (work->len > 0u) {
        ArcHeader *cur = work->data[--work->len];
        cc_visit_children(cur, cc_mark_gray_cb, &tc);
    }
}

static void cc_scan_black_cb(int64_t val, void *ctx)
{
    CCTrialCtx *tc = (CCTrialCtx *)ctx;
    ArcHeader *chdr = cc_trial_child(val, tc->tm->include_leaves);
    if (chdr == NULL)
        return;
    TrialEntry *e = trial_get(tc->tm, chdr);
    e->rc++;
    if (e->color != CC_COLOR_BLACK) {
        e->color = CC_COLOR_BLACK;
        ccvec_push(tc->work, chdr);
    }
}

static void cc_scan_black(TrialMap *tm, CCVec *work, ArcHeader *start)
{
    TrialEntry *se = trial_get(tm, start);
    se->color = CC_COLOR_BLACK;
    ccvec_push(work, start);
    CCTrialCtx tc = { tm, work };
    while (work->len > 0u) {
        ArcHeader *cur = work->data[--work->len];
        cc_visit_children(cur, cc_scan_black_cb, &tc);
    }
}

static void cc_scan_cb(int64_t val, void *ctx)
{
    CCTrialCtx *tc = (CCTrialCtx *)ctx;
    ArcHeader *chdr = cc_trial_child(val, tc->tm->include_leaves);
    if (chdr == NULL)
        return;
    TrialEntry *e = trial_get(tc->tm, chdr);
    if (e->color == CC_COLOR_GRAY)
        ccvec_push(tc->work, chdr);
}

static void cc_scan(TrialMap *tm, CCVec *scan_work, CCVec *black_work,
                    ArcHeader *start)
{
    if (trial_get(tm, start)->color != CC_COLOR_GRAY)
        return;
    ccvec_push(scan_work, start);
    CCTrialCtx tc = { tm, scan_work };
    while (scan_work->len > 0u) {
        ArcHeader *cur = scan_work->data[--scan_work->len];
        TrialEntry *e = trial_get(tm, cur);
        if (e->color != CC_COLOR_GRAY)
            continue;
        if (e->rc > 0) {
            cc_scan_black(tm, black_work, cur);
        } else {
            e->color = CC_COLOR_WHITE;
            cc_visit_children(cur, cc_scan_cb, &tc);
        }
    }
}

typedef struct CCWhiteCtx {
    TrialMap *tm;
    CCVec    *work;
    CCVec    *dead;
} CCWhiteCtx;

static void cc_collect_white_cb(int64_t val, void *ctx)
{
    ArcHeader *chdr = cc_trial_child(val, 0);
    if (chdr == NULL)
        return;
    CCWhiteCtx *wc = (CCWhiteCtx *)ctx;
    TrialEntry *e = trial_get(wc->tm, chdr);
    if (e->color == CC_COLOR_WHITE) {
        e->color = CC_COLOR_DEAD;
        ccvec_push(wc->work, chdr);
        ccvec_push(wc->dead, chdr);
    }
}

static void cc_collect_white(TrialMap *tm, CCVec *work, CCVec *dead,
                             ArcHeader *start)
{
    TrialEntry *se = trial_get(tm, start);
    if (se->color != CC_COLOR_WHITE)
        return;
    CCWhiteCtx wc = { tm, work, dead };
    se->color = CC_COLOR_DEAD;
    ccvec_push(work, start);
    ccvec_push(dead, start);
    while (work->len > 0u) {
        ArcHeader *cur = work->data[--work->len];
        cc_visit_children(cur, cc_collect_white_cb, &wc);
    }
}

static void finalizers_mark(TrialMap *tm, CCVec *work)
{
    for (Finalizer *f = finalizers; f != NULL; f = f->next) {
        TrialEntry *e = trial_get(tm, finalizer_target(f));
        e->rc--;
        if (e->color == CC_COLOR_BLACK)
            cc_mark_gray(tm, work, finalizer_target(f));
    }
}

/* Preserve registration order in the ready list. Snapshot eligibility for
 * every target before restoring any pins, including targets in one cycle. */
static void finalizers_claim(TrialMap *tm, CCVec *work, CCVec *black_work)
{
    for (Finalizer *f = finalizers; f != NULL; f = f->next)
        cc_scan(tm, work, black_work, finalizer_target(f));

    Finalizer *ready = NULL;
    Finalizer **tail = &ready;
    for (Finalizer **link = &finalizers; *link != NULL;) {
        Finalizer *f = *link;
        if (trial_get(tm, finalizer_target(f))->color == CC_COLOR_WHITE) {
            *link = f->next;
            *tail = f;
            tail = &f->next;
        } else {
            link = &f->next;
        }
    }
    *tail = NULL;
    for (Finalizer *f = ready; f != NULL; f = f->next) {
        if (trial_get(tm, finalizer_target(f))->color == CC_COLOR_WHITE)
            cc_scan_black(tm, black_work, finalizer_target(f));
    }
    append_pending(ready);
}

typedef struct { TrialMap *tm; CCVec *values; } OutgoingEdges;

static void cc_collect_outgoing_cb(int64_t val, void *ctx)
{
    if (!is_heap_ptr(val))
        return;
    ArcHeader *chdr = (ArcHeader *)(uintptr_t)val - 1;
    if (atomic_load_explicit(&chdr->refcount, memory_order_relaxed) == ARC_IMMORTAL)
        return;
    OutgoingEdges *out = ctx;
    if (!is_cycle_candidate_obj(chdr) || trial_get(out->tm, chdr)->color != CC_COLOR_DEAD)
        ccvec_push(out->values, (ArcHeader *)(uintptr_t)val);
}

/* Number reclaimed, or -1 when another mutator prevents a trial. */
int64_t collect_cycles(int discover_finalizers)
{
    check_rc_thread();
    if (tls_os_mutator_active != 0) {
        /* Inside an active FFI mutator call: never block on g_cc_collect_lock
           (an external collector may hold it waiting for us to exit), and
           skip if other FFI mutator threads are active. */
        if (!arc_trylock(&g_cc_collect_lock))
            return -1;
    } else {
        arc_lock(&g_cc_collect_lock);
    }

    atomic_store_explicit(&g_cc_waiting, 1, memory_order_seq_cst);
    if (tls_os_mutator_active != 0) {
        if (atomic_load_explicit(&g_active_mutators, memory_order_seq_cst) > 1) {
            atomic_store_explicit(&g_cc_waiting, 0, memory_order_release);
            arc_unlock(&g_cc_collect_lock);
            return -1;
        }
    } else {
        while (atomic_load_explicit(&g_active_mutators, memory_order_seq_cst) > 0)
            cpu_relax();
    }

    arc_lock(&g_cc_lock);
    if (g_cc_roots.len == 0u && !(discover_finalizers && finalizers != NULL)) {
        arc_unlock(&g_cc_lock);
        atomic_store_explicit(&g_cc_waiting, 0, memory_order_release);
        arc_unlock(&g_cc_collect_lock);
        return 0;
    }

    atomic_store_explicit(&g_cc_active, 1, memory_order_release);

    TrialMap tm = {0};
    /* The normal cycle trial omits leaves. A registered leaf can also be
     * unreachable via a dying parent, so account for incoming edges to
     * leaves during discovery. The sweep still reclaims them by ARC. */
    if (discover_finalizers) {
        for (Finalizer *f = finalizers; f != NULL; f = f->next) {
            if (!is_cycle_candidate_obj(finalizer_target(f))) {
                tm.include_leaves = 1;
                break;
            }
        }
    }
    CCVec work = { NULL, 0, 0, 0 };
    CCVec black_work = { NULL, 0, 0, 0 };
    CCVec dead = { NULL, 0, 0, 0 };
    CCVec leaves = { NULL, 0, 0, 0 };

    for (size_t i = 0; i < g_cc_roots.len; i++) {
        ArcHeader *r = g_cc_roots.data[i];
        if (trial_get(&tm, r)->color == CC_COLOR_BLACK)
            cc_mark_gray(&tm, &work, r);
    }

    if (discover_finalizers)
        finalizers_mark(&tm, &work);

    for (size_t i = 0; i < g_cc_roots.len; i++)
        cc_scan(&tm, &work, &black_work, g_cc_roots.data[i]);

    if (discover_finalizers)
        finalizers_claim(&tm, &work, &black_work);

    for (size_t i = 0; i < g_cc_roots.len; i++) {
        ArcHeader *r = g_cc_roots.data[i];
        if (trial_get(&tm, r)->color == CC_COLOR_WHITE)
            cc_collect_white(&tm, &work, &dead, r);
        atomic_fetch_and_explicit(&r->reserved, CC_COLOR_MASK, memory_order_relaxed);
    }
    g_cc_roots.len = 0;

    OutgoingEdges outgoing = { &tm, &leaves };
    for (size_t i = 0; i < dead.len; i++) {
        ArcHeader *w = dead.data[i];
        if (might_be_weak_target(w))
            clear_weak_target(w);
        if (w->tag == ARC_TAG_FIBER)
            fiber_collect_dead((Fiber *)(w + 1), cc_collect_outgoing_cb, &outgoing);
        else
            cc_visit_children(w, cc_collect_outgoing_cb, &outgoing);
    }

    atomic_store_explicit(&g_cc_active, 0, memory_order_release);
    arc_unlock(&g_cc_lock);

    defer_foreign_releases();
    for (size_t i = 0; i < leaves.len; i++)
        arc_release((void *)leaves.data[i]);
    for (size_t i = 0; i < dead.len; i++) {
        account_objects(&g_live_objects, -1);
        slab_free(dead.data[i]);
    }

    int64_t reclaimed = (int64_t)dead.len;
    atomic_store_explicit(&g_cc_waiting, 0, memory_order_release);
    arc_unlock(&g_cc_collect_lock);
    trial_free(&tm);
    ccvec_free(&work);
    ccvec_free(&black_work);
    ccvec_free(&dead);
    ccvec_free(&leaves);
    resume_foreign_releases();
    return reclaimed;
}

int64_t ocamlcc_arc_collect(int64_t unit)
{
    (void)unit;
    int64_t reclaimed = collect_cycles(0);
    return tag_int(reclaimed < 0 ? 0 : reclaimed);
}
