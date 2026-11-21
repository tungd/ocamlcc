/* arc.c — freestanding slab allocator, O(1)-stack tail-drop ARC, and
 * Perceus reuse over ArcHeader (design doc §4.2).
 *
 * Uses pal_page_alloc / pal_page_free directly with no libc heap calls. */
#include "arc.h"
#include "ocamlcc_bigarray.h"

#include "fiber.h"
#include "pal.h"

#ifndef OCAMLCC_SINGLE_THREAD_RC
#include <pthread.h>
#endif

#define SLAB_SIZE        (64u * 1024u)
#define LARGE_PAGE_ALIGN (16u * 1024u)
#define NUM_SIZE_CLASSES 12
#define LOCAL_DROP_CAP   256u
#define DROP_PAGE_SIZE   (16u * 1024u)
#define DROP_PAGE_CAP    ((DROP_PAGE_SIZE - sizeof(void *)) / sizeof(ArcHeader *))

static const uint32_t k_class_sizes[NUM_SIZE_CLASSES] = {
    16u, 32u, 48u, 64u, 96u, 128u, 192u, 256u, 384u, 512u, 1024u, 2048u
};

typedef struct FreeSlot {
    struct FreeSlot *next;
} FreeSlot;

typedef struct DropPage {
    struct DropPage *prev;
    ArcHeader *items[1];
} DropPage;

typedef struct ArcWeakArray {
    struct ArcWeakArray *prev;
    struct ArcWeakArray *next;
    uint64_t             len;
    int64_t              slots[];
} ArcWeakArray;

extern void ocamlcc_c_mutex_free(void *p);
extern void ocamlcc_c_cond_free(void *c);

typedef struct ForeignRelease {
    OcamlccBigarrayRelease release;
    void *base;
    void *context;
    struct ForeignRelease *next;
} ForeignRelease;

typedef struct ArcBigarrayBuffer {
    uint8_t *data;
    size_t bytes;
    ForeignRelease *owner;
} ArcBigarrayBuffer;

typedef struct OcamlccBigarrayView {
    ArcBigarrayBuffer *backing;
    const void *runtime_id; /* distinguish independently linked ARC heaps */
    uint8_t *data;
    int ndims, kind, layout;
    int64_t dims[16];
} ArcBigarray;

static int ba_compare(const ArcBigarray *, const ArcBigarray *, int);
static uint32_t ba_hash(const ArcBigarray *);

typedef struct ArcSpinLock {
    _Atomic uint32_t locked;
} ArcSpinLock;

static inline void cpu_relax(void)
{
#if defined(__aarch64__)
    __asm__ volatile("yield" ::: "memory");
#elif defined(__x86_64__)
    __asm__ volatile("pause" ::: "memory");
#endif
}

static inline void arc_lock(ArcSpinLock *l)
{
    while (atomic_exchange_explicit(&l->locked, 1u, memory_order_acquire) != 0u) {
        while (atomic_load_explicit(&l->locked, memory_order_relaxed) != 0u)
            cpu_relax();
    }
}

static inline void arc_unlock(ArcSpinLock *l)
{
    atomic_store_explicit(&l->locked, 0u, memory_order_release);
}

static inline int arc_trylock(ArcSpinLock *l)
{
    return atomic_exchange_explicit(&l->locked, 1u, memory_order_acquire) == 0u;
}

#ifndef OCAMLCC_SINGLE_THREAD_RC
static ArcSpinLock g_alloc_lock = { 0u };
#endif

static inline void slab_lock(void)
{
#ifndef OCAMLCC_SINGLE_THREAD_RC
    arc_lock(&g_alloc_lock);
#endif
}

static inline void slab_unlock(void)
{
#ifndef OCAMLCC_SINGLE_THREAD_RC
    arc_unlock(&g_alloc_lock);
#endif
}

static ArcSpinLock g_weak_lock = { 0u };
static ArcSpinLock g_cc_lock = { 0u };
static ArcSpinLock g_cc_collect_lock = { 0u };
static _Atomic int g_cc_active = 0;
static _Atomic int g_cc_waiting = 0;
static _Atomic int g_active_mutators = 0;
static _Thread_local int tls_os_mutator_active = 0;
static _Thread_local ForeignRelease *pending_foreign_releases;
static _Thread_local unsigned foreign_release_depth;

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
static _Atomic unsigned g_rc_owner_claimed;
static _Thread_local int tls_rc_owner;
#endif

static inline void check_rc_thread(void)
{
#ifdef OCAMLCC_SINGLE_THREAD_RC
    if (tls_rc_owner)
        return;

    if (atomic_exchange_explicit(&g_rc_owner_claimed, 1u, memory_order_relaxed)) {
        static const char message[] =
            "ocamlcc: single-thread ARC runtime entered from another thread\n";
        pal_stderr_write(message, sizeof(message) - 1);
        pal_abort();
    }
    tls_rc_owner = 1;
#endif
}

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

typedef struct SlabPage {
    struct SlabPage *prev;
    struct SlabPage *next;
    FreeSlot        *free_list;
    uint32_t         cls;
    uint32_t         used_slots;
    uint32_t         bump_off;
    uint32_t         is_full;
    uint64_t         _pad;
} SlabPage;

_Static_assert((SLAB_SIZE & (SLAB_SIZE - 1u)) == 0u,
               "Slab lookup requires power-of-two alignment");
_Static_assert((sizeof(SlabPage) % 16u) == 0u,
               "SlabPage header must preserve 16-byte slot alignment");

static SlabPage  *g_partial_slabs[NUM_SIZE_CLASSES];
static SlabPage  *g_full_slabs[NUM_SIZE_CLASSES];
static uint32_t   g_class_slab_count[NUM_SIZE_CLASSES];

static ArcWeakArray     *g_weak_head = NULL;
static _Atomic uint64_t  g_weak_count = 0;

/* Opt-in Bacon-Rajan trial-deletion cycle collector state.
 * For cycle candidates (is_cycle_candidate_obj), ArcHeader.reserved encodes:
 *   bits [1:0]  : color (0 = black, 1 = gray, 2 = white, 3 = dead)
 *   bit  2      : ARC_CC_BUFFERED (1 iff present in g_cc_roots)
 *   bits [31:3] : index inside g_cc_roots */
#define CC_COLOR_BLACK  0u
#define CC_COLOR_GRAY   1u
#define CC_COLOR_WHITE  2u
#define CC_COLOR_DEAD   3u
#define CC_COLOR_MASK   0x3u
#define CC_BUFFERED     0x4u
#define CC_INDEX_SHIFT  3u
#define CC_MAX_ROOTS    ((size_t)1u << 29)

typedef struct CCVec {
    ArcHeader **data;
    size_t      len;
    size_t      cap;
    size_t      alloc_bytes;
} CCVec;

static CCVec g_cc_roots = { NULL, 0, 0, 0 };

static inline int is_unscanned_leaf_tag(uint16_t tag)
{
    return tag == (uint16_t)ARC_TAG_STRING ||
           tag == (uint16_t)ARC_TAG_WEAK ||
           tag == (uint16_t)ARC_TAG_FLOAT ||
           tag == (uint16_t)ARC_TAG_FLOAT_ARRAY ||
           tag == (uint16_t)ARC_TAG_CUSTOM;
}

static inline int is_cycle_candidate_obj(const ArcHeader *hdr)
{
    if (atomic_load_explicit(&hdr->refcount, memory_order_relaxed) == ARC_IMMORTAL)
        return 0;
    uint16_t tag = hdr->tag;
    if (is_unscanned_leaf_tag(tag))
        return 0;
    if (tag == (uint16_t)ARC_TAG_FIBER)
        return 1; /* the shadow stack holds owning references (see
                     cc_visit_children); queued fibers keep the scheduler's
                     +1 from spawn and survive every trial */
    if (tag == (uint16_t)ARC_TAG_ARRAY)
        return hdr->byte_size >= 8u;
    if (tag == (uint16_t)ARC_TAG_PAP)
        return 1;
    return arc_scan_count(hdr) > 0u;
}

static void ccvec_push(CCVec *v, ArcHeader *h)
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

static void ccvec_free(CCVec *v)
{
    if (v->data != NULL) {
        pal_page_free(v->data, v->alloc_bytes);
        v->data = NULL;
        v->len = 0;
        v->cap = 0;
        v->alloc_bytes = 0;
    }
}

static inline void cc_roots_add(ArcHeader *hdr)
{
    /* A mutator holds an owner here. An already buffered candidate stays
     * registered until a trial excludes the mutators or the object dies. */
    if ((atomic_load_explicit(&hdr->reserved, memory_order_relaxed) & CC_BUFFERED) != 0u ||
        !is_cycle_candidate_obj(hdr))
        return;
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

static inline void cc_roots_remove_locked(ArcHeader *hdr)
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

/* Weak-target registry: values currently referenced by any Weak.t slot.
   [weak_clear_target] walks the weak arrays only for objects in this set,
   so dropping an object that was never weakly referenced is O(1) even when
   weak arrays exist. Entries are removed when a target dies, keeping the
   set proportional to live weak data. Stale entries (a value overwritten
   out of its slot) are harmless: the next death lookup scans once, finds
   nothing, and removes the entry. */
#define WEAK_TARGET_TOMBSTONE ((int64_t)1)
static int64_t *g_weak_targets = NULL;  /* open addressing, power-of-2 cap */
static uint64_t g_weak_targets_mask = 0; /* cap - 1 */
static uint64_t g_weak_targets_used = 0; /* live entries + tombstones */
static uint64_t g_weak_targets_live = 0; /* live entries only */

static uint64_t weak_target_hash(int64_t v)
{
    uint64_t x = (uint64_t)v;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return x;
}

static void weak_targets_rehash(void)
{
    uint64_t old_cap =
        (g_weak_targets == NULL) ? 0u : (g_weak_targets_mask + 1u);
    uint64_t new_cap;
    if (old_cap == 0u) {
        new_cap = 1024u;
    } else if ((g_weak_targets_live + 1u) * 2u <= old_cap) {
        /* Live keys are sparse (<= 50% capacity); rehash at the same capacity
           to purge tombstones without doubling on repeated churn. */
        new_cap = old_cap;
    } else {
        new_cap = old_cap * 2u;
    }
    int64_t *nt = (int64_t *)pal_page_alloc((size_t)new_cap * sizeof(int64_t));
    if (nt == NULL)
        pal_abort();
    for (uint64_t i = 0; i < new_cap; i++)
        nt[i] = 0;
    uint64_t live = 0;
    if (g_weak_targets != NULL) {
        for (uint64_t i = 0; i < old_cap; i++) {
            int64_t v = g_weak_targets[i];
            if (v != 0 && v != WEAK_TARGET_TOMBSTONE) {
                uint64_t j = weak_target_hash(v) & (new_cap - 1u);
                while (nt[j] != 0)
                    j = (j + 1u) & (new_cap - 1u);
                nt[j] = v;
                live++;
            }
        }
        pal_page_free(g_weak_targets, (size_t)old_cap * sizeof(int64_t));
    }
    g_weak_targets = nt;
    g_weak_targets_mask = new_cap - 1u;
    g_weak_targets_used = live;
    g_weak_targets_live = live;
}

static int weak_targets_contains(int64_t v)
{
    if (g_weak_targets == NULL)
        return 0;
    uint64_t j = weak_target_hash(v) & g_weak_targets_mask;
    for (;;) {
        int64_t s = g_weak_targets[j];
        if (s == 0)
            return 0;
        if (s == v)
            return 1;
        j = (j + 1u) & g_weak_targets_mask;
    }
}

static void weak_targets_insert(int64_t v)
{
    ArcHeader *hdr = (ArcHeader *)(uintptr_t)v - 1;
    if (atomic_load_explicit(&hdr->refcount, memory_order_relaxed) == ARC_IMMORTAL)
        return; /* An immortal target never needs to be cleared. */
    if (arc_has_spare_scan_bit(hdr))
        atomic_fetch_or_explicit(&hdr->scan_fields, ARC_FLAG_WEAK_TARGET,
                                 memory_order_relaxed);
    if (weak_targets_contains(v))
        return;
    /* Keep at least a third of the table empty so linear probing (which
       terminates on the first empty slot) always terminates, even for
       lookups of absent keys. */
    if (g_weak_targets == NULL ||
        (g_weak_targets_used + 1u) * 3u > (g_weak_targets_mask + 1u) * 2u)
        weak_targets_rehash();
    uint64_t j = weak_target_hash(v) & g_weak_targets_mask;
    while (g_weak_targets[j] != 0 && g_weak_targets[j] != WEAK_TARGET_TOMBSTONE)
        j = (j + 1u) & g_weak_targets_mask;
    if (g_weak_targets[j] == 0)
        g_weak_targets_used++;
    g_weak_targets[j] = v;
    g_weak_targets_live++;
}

static void weak_targets_remove(int64_t v)
{
    if (g_weak_targets == NULL)
        return;
    uint64_t j = weak_target_hash(v) & g_weak_targets_mask;
    for (;;) {
        int64_t s = g_weak_targets[j];
        if (s == 0)
            return;
        if (s == v) {
            g_weak_targets[j] = WEAK_TARGET_TOMBSTONE;
            g_weak_targets_live--;
            return;
        }
        j = (j + 1u) & g_weak_targets_mask;
    }
}

static void weak_clear_target_locked(int64_t dead_obj)
{
    if (!weak_targets_contains(dead_obj))
        return;
    for (ArcWeakArray *w = g_weak_head; w != NULL; w = w->next) {
        for (uint64_t i = 0; i < w->len; i++) {
            if (w->slots[i] == dead_obj)
                w->slots[i] = 0;
        }
    }
    weak_targets_remove(dead_obj);
}

static inline void maybe_clear_weak_target(ArcHeader *hdr)
{
    /* Registration has an owning reference. The final decrement or the
     * collector's mutator handoff makes its mark visible before retirement.
     * Oversized payloads keep the original scan-count representation. */
    if (arc_has_spare_scan_bit(hdr)) {
        if ((atomic_load_explicit(&hdr->scan_fields, memory_order_relaxed) &
             ARC_FLAG_WEAK_TARGET) == 0u)
            return;
    } else if (atomic_load_explicit(&g_weak_count, memory_order_acquire) == 0u) {
        return;
    }
    arc_lock(&g_weak_lock);
    weak_clear_target_locked((int64_t)(uintptr_t)(hdr + 1));
    arc_unlock(&g_weak_lock);
}

static void weak_unlink(ArcWeakArray *w)
{
    arc_lock(&g_weak_lock);
    if (w->prev != NULL)
        w->prev->next = w->next;
    else
        g_weak_head = w->next;
    if (w->next != NULL)
        w->next->prev = w->prev;
    w->prev = NULL;
    w->next = NULL;
    atomic_fetch_sub_explicit(&g_weak_count, 1u, memory_order_relaxed);
    arc_unlock(&g_weak_lock);
}

static _Atomic int64_t g_live_objects = 0;
static _Atomic int64_t g_reuse_hits = 0;
static _Atomic int64_t g_active_slabs = 0;
static _Atomic uint64_t g_alloc_words = 0;
static _Atomic int64_t g_gc_collections = 0;

/* Keep atomic snapshots for C readers. The single-thread profile has only
 * one writer, so its counter updates need no atomic read-modify-write. */
static inline void account_objects(_Atomic int64_t *counter, int64_t delta)
{
#ifdef OCAMLCC_SINGLE_THREAD_RC
    int64_t count = atomic_load_explicit(counter, memory_order_relaxed);
    atomic_store_explicit(counter, count + delta, memory_order_relaxed);
#else
    atomic_fetch_add_explicit(counter, delta, memory_order_relaxed);
#endif
}

static inline void account_words(uint64_t words)
{
#ifdef OCAMLCC_SINGLE_THREAD_RC
    uint64_t count = atomic_load_explicit(&g_alloc_words, memory_order_relaxed);
    atomic_store_explicit(&g_alloc_words, count + words, memory_order_relaxed);
#else
    atomic_fetch_add_explicit(&g_alloc_words, words, memory_order_relaxed);
#endif
}

static _Thread_local int64_t tls_exn_slot = 0;
static _Atomic int64_t g_next_oo_id = 0;

int64_t ocamlcc_get_exn(void) { return tls_exn_slot; }
void ocamlcc_set_exn(int64_t exn) { tls_exn_slot = exn; }

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

static inline int64_t tag_int(int64_t n)
{
    return (int64_t)(((uint64_t)n << 1) | 1ull);
}

static inline int is_heap_ptr(int64_t val)
{
    return val != 0 && (val & 1) == 0;
}

int64_t caml_fresh_oo_id(int64_t ignored)
{
    (void)ignored;
    int64_t id = atomic_fetch_add_explicit(&g_next_oo_id, 1, memory_order_relaxed);
    return tag_int(id);
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
        uint32_t n = dhdr->byte_size / 8u;
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
        uint32_t n = nhdr->byte_size / 8u;
        for (uint32_t i = 0; i < n; i++)
            arc_retain_val(da[i]);
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

static inline int size_class_for(uint32_t total_bytes)
{
    for (int i = 0; i < NUM_SIZE_CLASSES; i++) {
        if (total_bytes <= k_class_sizes[i])
            return i;
    }
    return -1;
}

static inline size_t align_up_large(uint32_t total_bytes)
{
    size_t mask = (size_t)LARGE_PAGE_ALIGN - 1u;
    return ((size_t)total_bytes + mask) & ~mask;
}

static void slab_list_push(SlabPage **head, SlabPage *s)
{
    s->prev = NULL;
    s->next = *head;
    if (*head != NULL)
        (*head)->prev = s;
    *head = s;
}

static void slab_list_remove(SlabPage **head, SlabPage *s)
{
    if (s->prev != NULL)
        s->prev->next = s->next;
    else
        *head = s->next;
    if (s->next != NULL)
        s->next->prev = s->prev;
    s->prev = NULL;
    s->next = NULL;
}

static inline SlabPage *slab_owner(const ArcHeader *hdr)
{
    return (SlabPage *)((uintptr_t)hdr & ~((uintptr_t)SLAB_SIZE - 1u));
}

static inline int slab_has_space(const SlabPage *s, uint32_t step)
{
    return s->free_list != NULL || s->bump_off + step <= SLAB_SIZE;
}

static inline ArcHeader *slab_take_slot(SlabPage *s, uint32_t step)
{
    ArcHeader *hdr;
    if (s->free_list != NULL) {
        FreeSlot *slot = s->free_list;
        s->free_list = slot->next;
        hdr = (ArcHeader *)slot;
    } else {
        hdr = (ArcHeader *)((uint8_t *)s + s->bump_off);
        s->bump_off += step;
    }
    s->used_slots++;
    return hdr;
}

#define SLAB_MAGAZINE_CAPACITY 16u

static ArcHeader *slab_alloc_shared(int cls, ArcHeader **extra, uint32_t *count)
{
    slab_lock();
    uint32_t step = k_class_sizes[cls];
    SlabPage *s = g_partial_slabs[cls];
    if (s == NULL) {
        s = pal_page_alloc_aligned(SLAB_SIZE, SLAB_SIZE);
        if (s == NULL) {
            slab_unlock();
            pal_abort();
        }
        s->prev = NULL;
        s->next = NULL;
        s->free_list = NULL;
        s->cls = (uint32_t)cls;
        s->used_slots = 0u;
        s->bump_off = (uint32_t)sizeof(SlabPage);
        s->is_full = 0u;
        slab_list_push(&g_partial_slabs[cls], s);
        g_class_slab_count[cls]++;
        account_objects(&g_active_slabs, 1);
    }
    ArcHeader *hdr = slab_take_slot(s, step);
    if (extra != NULL) {
        while (*count < SLAB_MAGAZINE_CAPACITY - 1u && slab_has_space(s, step)) {
            extra[*count] = slab_take_slot(s, step);
            (*count)++;
        }
    }
    if (!slab_has_space(s, step)) {
        slab_list_remove(&g_partial_slabs[cls], s);
        slab_list_push(&g_full_slabs[cls], s);
        s->is_full = 1u;
    }
    slab_unlock();
    return hdr;
}

/* Cached slots count as used until returned here. A cached or live slot
 * therefore pins its slab even if another thread frees its last live block. */
static SlabPage *slab_return_slot_locked(ArcHeader *hdr)
{
    SlabPage *s = slab_owner(hdr);
    uint32_t cls = s->cls;
    FreeSlot *slot = (FreeSlot *)hdr;
    slot->next = s->free_list;
    s->free_list = slot;
    s->used_slots--;
    if (s->used_slots == 0u && g_class_slab_count[cls] > 1u) {
        if (s->is_full)
            slab_list_remove(&g_full_slabs[cls], s);
        else
            slab_list_remove(&g_partial_slabs[cls], s);
        g_class_slab_count[cls]--;
        account_objects(&g_active_slabs, -1);
        return s;
    }
    if (s->is_full) {
        slab_list_remove(&g_full_slabs[cls], s);
        slab_list_push(&g_partial_slabs[cls], s);
        s->is_full = 0u;
    }
    return NULL;
}

static void slab_return_slots(ArcHeader *const *slots, uint32_t count)
{
    SlabPage *retired[SLAB_MAGAZINE_CAPACITY];
    uint32_t retired_count = 0;
    slab_lock();
    for (uint32_t i = 0; i < count; i++) {
        SlabPage *s = slab_return_slot_locked(slots[i]);
        if (s != NULL)
            retired[retired_count++] = s;
    }
    slab_unlock();
    for (uint32_t i = 0; i < retired_count; i++)
        pal_page_free(retired[i], SLAB_SIZE);
}

#ifndef OCAMLCC_SINGLE_THREAD_RC
typedef struct {
    ArcHeader *slots[SLAB_MAGAZINE_CAPACITY];
    uint32_t count;
} SlabMagazine;

typedef struct {
    SlabMagazine magazines[NUM_SIZE_CLASSES];
} SlabThreadCache;

static pthread_once_t g_slab_cache_once = PTHREAD_ONCE_INIT;
static pthread_key_t g_slab_cache_key;
/* 0 before key creation, 1 for a valid key, -1 if caching is unavailable. */
static _Atomic int g_slab_cache_ready;
static _Thread_local SlabThreadCache *tls_slab_cache;
static _Thread_local int tls_slab_cache_ended;

static void slab_cache_destroy(void *arg)
{
    SlabThreadCache *cache = arg;
    tls_slab_cache = NULL;
    tls_slab_cache_ended = 1;
    for (int cls = 0; cls < NUM_SIZE_CLASSES; cls++) {
        SlabMagazine *m = &cache->magazines[cls];
        if (m->count != 0)
            slab_return_slots(m->slots, m->count);
    }
    pal_page_free(cache, sizeof(*cache));
}

static void slab_cache_create_key(void)
{
    int rc = pthread_key_create(&g_slab_cache_key, slab_cache_destroy);
    atomic_store_explicit(&g_slab_cache_ready, rc == 0 ? 1 : -1, memory_order_release);
}

static SlabThreadCache *slab_cache_init(void)
{
    /* Other pthread destructors can still release objects after ours. */
    if (tls_slab_cache_ended)
        return NULL;
    int ready = atomic_load_explicit(&g_slab_cache_ready, memory_order_acquire);
    if (ready == 0) {
        pthread_once(&g_slab_cache_once, slab_cache_create_key);
        ready = atomic_load_explicit(&g_slab_cache_ready, memory_order_acquire);
    }
    if (ready != 1)
        return NULL;

    SlabThreadCache *cache = pal_page_alloc(sizeof(*cache));
    if (cache == NULL)
        return NULL;
    if (pthread_setspecific(g_slab_cache_key, cache) != 0) {
        pal_page_free(cache, sizeof(*cache));
        return NULL;
    }
    tls_slab_cache = cache;
    return cache;
}

static inline SlabMagazine *slab_magazine(int cls)
{
    SlabThreadCache *cache = tls_slab_cache;
    if (cache == NULL)
        cache = slab_cache_init();
    return cache == NULL ? NULL : &cache->magazines[cls];
}

static inline void slab_cache_slot(SlabMagazine *m, ArcHeader *hdr)
{
    if (m->count == SLAB_MAGAZINE_CAPACITY) {
        m->count /= 2u;
        slab_return_slots(m->slots + m->count, m->count);
    }
    m->slots[m->count++] = hdr;
}
#endif

static ArcHeader *slab_alloc(uint32_t total_bytes)
{
    int cls = size_class_for(total_bytes);
    if (cls >= 0) {
#ifndef OCAMLCC_SINGLE_THREAD_RC
        SlabMagazine *m = slab_magazine(cls);
        if (m != NULL) {
            if (m->count != 0)
                return m->slots[--m->count];
            return slab_alloc_shared(cls, m->slots, &m->count);
        }
#endif
        return slab_alloc_shared(cls, NULL, NULL);
    }

    size_t page_sz = align_up_large(total_bytes);
    ArcHeader *hdr = (ArcHeader *)pal_page_alloc(page_sz);
    if (hdr == NULL)
        pal_abort();
    return hdr;
}

static void slab_free(ArcHeader *hdr)
{
    uint32_t total_bytes = (uint32_t)sizeof(ArcHeader) + hdr->byte_size;
    int cls = size_class_for(total_bytes);
    if (cls >= 0) {
        SlabPage *s = slab_owner(hdr);
        if (s->cls != (uint32_t)cls)
            pal_abort();
#ifndef OCAMLCC_SINGLE_THREAD_RC
        SlabMagazine *m = slab_magazine(cls);
        if (m != NULL) {
            slab_cache_slot(m, hdr);
            return;
        }
#endif
        slab_return_slots(&hdr, 1u);
    } else {
        pal_page_free(hdr, align_up_large(total_bytes));
    }
}

void *arc_alloc(uint16_t tag, uint16_t scan_fields, uint32_t byte_size)
{
    if ((uint64_t)sizeof(ArcHeader) + (uint64_t)byte_size > (uint64_t)UINT32_MAX)
        pal_abort();
    ArcHeader *hdr = slab_alloc((uint32_t)sizeof(ArcHeader) + byte_size);
    atomic_init(&hdr->refcount, 1u);
    hdr->tag = tag;
    atomic_init(&hdr->scan_fields, scan_fields);
    hdr->byte_size = byte_size;
    hdr->reserved = 0;
    account_objects(&g_live_objects, 1);
    account_words((uint64_t)(byte_size / 8u) + 2u);
    return hdr + 1;
}

extern const void *ocamlcc_global_Invalid_argument;
extern const void *ocamlcc_global_Failure;
extern const void *ocamlcc_global_Sys_error;

#define DEFINE_IMMORTAL_STR(sym, lit)                                          \
    static const struct __attribute__((aligned(16))) {                         \
        ArcHeader hdr;                                                         \
        char str[sizeof(lit)];                                                 \
    } sym = {                                                                  \
        { ARC_IMMORTAL, (uint16_t)ARC_TAG_STRING, 0u,                          \
          (uint32_t)sizeof(lit), (uint32_t)(sizeof(lit) - 1u) },               \
        lit                                                                    \
    }

DEFINE_IMMORTAL_STR(g_inv_arg_finalise, "Gc.finalise");
DEFINE_IMMORTAL_STR(g_inv_arg_oob_str, "index out of bounds");
DEFINE_IMMORTAL_STR(g_inv_arg_fn_str, "compare: functional value");
DEFINE_IMMORTAL_STR(g_inv_arg_bytes_str, "Bytes.create");
DEFINE_IMMORTAL_STR(g_inv_arg_array_str, "Array.make");
DEFINE_IMMORTAL_STR(g_inv_arg_weak_str, "Weak.create");
DEFINE_IMMORTAL_STR(g_inv_arg_fiber_str,
                    "Fiber: coroutine/scheduler cross-call");

static void raise_invalid_arg_imm(const char *imm_str)
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

void *arc_alloc_bytes(uint64_t len)
{
    if (len > (uint64_t)UINT32_MAX - 1u - (uint64_t)sizeof(ArcHeader)) {
        raise_invalid_arg_imm(g_inv_arg_bytes_str.str);
        return (void *)(uintptr_t)1;
    }
    char *s = arc_alloc((uint16_t)ARC_TAG_STRING, 0u, (uint32_t)(len + 1u));
    ArcHeader *hdr = (ArcHeader *)s - 1;
    hdr->reserved = (uint32_t)len;
    s[len] = '\0';
    return s;
}

/* CamlinternalBulkOps checks the slices before entering these helpers.
   Bytes and strings have the same payload layout and may alias. */
int64_t ocamlcc_bulk_blit_bytes(int64_t src, int64_t src_off, int64_t dst,
                               int64_t dst_off, int64_t len)
{
    pal_memmove((char *)(uintptr_t)dst + (dst_off >> 1),
                (const char *)(uintptr_t)src + (src_off >> 1),
                (size_t)(len >> 1));
    return 1;
}

int64_t ocamlcc_bulk_fill_bytes(int64_t dst, int64_t off, int64_t len, int64_t ch)
{
    pal_memset((char *)(uintptr_t)dst + (off >> 1),
               (uint8_t)(ch >> 1), (size_t)(len >> 1));
    return 1;
}

/* Keep the header ABI identical in both builds. On the single owner thread
   relaxed loads and stores suffice, and require no atomic read-modify-write. */
static inline void refcount_add(ArcHeader *hdr, uint32_t old_rc, uint32_t n)
{
#ifdef OCAMLCC_SINGLE_THREAD_RC
    atomic_store_explicit(&hdr->refcount, old_rc + n, memory_order_relaxed);
#else
    (void)old_rc;
    atomic_fetch_add_explicit(&hdr->refcount, n, memory_order_relaxed);
#endif
}

static inline int refcount_drop_last(ArcHeader *hdr, uint32_t old_rc)
{
#ifdef OCAMLCC_SINGLE_THREAD_RC
    atomic_store_explicit(&hdr->refcount, old_rc - 1u, memory_order_relaxed);
    return old_rc == 1u;
#else
    (void)old_rc;
    if (atomic_fetch_sub_explicit(&hdr->refcount, 1u, memory_order_acq_rel) != 1u)
        return 0;
    atomic_thread_fence(memory_order_acquire);
    return 1;
#endif
}

void *arc_alloc_array(uint64_t len, int64_t init)
{
    if (len > ((uint64_t)UINT32_MAX - (uint64_t)sizeof(ArcHeader)) / 8u) {
        arc_release_val(init);
        raise_invalid_arg_imm(g_inv_arg_array_str.str);
        return (void *)(uintptr_t)1;
    }
    if (len > 0 && is_heap_ptr(init)) {
        const ArcHeader *ihdr = (const ArcHeader *)(uintptr_t)init - 1;
        if (ihdr->tag == (uint16_t)ARC_TAG_FLOAT) {
            uint64_t bits;
            pal_memcpy(&bits, (const void *)(uintptr_t)init, sizeof(bits));
            uint64_t *farr = (uint64_t *)arc_alloc((uint16_t)ARC_TAG_FLOAT_ARRAY,
                                                    0u, (uint32_t)(len * 8u));
            for (uint64_t i = 0; i < len; i++)
                farr[i] = bits;
            arc_release_val(init);
            return farr;
        }
    }
    uint16_t scan = (len > 0xffffu) ? 0xffffu : (uint16_t)len;
    int64_t *arr = arc_alloc((uint16_t)ARC_TAG_ARRAY, scan, (uint32_t)(len * 8u));
    if (len == 0) {
        arc_release_val(init);
        return arr;
    }
    if (len > 1 && is_heap_ptr(init)) {
        ArcHeader *ihdr = (ArcHeader *)(uintptr_t)init - 1;
        uint32_t rc = atomic_load_explicit(&ihdr->refcount, memory_order_relaxed);
        if (rc != ARC_IMMORTAL) {
            uint64_t extra = len - 1u;
            if (extra >= (uint64_t)(ARC_IMMORTAL - rc))
                pal_abort();
            refcount_add(ihdr, rc, (uint32_t)extra);
        }
    }
    for (uint64_t i = 0; i < len; i++)
        arr[i] = init;
    return arr;
}

void arc_retain(void *obj)
{
    ArcHeader *hdr = (ArcHeader *)obj - 1;
    uint32_t rc = atomic_load_explicit(&hdr->refcount, memory_order_relaxed);
    if (rc != ARC_IMMORTAL)
        refcount_add(hdr, rc, 1u);
}

static int arc_try_retain(ArcHeader *hdr)
{
#ifdef OCAMLCC_SINGLE_THREAD_RC
    uint32_t rc = atomic_load_explicit(&hdr->refcount, memory_order_relaxed);
    if (rc == 0u)
        return 0;
    if (rc != ARC_IMMORTAL)
        refcount_add(hdr, rc, 1u);
    return 1;
#else
    uint32_t rc = atomic_load_explicit(&hdr->refcount, memory_order_acquire);
    while (rc != 0u) {
        if (rc == ARC_IMMORTAL)
            return 1;
        if (atomic_compare_exchange_weak_explicit(
                &hdr->refcount, &rc, rc + 1u,
                memory_order_acq_rel, memory_order_acquire))
            return 1;
    }
    return 0;
#endif
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
static void release_subtree(ArcHeader *root, int free_root)
{
    foreign_release_depth++;
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
            uint32_t n = cur->byte_size / 8u;
            for (uint32_t i = 0; i < n; i++)
                drop_child_val(&w, arr[i], &tail);
        } else if (tag == ARC_TAG_WEAK) {
            weak_unlink((ArcWeakArray *)(cur + 1));
        } else if (tag == ARC_TAG_FIBER) {
            fiber_destroy((Fiber *)(cur + 1));
        } else if (tag == ARC_TAG_CUSTOM) {
            void *p = (void *)(uintptr_t)(*(uint64_t *)(cur + 1));
            if (cur->reserved == ARC_CUSTOM_MUTEX)
                ocamlcc_c_mutex_free(p);
            else if (cur->reserved == ARC_CUSTOM_COND)
                ocamlcc_c_cond_free(p);
            else if (cur->reserved == ARC_CUSTOM_BIGARRAY) {
                ArcBigarray *a = (void *)(cur + 1);
                drop_child_val(&w, (int64_t)(uintptr_t)a->backing, &tail);
            } else if (cur->reserved == ARC_CUSTOM_BIGARRAY_BUFFER) {
                ArcBigarrayBuffer *b = (void *)(cur + 1);
                if (b->owner) {
                    b->owner->next = pending_foreign_releases;
                    pending_foreign_releases = b->owner;
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

        maybe_clear_weak_target(cur);

        if (((atomic_load_explicit(&cur->reserved, memory_order_relaxed) &
              CC_BUFFERED) != 0u && is_cycle_candidate_obj(cur)) ||
            atomic_load_explicit(&g_cc_active, memory_order_acquire) != 0) {
            arc_lock(&g_cc_lock);
            cc_roots_remove_locked(cur);
            arc_unlock(&g_cc_lock);
        }

        account_objects(&g_live_objects, -1);
        if (cur != root || free_root)
            slab_free(cur);

        cur = (tail != NULL) ? tail : work_pop(&w);
    }
    foreign_release_depth--;
    if (pending_foreign_releases) drain_foreign_releases();
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
        atomic_init(&hdr->scan_fields, scan_fields);
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

int64_t ocamlcc_weak_table_cap(int64_t unit)
{
    (void)unit;
    arc_lock(&g_weak_lock);
    uint64_t cap = (g_weak_targets == NULL) ? 0u : (g_weak_targets_mask + 1u);
    arc_unlock(&g_weak_lock);
    return tag_int((int64_t)cap);
}

typedef void (*CcChildFn)(int64_t val, void *ctx);

static void cc_visit_children(ArcHeader *hdr, CcChildFn fn, void *ctx)
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
        uint32_t n = hdr->byte_size / 8u;
        for (uint32_t i = 0; i < n; i++)
            fn(arr[i], ctx);
    } else if (tag == (uint16_t)ARC_TAG_FIBER) {
        /* The fiber owns its shadow-stack values (live across suspension
           points), the entry closure, the resume/suspend payload, and its
           per-fiber exception slots — each is an owning child edge. */
        const Fiber *f = (const Fiber *)(hdr + 1);
        if (f->shadow_base != NULL) {
            for (const uint64_t *p = f->shadow_base; p < f->shadow_sp; p++)
                fn((int64_t)*p, ctx);
        }
        if (f->entry_closure != 0)
            fn(f->entry_closure, ctx);
        if (f->result != 0)
            fn(f->result, ctx);
        if (f->exn_slot != 0)
            fn(f->exn_slot, ctx);
        if (f->pending_exn != 0)
            fn(f->pending_exn, ctx);
        for (size_t i = 0; i < FIBER_HANDLER_COUNT; i++)
            fn(f->handlers[i], ctx);
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

/* Registrations own both their callback and a temporary pin on the target.
 * The major-collection trial discounts these pins to find unreachable values.
 * Ordinary ARC release and reuse therefore need no registry lookup or lock. */
typedef struct Finalizer {
    struct Finalizer *next;
    int64_t value; /* ordinary target, or a one-slot weak array for last callbacks */
    int64_t callback;
    int last;
} Finalizer;

static Finalizer *finalizers; /* newest first, protected by g_cc_lock */
static Finalizer *last_finalizers; /* protected by g_weak_lock */
static Finalizer *pending_finalizers; /* owned by the active dispatcher */
/* READY publishes a nonempty queue from a callback that released dispatch.
 * A taker may deliver those registrations without a successful new trial. */
enum DispatchState { DISPATCH_IDLE, DISPATCH_ACTIVE, DISPATCH_READY };
static _Atomic enum DispatchState finalizer_dispatch;
/* Includes registrations already claimed by a dispatcher. */
/* Generated code reads this count to bypass automatic polls on idle paths. */
_Atomic uint64_t ocamlcc_finalizer_count;
static _Atomic uint64_t last_finalizer_poll;

static ArcHeader *finalizer_target(Finalizer *f)
{
    return (ArcHeader *)(uintptr_t)f->value - 1;
}

static void append_pending(Finalizer *ready)
{
    if (ready == NULL)
        return;
    /* Exceptions may have left earlier callbacks pending. */
    Finalizer **end = &pending_finalizers;
    while (*end != NULL)
        end = &(*end)->next;
    *end = ready;
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
static int64_t collect_cycles(int discover_finalizers)
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
        int is_fiber = (w->tag == (uint16_t)ARC_TAG_FIBER);
        Fiber *f = is_fiber ? (Fiber *)(w + 1) : NULL;
        if (is_fiber) {
            while (f->reuse_sp > f->reuse_base) {
                f->reuse_sp--;
                arc_free_reuse(*f->reuse_sp);
            }
        }
        maybe_clear_weak_target(w);
        cc_visit_children(w, cc_collect_outgoing_cb, &outgoing);
        if (is_fiber) {
            f->entry_closure = 0;
            f->result = 0;
            f->exn_slot = 0;
            f->pending_exn = 0;
            if (f->shadow_base != NULL) {
                pal_page_free(f->shadow_base,
                              (size_t)(f->shadow_end - f->shadow_base) *
                                  sizeof(uint64_t));
                f->shadow_base = NULL;
                f->shadow_sp = NULL;
                f->shadow_end = NULL;
            }
            if (f->reuse_base != NULL) {
                pal_page_free(f->reuse_base,
                              (size_t)(f->reuse_end - f->reuse_base) *
                                  sizeof(void *));
                f->reuse_base = NULL;
                f->reuse_sp = NULL;
                f->reuse_end = NULL;
            }
            if (f->c_stack != NULL) {
                pal_page_free(f->c_stack, f->c_stack_bytes);
                f->c_stack = NULL;
                f->c_stack_bytes = 0;
            }
            f->state = FIBER_DONE;
        }
    }

    atomic_store_explicit(&g_cc_active, 0, memory_order_release);
    arc_unlock(&g_cc_lock);

    foreign_release_depth++;
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
    foreign_release_depth--;
    if (pending_foreign_releases) drain_foreign_releases();
    return reclaimed;
}

int64_t ocamlcc_arc_collect(int64_t unit)
{
    (void)unit;
    int64_t reclaimed = collect_cycles(0);
    return tag_int(reclaimed < 0 ? 0 : reclaimed);
}

int64_t ocamlcc_weak_create(int64_t len_val)
{
    int64_t len_s = len_val >> 1;
    if (len_s < 0) {
        raise_invalid_arg_imm(g_inv_arg_weak_str.str);
        return 1;
    }
    uint64_t len = (uint64_t)len_s;
    if (len > ((uint64_t)UINT32_MAX - (uint64_t)sizeof(ArcHeader) -
               (uint64_t)sizeof(ArcWeakArray)) / 8u) {
        raise_invalid_arg_imm(g_inv_arg_weak_str.str);
        return 1;
    }
    uint32_t bsz = (uint32_t)(sizeof(ArcWeakArray) + len * sizeof(int64_t));
    ArcWeakArray *w = (ArcWeakArray *)arc_alloc((uint16_t)ARC_TAG_WEAK, 0u, bsz);
    w->len = len;
    for (uint64_t i = 0; i < len; i++)
        w->slots[i] = 0;
    arc_lock(&g_weak_lock);
    w->prev = NULL;
    w->next = g_weak_head;
    if (g_weak_head != NULL)
        g_weak_head->prev = w;
    g_weak_head = w;
    atomic_fetch_add_explicit(&g_weak_count, 1u, memory_order_relaxed);
    arc_unlock(&g_weak_lock);
    return (int64_t)(uintptr_t)w;
}

int64_t ocamlcc_weak_length(int64_t weak_val)
{
    ArcWeakArray *w = (ArcWeakArray *)(uintptr_t)weak_val;
    return tag_int((int64_t)w->len);
}

int64_t ocamlcc_weak_set(int64_t weak_val, int64_t idx_val, int64_t opt_val)
{
    ArcWeakArray *w = (ArcWeakArray *)(uintptr_t)weak_val;
    int64_t idx = idx_val >> 1;
    if (idx < 0 || (uint64_t)idx >= w->len) {
        raise_invalid_arg_imm(g_inv_arg_oob_str.str);
        return 1;
    }
    int64_t target = 0;
    if (opt_val != 1) {
        int64_t *some = (int64_t *)(uintptr_t)opt_val;
        target = some[0];
    }
    arc_lock(&g_weak_lock);
    w->slots[idx] = target;
    if (target != 0 && is_heap_ptr(target))
        weak_targets_insert(target);
    arc_unlock(&g_weak_lock);
    return 1;
}

int64_t ocamlcc_weak_get(int64_t weak_val, int64_t idx_val)
{
    ArcWeakArray *w = (ArcWeakArray *)(uintptr_t)weak_val;
    int64_t idx = idx_val >> 1;
    if (idx < 0 || (uint64_t)idx >= w->len) {
        raise_invalid_arg_imm(g_inv_arg_oob_str.str);
        return 1;
    }
    arc_lock(&g_weak_lock);
    int64_t val = w->slots[idx];
    if (val != 0 && is_heap_ptr(val)) {
        ArcHeader *hdr = (ArcHeader *)(uintptr_t)val - 1;
        if (!arc_try_retain(hdr)) {
            w->slots[idx] = 0;
            val = 0;
        }
    }
    arc_unlock(&g_weak_lock);
    if (val == 0)
        return 1; /* None */
    int64_t *some = (int64_t *)arc_alloc(0u, 1u, 8u);
    some[0] = val;
    return (int64_t)(uintptr_t)some;
}

static int64_t dup_with_tag(int64_t v, int override_tag, uint16_t new_atag);

int64_t ocamlcc_weak_get_copy(int64_t weak_val, int64_t idx_val)
{
    ArcWeakArray *w = (ArcWeakArray *)(uintptr_t)weak_val;
    int64_t idx = idx_val >> 1;
    if (idx < 0 || (uint64_t)idx >= w->len) {
        raise_invalid_arg_imm(g_inv_arg_oob_str.str);
        return 1;
    }
    arc_lock(&g_weak_lock);
    int64_t val = w->slots[idx];
    if (val != 0 && is_heap_ptr(val)) {
        ArcHeader *hdr = (ArcHeader *)(uintptr_t)val - 1;
        if (!arc_try_retain(hdr)) {
            w->slots[idx] = 0;
            val = 0;
        }
    }
    arc_unlock(&g_weak_lock);
    if (val == 0)
        return 1; /* None */
    int64_t result = dup_with_tag(val, 0, 0u);
    arc_release_val(val);
    int64_t *some = (int64_t *)arc_alloc(0u, 1u, 8u);
    some[0] = result;
    return (int64_t)(uintptr_t)some;
}

int64_t ocamlcc_weak_check(int64_t weak_val, int64_t idx_val)
{
    ArcWeakArray *w = (ArcWeakArray *)(uintptr_t)weak_val;
    int64_t idx = idx_val >> 1;
    if (idx < 0 || (uint64_t)idx >= w->len) {
        raise_invalid_arg_imm(g_inv_arg_oob_str.str);
        return 1;
    }
    arc_lock(&g_weak_lock);
    int64_t val = w->slots[idx];
    if (val != 0 && is_heap_ptr(val)) {
        ArcHeader *hdr = (ArcHeader *)(uintptr_t)val - 1;
        if (atomic_load_explicit(&hdr->refcount, memory_order_acquire) == 0u) {
            w->slots[idx] = 0;
            val = 0;
        }
    }
    arc_unlock(&g_weak_lock);
    return (val != 0) ? 3 : 1; /* OCaml bool: true=3, false=1 */
}

/* ------------------------------------------------------------------ */
/* Tagged wrappers around minimal builtins.c I/O & exit                */
/* ------------------------------------------------------------------ */

extern void ocamlcc_print_int(int64_t n);
extern void ocamlcc_print_string(const char *s, size_t len);
extern void ocamlcc_print_endline(const char *s, size_t len);
extern void ocamlcc_exit(int64_t code) __attribute__((noreturn));

int64_t ocamlcc_print_int_val(int64_t val)
{
    ocamlcc_print_int(val >> 1);
    return 1;
}

int64_t ocamlcc_print_char_val(int64_t val)
{
    char ch = (char)(val >> 1);
    ocamlcc_print_string(&ch, 1u);
    return 1;
}

int64_t ocamlcc_print_string_val(int64_t val)
{
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)val - 1;
    ocamlcc_print_string((const char *)(uintptr_t)val, (size_t)hdr->reserved);
    return 1;
}

int64_t ocamlcc_prerr_string_val(int64_t val)
{
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)val - 1;
    pal_stderr_write((const void *)(uintptr_t)val, (size_t)hdr->reserved);
    return 1;
}

static void raise_failure_cstr(const char *msg, size_t len)
{
    char *s = (char *)arc_alloc_bytes((uint64_t)len);
    if (len > 0u)
        pal_memcpy(s, msg, len);
    int64_t *blk = (int64_t *)arc_alloc(0u, 2u, 16u);
    blk[0] = (int64_t)(uintptr_t)ocamlcc_global_Failure;
    blk[1] = (int64_t)(uintptr_t)s;
    ocamlcc_set_exn((int64_t)(uintptr_t)blk);
}

int64_t ocamlcc_alloc_float(double d)
{
    double *p = (double *)arc_alloc((uint16_t)ARC_TAG_FLOAT, 0u, 8u);
    *p = d;
    return (int64_t)(uintptr_t)p;
}

int64_t ocamlcc_alloc_custom(uint32_t kind, uint64_t bits)
{
    uint64_t *p = (uint64_t *)arc_alloc((uint16_t)ARC_TAG_CUSTOM, 0u, 8u);
    ArcHeader *hdr = (ArcHeader *)p - 1;
    hdr->reserved = kind;
    *p = bits;
    return (int64_t)(uintptr_t)p;
}

static inline double unbox_float(int64_t v)
{
    double d;
    pal_memcpy(&d, (const void *)(uintptr_t)v, sizeof(double));
    return d;
}

static inline int64_t unbox_custom_i64(int64_t v)
{
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)v - 1;
    if (hdr->reserved == ARC_CUSTOM_INT32) {
        int32_t w;
        pal_memcpy(&w, (const void *)(uintptr_t)v, sizeof(w));
        return (int64_t)w;
    }
    int64_t l;
    pal_memcpy(&l, (const void *)(uintptr_t)v, sizeof(l));
    return l;
}

int64_t ocamlcc_gen_makearray(int64_t n, const int64_t *elems)
{
    if (n <= 0)
        return (int64_t)(uintptr_t)arc_alloc((uint16_t)ARC_TAG_ARRAY, 0u, 0u);
    if (is_heap_ptr(elems[0])) {
        const ArcHeader *h0 = (const ArcHeader *)(uintptr_t)elems[0] - 1;
        if (h0->tag == (uint16_t)ARC_TAG_FLOAT) {
            double *farr = (double *)arc_alloc(
                (uint16_t)ARC_TAG_FLOAT_ARRAY, 0u, (uint32_t)((uint64_t)n * 8u));
            for (int64_t i = 0; i < n; i++) {
                farr[i] = unbox_float(elems[i]);
                arc_release_val(elems[i]);
            }
            return (int64_t)(uintptr_t)farr;
        }
    }
    uint16_t scan = (n > 0xffff) ? 0xffffu : (uint16_t)n;
    int64_t *arr = (int64_t *)arc_alloc(
        (uint16_t)ARC_TAG_ARRAY, scan, (uint32_t)((uint64_t)n * 8u));
    for (int64_t i = 0; i < n; i++)
        arr[i] = elems[i];
    return (int64_t)(uintptr_t)arr;
}

int64_t ocamlcc_gen_array_get(int64_t safe, int64_t arr, int64_t idx_val)
{
    uint64_t idx = (uint64_t)(idx_val >> 1);
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)arr - 1;
    uint64_t len = (uint64_t)(hdr->byte_size >> 3);
    if (safe && idx >= len) {
        ocamlcc_raise_invalid_arg_oob();
        return 1;
    }
    if (hdr->tag == (uint16_t)ARC_TAG_FLOAT_ARRAY) {
        const double *farr = (const double *)(uintptr_t)arr;
        return ocamlcc_alloc_float(farr[idx]);
    }
    const int64_t *elems = (const int64_t *)(uintptr_t)arr;
    int64_t v = elems[idx];
    arc_retain_val(v);
    return v;
}

int64_t ocamlcc_gen_array_set(int64_t safe, int64_t arr, int64_t idx_val, int64_t v)
{
    uint64_t idx = (uint64_t)(idx_val >> 1);
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)arr - 1;
    uint64_t len = (uint64_t)(hdr->byte_size >> 3);
    if (safe && idx >= len) {
        arc_release_val(v);
        ocamlcc_raise_invalid_arg_oob();
        return 1;
    }
    if (hdr->tag == (uint16_t)ARC_TAG_FLOAT_ARRAY) {
        double *farr = (double *)(uintptr_t)arr;
        farr[idx] = unbox_float(v);
        arc_release_val(v);
        return 1;
    }
    int64_t *elems = (int64_t *)(uintptr_t)arr;
    int64_t old_v = elems[idx];
    elems[idx] = v;
    arc_release_val(old_v);
    return 1;
}

static int array_is_flat_float(int64_t value)
{
    return ((const ArcHeader *)(uintptr_t)value - 1)->tag == ARC_TAG_FLOAT_ARRAY;
}

/* An array's header scan count is not a type proof. AND the tags across
   the affected slice so the native compiler can vectorize the check. */
static int array_words_are_immediate(const int64_t *words, size_t count)
{
    uint64_t tags = 1u;
    for (size_t i = 0; i < count; i++)
        tags &= (uint64_t)words[i];
    return (int)(tags & 1u);
}

static inline void array_replace_borrowed(int64_t *slot, int64_t value)
{
    int64_t old = *slot;
    if (old == value)
        return;
    arc_retain_val(value);
    *slot = value;
    arc_release_val(old);
}

int64_t ocamlcc_bulk_array_sub(int64_t src, int64_t off, int64_t len)
{
    size_t count = (size_t)(len >> 1);
    size_t start = (size_t)(off >> 1);
    int flat_float = array_is_flat_float(src);
    const void *from = (const char *)(uintptr_t)src + start * sizeof(int64_t);
    int needs_retain = !flat_float && !array_words_are_immediate(from, count);
    uint16_t tag = flat_float ? ARC_TAG_FLOAT_ARRAY : ARC_TAG_ARRAY;
    uint16_t scan = !needs_retain ? 0u :
        (count > UINT16_MAX ? UINT16_MAX : (uint16_t)count);
    int64_t *copy = arc_alloc(tag, scan, (uint32_t)(count * sizeof(*copy)));
    pal_memcpy(copy, from, count * sizeof(*copy));
    if (needs_retain)
        for (size_t i = 0; i < count; i++)
            arc_retain_val(copy[i]);
    return (int64_t)(uintptr_t)copy;
}

int64_t ocamlcc_bulk_array_blit(int64_t src, int64_t src_off, int64_t dst,
                              int64_t dst_off, int64_t len)
{
    size_t count = (size_t)(len >> 1);
    if (count == 0 || (src == dst && src_off == dst_off))
        return 1;

    int src_float = array_is_flat_float(src);
    int dst_float = array_is_flat_float(dst);
    if (src_float != dst_float) {
        /* Preserve the generic boxed/flat conversion for mixed layouts. */
        for (size_t i = 0; i < count; i++) {
            int64_t delta = (int64_t)i * 2;
            int64_t value = ocamlcc_gen_array_get(0, src, src_off + delta);
            ocamlcc_gen_array_set(0, dst, dst_off + delta, value);
        }
        return 1;
    }

    const void *src_slice = (const char *)(uintptr_t)src + (src_off >> 1) * 8;
    void *dst_slice = (char *)(uintptr_t)dst + (dst_off >> 1) * 8;
    const int64_t *from = src_slice;
    int64_t *to = dst_slice;
    if (src_float || (array_words_are_immediate(from, count) &&
                      array_words_are_immediate(to, count))) {
        pal_memmove(dst_slice, src_slice, count * sizeof(*to));
    } else if (src == dst && dst_off > src_off) {
        for (size_t i = count; i > 0; i--)
            array_replace_borrowed(&to[i - 1], from[i - 1]);
    } else {
        for (size_t i = 0; i < count; i++)
            array_replace_borrowed(&to[i], from[i]);
    }
    return 1;
}

int64_t ocamlcc_bulk_array_fill(int64_t dst, int64_t off, int64_t len, int64_t value)
{
    size_t count = (size_t)(len >> 1);
    if (count == 0)
        return 1;

    if (array_is_flat_float(dst)) {
        double *to = (double *)(uintptr_t)dst + (off >> 1);
        double unboxed = unbox_float(value);
        for (size_t i = 0; i < count; i++)
            to[i] = unboxed;
    } else {
        int64_t *to = (int64_t *)(uintptr_t)dst + (off >> 1);
        if ((value & 1) && array_words_are_immediate(to, count)) {
            for (size_t i = 0; i < count; i++)
                to[i] = value;
        } else {
            for (size_t i = 0; i < count; i++)
                array_replace_borrowed(&to[i], value);
        }
    }
    return 1;
}

extern int ocamlcc_snprintf_double(char *out, size_t cap, const char *fmt,
                                   size_t fmt_len, double d);
extern int ocamlcc_parse_double(const char *s, size_t len, double *out);
extern double ocamlcc_c_sqrt(double d);
extern double ocamlcc_c_floor(double d);
extern double ocamlcc_c_ceil(double d);
extern double ocamlcc_c_fmod(double a, double b);
extern double ocamlcc_c_copysign(double a, double b);
extern int ocamlcc_c_fpclassify(double d);

int64_t ocamlcc_print_float_val(int64_t val)
{
    char buf[64];
    int n = ocamlcc_snprintf_double(buf, sizeof(buf), "%.12g", 5u, unbox_float(val));
    if (n > 0)
        ocamlcc_print_string(buf, (size_t)n);
    return 1;
}

static int64_t alloc_c_string_buf(const char *buf, int n)
{
    if (n < 0)
        n = 0;
    char *s = (char *)arc_alloc_bytes((uint64_t)n);
    if (n > 0)
        pal_memcpy(s, buf, (size_t)n);
    return (int64_t)(uintptr_t)s;
}

int64_t caml_format_float(int64_t fmt_val, int64_t float_val)
{
    const ArcHeader *fh = (const ArcHeader *)(uintptr_t)fmt_val - 1;
    char buf[512];
    int n = ocamlcc_snprintf_double(
        buf, sizeof(buf), (const char *)(uintptr_t)fmt_val,
        (size_t)fh->reserved, unbox_float(float_val));
    return alloc_c_string_buf(buf, n);
}

int64_t caml_float_of_string(int64_t s_val)
{
    const ArcHeader *sh = (const ArcHeader *)(uintptr_t)s_val - 1;
    double d = 0.0;
    if (!ocamlcc_parse_double((const char *)(uintptr_t)s_val,
                              (size_t)sh->reserved, &d)) {
        raise_failure_cstr("float_of_string", 15u);
        return 1;
    }
    return ocamlcc_alloc_float(d);
}

int64_t caml_int32_to_float(int64_t v)
{
    return ocamlcc_alloc_float((double)(int32_t)unbox_custom_i64(v));
}

int64_t caml_int32_of_float(int64_t v)
{
    return ocamlcc_alloc_custom(ARC_CUSTOM_INT32,
                                (uint64_t)(int64_t)(int32_t)unbox_float(v));
}

int64_t caml_int32_bits_of_float(int64_t v)
{
    double d = unbox_float(v);
    float f = (float)d;
    uint32_t bits = 0;
    pal_memcpy(&bits, &f, sizeof(bits));
    return ocamlcc_alloc_custom(ARC_CUSTOM_INT32, (uint64_t)(int64_t)(int32_t)bits);
}

int64_t caml_int32_float_of_bits(int64_t v)
{
    uint32_t bits = (uint32_t)(int32_t)unbox_custom_i64(v);
    float f = 0.0f;
    pal_memcpy(&f, &bits, sizeof(f));
    return ocamlcc_alloc_float((double)f);
}

int64_t caml_int64_to_float(int64_t v)
{
    return ocamlcc_alloc_float((double)unbox_custom_i64(v));
}

int64_t caml_int64_of_float(int64_t v)
{
    return ocamlcc_alloc_custom(ARC_CUSTOM_INT64, (uint64_t)(int64_t)unbox_float(v));
}

int64_t caml_int64_bits_of_float(int64_t v)
{
    uint64_t bits = 0;
    pal_memcpy(&bits, (const void *)(uintptr_t)v, sizeof(bits));
    return ocamlcc_alloc_custom(ARC_CUSTOM_INT64, bits);
}

int64_t caml_int64_float_of_bits(int64_t v)
{
    double d = 0.0;
    uint64_t bits = (uint64_t)unbox_custom_i64(v);
    pal_memcpy(&d, &bits, sizeof(d));
    return ocamlcc_alloc_float(d);
}

int64_t caml_nativeint_to_float(int64_t v)
{
    return ocamlcc_alloc_float((double)unbox_custom_i64(v));
}

int64_t caml_nativeint_of_float(int64_t v)
{
    return ocamlcc_alloc_custom(ARC_CUSTOM_NATIVEINT, (uint64_t)(int64_t)unbox_float(v));
}

int64_t caml_sqrt_float(int64_t v)
{
    return ocamlcc_alloc_float(ocamlcc_c_sqrt(unbox_float(v)));
}

int64_t caml_floor_float(int64_t v)
{
    return ocamlcc_alloc_float(ocamlcc_c_floor(unbox_float(v)));
}

int64_t caml_ceil_float(int64_t v)
{
    return ocamlcc_alloc_float(ocamlcc_c_ceil(unbox_float(v)));
}

int64_t caml_fmod_float(int64_t a, int64_t b)
{
    return ocamlcc_alloc_float(ocamlcc_c_fmod(unbox_float(a), unbox_float(b)));
}

int64_t caml_copysign_float(int64_t a, int64_t b)
{
    return ocamlcc_alloc_float(ocamlcc_c_copysign(unbox_float(a), unbox_float(b)));
}

int64_t caml_classify_float(int64_t v)
{
    return tag_int((int64_t)ocamlcc_c_fpclassify(unbox_float(v)));
}

int64_t ocamlcc_print_endline_val(int64_t val)
{
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)val - 1;
    ocamlcc_print_endline((const char *)(uintptr_t)val, (size_t)hdr->reserved);
    return 1;
}

void ocamlcc_exit_val(int64_t val)
{
    ocamlcc_exit(val >> 1);
}

/* ------------------------------------------------------------------ */
/* Bytes / String runtime primitives                                   */
/* ------------------------------------------------------------------ */

static int bytes_compare_raw(int64_t a, int64_t b)
{
    if (a == b)
        return 0;
    const ArcHeader *ha = (const ArcHeader *)(uintptr_t)a - 1;
    const ArcHeader *hb = (const ArcHeader *)(uintptr_t)b - 1;
    uint32_t la = ha->reserved;
    uint32_t lb = hb->reserved;
    uint32_t minlen = (la < lb) ? la : lb;
    const uint8_t *sa = (const uint8_t *)(uintptr_t)a;
    const uint8_t *sb = (const uint8_t *)(uintptr_t)b;
    for (uint32_t i = 0; i < minlen; i++) {
        if (sa[i] != sb[i])
            return (sa[i] < sb[i]) ? -1 : 1;
    }
    if (la != lb)
        return (la < lb) ? -1 : 1;
    return 0;
}

static inline int slice_in_bounds(int64_t ofs, int64_t len, uint64_t cap)
{
    return ofs >= 0 && len >= 0 && (uint64_t)ofs <= cap &&
           (uint64_t)len <= cap - (uint64_t)ofs;
}

/* ------------------------------------------------------------------ */
/* Polymorphic structural comparison & bounded hashing                 */
/* ------------------------------------------------------------------ */

/* C recursion depth is bounded so cyclic records cannot smash the C
 * stack; the shared step budget bounds tail-iterated cycles (e.g. cyclic
 * lists), which would otherwise spin forever without growing the stack. */
#define COMPARE_MAX_DEPTH 10000
#define COMPARE_MAX_STEPS 100000000LL

DEFINE_IMMORTAL_STR(g_inv_arg_cyc_str, "compare: cyclic structure");

enum { CMP_LESS = -1, CMP_EQUAL = 0, CMP_GREATER = 1, CMP_UNORDERED = 2 };

static int is_nan_bits(uint64_t bits)
{
    return (bits & 0x7fffffffffffffffULL) > 0x7ff0000000000000ULL;
}

static __attribute__((noinline)) int compare_f64_raw(double da, double db, int total)
{
    uint64_t ba = 0, bb = 0;
    pal_memcpy(&ba, &da, sizeof(ba));
    pal_memcpy(&bb, &db, sizeof(bb));
    int na = is_nan_bits(ba);
    int nb = is_nan_bits(bb);
    if (!total && (na || nb))
        return CMP_UNORDERED;
    if (na) {
        if (nb)
            return CMP_EQUAL;
        return -1;
    }
    if (nb)
        return 1;
    if (da < db)
        return -1;
    if (da > db)
        return 1;
    return 0;
}

static __attribute__((noinline)) int compare_float_arrays_raw(
    int64_t a, int64_t b, uint32_t fa, uint32_t fb, int total)
{
    if (fa != fb)
        return (fa < fb) ? -1 : 1;
    const double *pa = (const double *)(uintptr_t)a;
    const double *pb = (const double *)(uintptr_t)b;
    for (uint32_t i = 0; i < fa; i++) {
        int c = compare_f64_raw(pa[i], pb[i], total);
        if (c != 0)
            return c;
    }
    return 0;
}

static int64_t follow_forward(int64_t v, int64_t *steps)
{
    while (is_heap_ptr(v) &&
           ((const ArcHeader *)(uintptr_t)v - 1)->tag == (uint16_t)ARC_TAG_FORWARD) {
        if (*steps <= 0) {
            raise_invalid_arg_imm(g_inv_arg_cyc_str.str);
            return 0;
        }
        (*steps)--;
        v = ((const int64_t *)(uintptr_t)v)[0];
    }
    return v;
}

static int val_compare_raw(int64_t a, int64_t b, int total, int depth,
                           int64_t *steps)
{
    for (;;) {
        if (*steps <= 0) {
            raise_invalid_arg_imm(g_inv_arg_cyc_str.str);
            return 1;
        }
        (*steps)--;
        a = follow_forward(a, steps);
        if (ocamlcc_get_exn() != 0) return 1;
        b = follow_forward(b, steps);
        if (ocamlcc_get_exn() != 0) return 1;
        if (a == b && (total || !is_heap_ptr(a)))
            return 0;
        int ia = (a & 1) != 0;
        int ib = (b & 1) != 0;
        if (ia && ib)
            return (a < b) ? -1 : 1;
        if (ia)
            return -1;
        if (ib)
            return 1;

        const ArcHeader *ha = (const ArcHeader *)(uintptr_t)a - 1;
        const ArcHeader *hb = (const ArcHeader *)(uintptr_t)b - 1;
        uint16_t ta = ha->tag == ARC_TAG_ARRAY || (ha->tag == ARC_TAG_FLOAT_ARRAY && ha->byte_size == 0) ? 0 : ha->tag;
        uint16_t tb = hb->tag == ARC_TAG_ARRAY || (hb->tag == ARC_TAG_FLOAT_ARRAY && hb->byte_size == 0) ? 0 : hb->tag;
        /* A partial application also represents an OCaml function. */
        if ((ta == ARC_TAG_CLOSURE || ta == ARC_TAG_PAP) &&
            (tb == ARC_TAG_CLOSURE || tb == ARC_TAG_PAP)) {
            raise_invalid_arg_imm(g_inv_arg_fn_str.str);
            return 1;
        }
        if (ta != tb)
            return (ta < tb) ? -1 : 1;

        if (ta == (uint16_t)ARC_TAG_STRING)
            return bytes_compare_raw(a, b);
        if (ta == (uint16_t)ARC_TAG_FLOAT)
            return compare_f64_raw(unbox_float(a), unbox_float(b), total);
        if (ta == (uint16_t)ARC_TAG_FLOAT_ARRAY) {
            return compare_float_arrays_raw(
                a, b, ha->byte_size / 8u, hb->byte_size / 8u, total);
        }
        if (ta == (uint16_t)ARC_TAG_CUSTOM) {
            if (ha->reserved != hb->reserved)
                return (ha->reserved < hb->reserved) ? -1 : 1;
            if (ha->reserved == ARC_CUSTOM_BIGARRAY)
                return ba_compare((void *)(uintptr_t)a, (void *)(uintptr_t)b, total);
            if (ha->reserved == ARC_CUSTOM_INT32 ||
                ha->reserved == ARC_CUSTOM_INT64 ||
                ha->reserved == ARC_CUSTOM_NATIVEINT) {
                int64_t va = unbox_custom_i64(a);
                int64_t vb = unbox_custom_i64(b);
                return (va < vb) ? -1 : (va > vb ? 1 : 0);
            }
            raise_invalid_arg_imm(g_inv_arg_fn_str.str);
            return 1;
        }

        /* Objects and extension constructors compare by their unique OID,
           without following method tables or potentially cyclic fields. */
        if (ta == 248u && ha->byte_size >= 16 && hb->byte_size >= 16) {
            int64_t x = ((const int64_t *)(uintptr_t)a)[1];
            int64_t y = ((const int64_t *)(uintptr_t)b)[1];
            return x < y ? -1 : x > y ? 1 : 0;
        }

        if (ta == (uint16_t)ARC_TAG_ARRAY || ta == 248u || ta < 245u) {
            uint32_t fa = ha->byte_size / 8u;
            uint32_t fb = hb->byte_size / 8u;
            if (fa != fb)
                return (fa < fb) ? -1 : 1;
            if (fa == 0u)
                return 0;
            if (depth >= COMPARE_MAX_DEPTH) {
                raise_invalid_arg_imm(g_inv_arg_cyc_str.str);
                return 1;
            }
            const int64_t *pa = (const int64_t *)(uintptr_t)a;
            const int64_t *pb = (const int64_t *)(uintptr_t)b;
            for (uint32_t i = 0; i + 1u < fa; i++) {
                int c = val_compare_raw(pa[i], pb[i], total, depth + 1, steps);
                if (c != 0)
                    return c;
            }
            /* Tail-iterate on the last field so long lists compare in O(1) stack. */
            a = pa[fa - 1u];
            b = pb[fb - 1u];
            continue;
        }

        /* Runtime handles compare by identity. */
        uintptr_t ua = (uintptr_t)a;
        uintptr_t ub = (uintptr_t)b;
        return ua < ub ? -1 : ua > ub ? 1 : 0;
    }
}

static int val_compare(int64_t a, int64_t b, int total)
{
    int64_t steps = COMPARE_MAX_STEPS;
    return val_compare_raw(a, b, total, 0, &steps);
}

int64_t caml_compare(int64_t a, int64_t b)
{
    int c = val_compare(a, b, 1);
    return tag_int((int64_t)c);
}

int64_t caml_equal(int64_t a, int64_t b)
{
    return (val_compare(a, b, 0) == 0) ? 3 : 1;
}

int64_t caml_notequal(int64_t a, int64_t b)
{
    return (val_compare(a, b, 0) != 0) ? 3 : 1;
}

int64_t caml_lessthan(int64_t a, int64_t b)
{
    return (val_compare(a, b, 0) == CMP_LESS) ? 3 : 1;
}

int64_t caml_lessequal(int64_t a, int64_t b)
{
    int c = val_compare(a, b, 0);
    return (c == CMP_LESS || c == CMP_EQUAL) ? 3 : 1;
}

int64_t caml_greaterthan(int64_t a, int64_t b)
{
    return (val_compare(a, b, 0) == CMP_GREATER) ? 3 : 1;
}

int64_t caml_greaterequal(int64_t a, int64_t b)
{
    int c = val_compare(a, b, 0);
    return (c == CMP_GREATER || c == CMP_EQUAL) ? 3 : 1;
}

static uint32_t hash_mix32(uint32_t h, uint32_t d)
{
    d *= 0xcc9e2d51u;
    d = (d << 15) | (d >> 17);
    d *= 0x1b873593u;
    h ^= d;
    h = (h << 13) | (h >> 19);
    return h * 5u + 0xe6546b64u;
}

static uint32_t hash_mix_intnat(uint32_t h, int64_t d)
{
    uint32_t n = (uint32_t)(((uint64_t)(d >> 32)) ^ ((uint64_t)(d >> 63)) ^
                            (uint64_t)d);
    return hash_mix32(h, n);
}

static uint32_t hash_mix_int64(uint32_t h, int64_t d)
{
    uint32_t lo = (uint32_t)d;
    uint32_t hi = (uint32_t)((uint64_t)d >> 32);
    h = hash_mix32(h, lo);
    return hash_mix32(h, hi);
}

static uint32_t hash_mix_f64(uint32_t h, double d)
{
    uint64_t bits = 0;
    pal_memcpy(&bits, &d, sizeof(bits));
    uint32_t lo = (uint32_t)bits;
    uint32_t hi = (uint32_t)(bits >> 32);
    if ((hi & 0x7FF00000u) == 0x7FF00000u && (lo | (hi & 0xFFFFFu)) != 0u) {
        hi = 0x7FF00000u;
        lo = 0x00000001u;
    } else if (hi == 0x80000000u && lo == 0u) {
        hi = 0u;
    }
    h = hash_mix32(h, lo);
    return hash_mix32(h, hi);
}

static uint32_t hash_mix_string(uint32_t h, int64_t v)
{
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)v - 1;
    uint32_t len = hdr->reserved;
    const uint8_t *s = (const uint8_t *)(uintptr_t)v;
    uint32_t i = 0;
    while (i + 4u <= len) {
        uint32_t w = (uint32_t)s[i] |
                     ((uint32_t)s[i + 1u] << 8) |
                     ((uint32_t)s[i + 2u] << 16) |
                     ((uint32_t)s[i + 3u] << 24);
        h = hash_mix32(h, w);
        i += 4u;
    }
    uint32_t rem = 0;
    switch (len & 3u) {
    case 3u: rem |= (uint32_t)s[i + 2u] << 16; /* fallthrough */
    case 2u: rem |= (uint32_t)s[i + 1u] << 8;  /* fallthrough */
    case 1u:
        rem |= (uint32_t)s[i];
        h = hash_mix32(h, rem);
        break;
    default:
        break;
    }
    h ^= len;
    return h;
}

static uint32_t hash_final_mix(uint32_t h)
{
    h ^= h >> 16;
    h *= 0x85ebca6bu;
    h ^= h >> 13;
    h *= 0xc2b2ae35u;
    h ^= h >> 16;
    return h;
}

int64_t caml_hash(int64_t count_val, int64_t limit_val,
                  int64_t seed_val, int64_t obj)
{
    int64_t num = count_val >> 1;
    int64_t sz = limit_val >> 1;
    if (sz < 0 || sz > 256)
        sz = 256;
    uint32_t h = (uint32_t)(seed_val >> 1);

    int64_t queue[256];
    int64_t rd = 0;
    int64_t wr = 1;
    queue[0] = obj;

    while (rd < wr && num > 0) {
        int64_t v = queue[rd++];
    again:
        if ((v & 1) != 0) {
            h = hash_mix_intnat(h, v);
            num--;
        } else {
            const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)v - 1;
            uint16_t tag = hdr->tag;
            if (tag == (uint16_t)ARC_TAG_STRING) {
                h = hash_mix_string(h, v);
                num--;
            } else if (tag == (uint16_t)ARC_TAG_FLOAT) {
                h = hash_mix_f64(h, unbox_float(v));
                num--;
            } else if (tag == (uint16_t)ARC_TAG_FLOAT_ARRAY && hdr->byte_size == 0) {
                h = hash_mix32(h, 0);
            } else if (tag == (uint16_t)ARC_TAG_FLOAT_ARRAY) {
                uint32_t nf = hdr->byte_size / 8u;
                const double *fa = (const double *)(uintptr_t)v;
                for (uint32_t i = 0; i < nf; i++) {
                    h = hash_mix_f64(h, fa[i]);
                    num--;
                    if (num <= 0)
                        break;
                }
            } else if (tag == (uint16_t)ARC_TAG_FORWARD) {
                int64_t steps = 1000;
                int ok = 0;
                while (steps > 0) {
                    v = ((const int64_t *)(uintptr_t)v)[0];
                    if ((v & 1) != 0 ||
                        ((const ArcHeader *)(uintptr_t)v - 1)->tag != (uint16_t)ARC_TAG_FORWARD) {
                        ok = 1;
                        break;
                    }
                    steps--;
                }
                if (ok)
                    goto again;
            } else if (tag == 248u) {
                /* Object_tag / exception constructor: mix Oid_val = Field(v, 1) */
                const int64_t *fields = (const int64_t *)(uintptr_t)v;
                h = hash_mix_intnat(h, fields[1]);
                num--;
            } else if (tag == (uint16_t)ARC_TAG_CUSTOM) {
                int64_t cv = unbox_custom_i64(v);
                if (hdr->reserved == ARC_CUSTOM_INT32 ||
                    hdr->reserved == ARC_CUSTOM_NATIVEINT) {
                    h = hash_mix_intnat(h, cv);
                    num--;
                } else if (hdr->reserved == ARC_CUSTOM_BIGARRAY) {
                    h = hash_mix_intnat(h, ba_hash((void *)(uintptr_t)v));
                    num--;
                } else if (hdr->reserved == ARC_CUSTOM_INT64) {
                    h = hash_mix_int64(h, cv);
                    num--;
                }
            } else if (tag == (uint16_t)ARC_TAG_ARRAY || tag < 245u) {
                uint32_t wosize = hdr->byte_size / 8u;
                h = hash_mix32(h, (wosize << 10) | (uint32_t)(tag == ARC_TAG_ARRAY ? 0 : tag));
                const int64_t *fields = (const int64_t *)(uintptr_t)v;
                for (uint32_t i = 0u; i < wosize; i++) {
                    if (wr >= sz)
                        break;
                    queue[wr++] = fields[i];
                }
            } else if (tag == (uint16_t)ARC_TAG_CLOSURE) {
                const ArcClosure *c = (const ArcClosure *)(uintptr_t)v;
                h = hash_mix32(h, (uint32_t)ARC_TAG_CLOSURE);
                h = hash_mix_intnat(h, (int64_t)(uintptr_t)c->code);
                num--;
            } else if (tag == (uint16_t)ARC_TAG_LAZY ||
                       tag == (uint16_t)ARC_TAG_FORCING) {
                uint32_t otag = (tag == (uint16_t)ARC_TAG_LAZY) ? 246u : 249u;
                uint32_t wosize = hdr->byte_size / 8u;
                h = hash_mix32(h, (wosize << 10) | otag);
                const int64_t *fields = (const int64_t *)(uintptr_t)v;
                for (uint32_t i = 0u; i < wosize; i++) {
                    if (wr >= sz)
                        break;
                    queue[wr++] = fields[i];
                }
            } else {
                /* Abstract/Channel/Other: do nothing */
            }
        }
    }

    h = hash_final_mix(h);
    return tag_int((int64_t)(h & 0x3fffffffu));
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

/* ------------------------------------------------------------------ */
/* Batch 1 Stdlib Primitives: Atomics, Bytes/Array, Channels, Runtime */
/* ------------------------------------------------------------------ */

extern int         ocamlcc_c_sys_open(const char *path, int flags_mask, int perm, int *err_out);
extern int64_t     ocamlcc_c_fd_read_raw(int fd, void *buf, size_t len, int *err_out);
extern int         ocamlcc_c_fd_write_all(int fd, const void *buf, size_t len, int *err_out);
extern int         ocamlcc_c_fd_lseek(int fd, int64_t off, int whence, int64_t *pos_out, int *err_out);
extern int         ocamlcc_c_fd_size(int fd, int64_t *size_out, int *err_out);
extern int         ocamlcc_c_fd_close_raw(int fd, int *err_out);
extern void        ocamlcc_c_fflush_stdio(int fd);
extern int         ocamlcc_c_isatty(int fd);
extern const char *ocamlcc_c_strerror(int err);

static void raise_sys_error_cstr(const char *msg)
{
    size_t len = 0u;
    while (msg[len] != '\0')
        len++;
    char *s = (char *)arc_alloc_bytes((uint64_t)len);
    if (len > 0u)
        pal_memcpy(s, msg, len);
    int64_t *blk = (int64_t *)arc_alloc(0u, 2u, 16u);
    blk[0] = (int64_t)(uintptr_t)ocamlcc_global_Sys_error;
    blk[1] = (int64_t)(uintptr_t)s;
    ocamlcc_set_exn((int64_t)(uintptr_t)blk);
}

static void raise_sys_error_errno(int err)
{
    const char *m = ocamlcc_c_strerror(err);
    raise_sys_error_cstr(m != NULL ? m : "system error");
}

/* ---- Named values / exit ---- */

static ArcSpinLock g_named_lock = { 0u };
static int64_t g_do_at_exit_fn = 0;

int64_t ocamlcc_set_at_exit_fn(int64_t val)
{
    arc_lock(&g_named_lock);
    int64_t old = g_do_at_exit_fn;
    arc_retain_val(val);
    g_do_at_exit_fn = val;
    arc_unlock(&g_named_lock);
    if (old != 0)
        arc_release_val(old);
    return 1;
}

void ocamlcc_run_at_exit(void)
{
    arc_lock(&g_named_lock);
    int64_t fn = g_do_at_exit_fn;
    if (fn != 0)
        arc_retain_val(fn);
    arc_unlock(&g_named_lock);
    if (fn != 0) {
        int64_t r = ocamlcc_apply1_raw(fn, 1);
        arc_release_val(r);
        arc_release_val(fn);
        if (ocamlcc_get_exn() != 0)
            ocamlcc_set_exn(0);
    }
    ocamlcc_c_fflush_stdio(1);
    ocamlcc_c_fflush_stdio(2);
}

void caml_sys_exit(int64_t code_val)
{
    ocamlcc_exit_val(code_val);
}

/* ---- Atomics ---- */

/* Readers must retain a heap value before any writer can detach it.
 * Keep destruction outside this lock. Integer fetch-add owns no pointers. */
static ArcSpinLock atomic_field_lock;

int64_t caml_atomic_load_field(int64_t obj_val, int64_t idx_val)
{
    int64_t idx = idx_val >> 1;
    _Atomic int64_t *slot = ((_Atomic int64_t *)(uintptr_t)obj_val) + idx;
    arc_lock(&atomic_field_lock);
    int64_t v = atomic_load_explicit(slot, memory_order_acquire);
    arc_retain_val(v);
    arc_unlock(&atomic_field_lock);
    return v;
}

int64_t caml_atomic_cas_field(int64_t obj_val, int64_t idx_val,
                              int64_t expected_val, int64_t desired_val)
{
    int64_t idx = idx_val >> 1;
    _Atomic int64_t *slot = ((_Atomic int64_t *)(uintptr_t)obj_val) + idx;
    arc_retain_val(desired_val);
    int64_t cur = expected_val;
    arc_lock(&atomic_field_lock);
    int changed = atomic_compare_exchange_strong_explicit(
        slot, &cur, desired_val, memory_order_acq_rel, memory_order_acquire);
    arc_unlock(&atomic_field_lock);
    arc_release_val(changed ? expected_val : desired_val);
    return changed ? 3 : 1;
}

int64_t caml_atomic_exchange_field(int64_t obj_val, int64_t idx_val,
                                   int64_t desired_val)
{
    int64_t idx = idx_val >> 1;
    _Atomic int64_t *slot = ((_Atomic int64_t *)(uintptr_t)obj_val) + idx;
    arc_retain_val(desired_val);
    arc_lock(&atomic_field_lock);
    int64_t old = atomic_exchange_explicit(slot, desired_val, memory_order_acq_rel);
    arc_unlock(&atomic_field_lock);
    return old;
}

int64_t caml_atomic_fetch_add_field(int64_t obj_val, int64_t idx_val,
                                    int64_t incr_val)
{
    int64_t idx = idx_val >> 1;
    _Atomic int64_t *slot = ((_Atomic int64_t *)(uintptr_t)obj_val) + idx;
    int64_t delta = (incr_val >> 1) * 2LL; /* preserve tagged low bit 1 */
    return atomic_fetch_add_explicit(slot, delta, memory_order_acq_rel);
}

static inline uint32_t arr_len_of(int64_t arr)
{
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)arr - 1;
    return hdr->byte_size / 8u;
}

/* ---- Raw POSIX fd hooks (channel buffering lives in CamlinternalChannel) ---- */

static int check_bytes_slice(int64_t buf_val, int64_t ofs_val, int64_t len_val,
                             int64_t *ofs_out, int64_t *len_out)
{
    int64_t o = ofs_val >> 1, n = len_val >> 1;
    const ArcHeader *bh = (const ArcHeader *)(uintptr_t)buf_val - 1;
    if (!slice_in_bounds(o, n, bh->reserved)) {
        raise_invalid_arg_imm(g_inv_arg_oob_str.str);
        return 0;
    }
    *ofs_out = o;
    *len_out = n;
    return 1;
}

int64_t caml_sys_open(int64_t path_val, int64_t flags_val, int64_t perm_val)
{
    const char *path = (const char *)(uintptr_t)path_val;
    int mask = 0;
    int64_t cur = flags_val;
    while (cur != 1) {
        const int64_t *cons = (const int64_t *)(uintptr_t)cur;
        int64_t ftag = cons[0] >> 1;
        switch (ftag) {
        case 0: mask |= 0x01; break; /* Open_rdonly */
        case 1: mask |= 0x02; break; /* Open_wronly */
        case 2: mask |= 0x04; break; /* Open_append */
        case 3: mask |= 0x08; break; /* Open_creat */
        case 4: mask |= 0x10; break; /* Open_trunc */
        case 5: mask |= 0x20; break; /* Open_excl */
        case 8: mask |= 0x40; break; /* Open_nonblock */
        default: break;
        }
        cur = cons[1];
    }
    int perm = (int)(perm_val >> 1);
    int err = 0;
    int fd = ocamlcc_c_sys_open(path, mask, perm, &err);
    if (fd < 0) {
        raise_sys_error_errno(err);
        return 1;
    }
    return tag_int((int64_t)fd);
}

int64_t ocamlcc_raw_fd_read(int64_t fd_val, int64_t buf_val,
                            int64_t ofs_val, int64_t len_val)
{
    int64_t o = 0, n = 0;
    if (!check_bytes_slice(buf_val, ofs_val, len_val, &o, &n))
        return 1;
    int err = 0;
    int64_t r = ocamlcc_c_fd_read_raw((int)(fd_val >> 1),
                                      (uint8_t *)(uintptr_t)buf_val + o,
                                      (size_t)n, &err);
    if (r < 0) {
        raise_sys_error_errno(err);
        return 1;
    }
    return tag_int(r);
}

int64_t ocamlcc_raw_fd_write(int64_t fd_val, int64_t buf_val,
                             int64_t ofs_val, int64_t len_val)
{
    int64_t o = 0, n = 0;
    if (!check_bytes_slice(buf_val, ofs_val, len_val, &o, &n))
        return 1;
    int err = 0;
    if (ocamlcc_c_fd_write_all((int)(fd_val >> 1),
                               (const uint8_t *)(uintptr_t)buf_val + o,
                               (size_t)n, &err) != 0)
        raise_sys_error_errno(err);
    return 1;
}

int64_t ocamlcc_raw_fd_lseek(int64_t fd_val, int64_t off_val, int64_t whence_val)
{
    int64_t pos = 0;
    int err = 0;
    if (ocamlcc_c_fd_lseek((int)(fd_val >> 1), unbox_custom_i64(off_val),
                           (int)(whence_val >> 1), &pos, &err) != 0) {
        raise_sys_error_errno(err);
        return 1;
    }
    return ocamlcc_alloc_custom(ARC_CUSTOM_INT64, (uint64_t)pos);
}

int64_t ocamlcc_raw_fd_size(int64_t fd_val)
{
    int64_t sz = 0;
    int err = 0;
    if (ocamlcc_c_fd_size((int)(fd_val >> 1), &sz, &err) != 0) {
        raise_sys_error_errno(err);
        return 1;
    }
    return ocamlcc_alloc_custom(ARC_CUSTOM_INT64, (uint64_t)sz);
}

int64_t ocamlcc_raw_fd_close(int64_t fd_val)
{
    int err = 0;
    if (ocamlcc_c_fd_close_raw((int)(fd_val >> 1), &err) != 0)
        raise_sys_error_errno(err);
    return 1;
}

int64_t ocamlcc_raw_fd_isatty(int64_t fd_val)
{
    return ocamlcc_c_isatty((int)(fd_val >> 1)) ? 3 : 1;
}

int64_t ocamlcc_stdio_flush(int64_t fd_val)
{
    ocamlcc_c_fflush_stdio((int)(fd_val >> 1));
    return 1;
}

/* ------------------------------------------------------------------ */
/* Batch 2 Stdlib Primitives: Obj, String Hash, Sys, Backtrace, Math, */
/* Digest, Sync, Floatarray                                           */
/* ------------------------------------------------------------------ */

extern int         ocamlcc_c_hexstring_of_float(char *out, size_t cap, double d, int64_t prec, char sign);
extern int         ocamlcc_c_file_exists(const char *path);
extern int         ocamlcc_c_stat_kind(const char *path, int *is_dir, int *is_reg, int *err_out);
extern int         ocamlcc_c_unlink(const char *path, int *err_out);
extern int         ocamlcc_c_rename(const char *oldp, const char *newp, int *err_out);
extern int         ocamlcc_c_chdir(const char *path, int *err_out);
extern int         ocamlcc_c_mkdir(const char *path, int mode, int *err_out);
extern int         ocamlcc_c_rmdir(const char *path, int *err_out);
extern char       *ocamlcc_c_getcwd(int *err_out);
extern const char *ocamlcc_c_getenv(const char *name);
extern int         ocamlcc_c_system(const char *cmd, int *err_out);
extern double      ocamlcc_c_sys_time(void);
extern int         ocamlcc_c_isatty(int fd);
extern int         ocamlcc_c_readdir_alloc(const char *path, char ***out_names, size_t *out_cnt, int *err_out);
extern void        ocamlcc_c_readdir_free(char **names, size_t cnt);
extern void        ocamlcc_c_free(void *p);

extern double ocamlcc_c_exp(double d);
extern double ocamlcc_c_exp2(double d);
extern double ocamlcc_c_expm1(double d);
extern double ocamlcc_c_log(double d);
extern double ocamlcc_c_log10(double d);
extern double ocamlcc_c_log2(double d);
extern double ocamlcc_c_log1p(double d);
extern double ocamlcc_c_pow(double a, double b);
extern double ocamlcc_c_sin(double d);
extern double ocamlcc_c_cos(double d);
extern double ocamlcc_c_tan(double d);
extern double ocamlcc_c_asin(double d);
extern double ocamlcc_c_acos(double d);
extern double ocamlcc_c_atan(double d);
extern double ocamlcc_c_atan2(double a, double b);
extern double ocamlcc_c_sinh(double d);
extern double ocamlcc_c_cosh(double d);
extern double ocamlcc_c_tanh(double d);
extern double ocamlcc_c_asinh(double d);
extern double ocamlcc_c_acosh(double d);
extern double ocamlcc_c_atanh(double d);
extern double ocamlcc_c_cbrt(double d);
extern double ocamlcc_c_hypot(double a, double b);
extern double ocamlcc_c_fma(double a, double b, double c);
extern double ocamlcc_c_erf(double d);
extern double ocamlcc_c_erfc(double d);
extern double ocamlcc_c_trunc(double d);
extern double ocamlcc_c_round(double d);
extern int    ocamlcc_c_signbit(double d);
extern double ocamlcc_c_nextafter(double a, double b);
extern double ocamlcc_c_frexp(double d, int *exp_out);
extern double ocamlcc_c_ldexp(double d, int exp_v);
extern double ocamlcc_c_modf(double d, double *iptr_out);

extern void *ocamlcc_c_mutex_new(void);
extern int   ocamlcc_c_mutex_lock(void *p);
extern int   ocamlcc_c_mutex_trylock(void *p);
extern int   ocamlcc_c_mutex_unlock(void *p);
extern void *ocamlcc_c_cond_new(void);
extern int   ocamlcc_c_cond_wait(void *c, void *m);
extern int   ocamlcc_c_cond_signal(void *c);
extern int   ocamlcc_c_cond_broadcast(void *c);

extern int   ocamlcc_c_random_bytes(uint8_t *buf, size_t len);
extern int   ocamlcc_c_is_win32(void);

static int64_t alloc_cstr_z(const char *s)
{
    size_t n = 0u;
    if (s != NULL) {
        while (s[n] != '\0') n++;
    }
    char *out = (char *)arc_alloc_bytes((uint64_t)n);
    if (n > 0u)
        pal_memcpy(out, s, n);
    return (int64_t)(uintptr_t)out;
}

/* ---- Obj / String Hash / Hexfloat / Atomic contended ---- */

int64_t caml_obj_tag(int64_t v)
{
    if (!is_heap_ptr(v))
        return tag_int(1000); /* Int_tag */
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)v - 1;
    uint16_t t = hdr->tag;
    if (t == (uint16_t)ARC_TAG_ARRAY)
        return tag_int(0);
    if (t == (uint16_t)ARC_TAG_CLOSURE || t == (uint16_t)ARC_TAG_PAP)
        return tag_int(247);
    if (t == (uint16_t)ARC_TAG_STRING)
        return tag_int(252);
    if (t == (uint16_t)ARC_TAG_FLOAT)
        return tag_int(253);
    if (t == (uint16_t)ARC_TAG_FLOAT_ARRAY)
        return tag_int(254);
    if (t == (uint16_t)ARC_TAG_CUSTOM)
        return tag_int(255);
    if (t == (uint16_t)ARC_TAG_LAZY)
        return tag_int(246);
    if (t == (uint16_t)ARC_TAG_FORCING)
        return tag_int(249);
    if (t == (uint16_t)ARC_TAG_FORWARD)
        return tag_int(250);
    return tag_int((int64_t)t);
}

int64_t caml_hexstring_of_float(int64_t f_val, int64_t prec_val, int64_t sign_val)
{
    char buf[128];
    int n = ocamlcc_c_hexstring_of_float(
        buf, sizeof(buf), unbox_float(f_val), prec_val >> 1, (char)(sign_val >> 1));
    return alloc_c_string_buf(buf, n);
}

int64_t caml_atomic_make_contended(int64_t v)
{
    int64_t *blk = (int64_t *)arc_alloc(0u, 1u, 8u);
    arc_retain_val(v);
    blk[0] = v;
    return (int64_t)(uintptr_t)blk;
}

/* ---- Sys / Env / FS / Runtime (constants/backtraces/Callback in CamlinternalSys) ---- */

static int    g_argc = 0;
static char **g_argv = NULL;

void ocamlcc_set_argv(int argc, char **argv)
{
    g_argc = argc;
    g_argv = argv;
}

int64_t ocamlcc_sys_is_win32(int64_t ignored)
{
    (void)ignored;
    return ocamlcc_c_is_win32() ? 3 : 1;
}

int64_t caml_sys_argv(int64_t ignored)
{
    (void)ignored;
    int n = (g_argc > 0 && g_argv != NULL) ? g_argc : 1;
    int64_t *arr = (int64_t *)arc_alloc(
        (uint16_t)ARC_TAG_ARRAY, 0u, (uint32_t)((uint64_t)n * 8u));
    if (g_argc > 0 && g_argv != NULL) {
        for (int i = 0; i < n; i++)
            arr[i] = alloc_cstr_z(g_argv[i]);
    } else {
        arr[0] = alloc_cstr_z("");
    }
    return (int64_t)(uintptr_t)arr;
}

int64_t caml_sys_getenv(int64_t name_val)
{
    const char *v = ocamlcc_c_getenv((const char *)(uintptr_t)name_val);
    if (v == NULL) {
        ocamlcc_set_exn((int64_t)(uintptr_t)ocamlcc_global_Not_found);
        return 1;
    }
    return alloc_cstr_z(v);
}

int64_t caml_sys_getenv_opt(int64_t name_val)
{
    const char *v = ocamlcc_c_getenv((const char *)(uintptr_t)name_val);
    if (v == NULL)
        return 1; /* None */
    int64_t *some = (int64_t *)arc_alloc(0u, 1u, 8u);
    some[0] = alloc_cstr_z(v);
    return (int64_t)(uintptr_t)some;
}

int64_t caml_sys_file_exists(int64_t path_val)
{
    return ocamlcc_c_file_exists((const char *)(uintptr_t)path_val) ? 3 : 1;
}

int64_t caml_sys_is_directory(int64_t path_val)
{
    int is_dir = 0, is_reg = 0, err = 0;
    if (ocamlcc_c_stat_kind((const char *)(uintptr_t)path_val, &is_dir, &is_reg, &err) != 0) {
        raise_sys_error_errno(err);
        return 1;
    }
    return is_dir ? 3 : 1;
}

int64_t caml_sys_is_regular_file(int64_t path_val)
{
    int is_dir = 0, is_reg = 0, err = 0;
    if (ocamlcc_c_stat_kind((const char *)(uintptr_t)path_val, &is_dir, &is_reg, &err) != 0) {
        raise_sys_error_errno(err);
        return 1;
    }
    return is_reg ? 3 : 1;
}

int64_t caml_sys_remove(int64_t path_val)
{
    int err = 0;
    if (ocamlcc_c_unlink((const char *)(uintptr_t)path_val, &err) != 0)
        raise_sys_error_errno(err);
    return 1;
}

int64_t caml_sys_rename(int64_t old_val, int64_t new_val)
{
    int err = 0;
    if (ocamlcc_c_rename((const char *)(uintptr_t)old_val,
                         (const char *)(uintptr_t)new_val, &err) != 0)
        raise_sys_error_errno(err);
    return 1;
}

int64_t caml_sys_chdir(int64_t path_val)
{
    int err = 0;
    if (ocamlcc_c_chdir((const char *)(uintptr_t)path_val, &err) != 0)
        raise_sys_error_errno(err);
    return 1;
}

int64_t caml_sys_mkdir(int64_t path_val, int64_t mode_val)
{
    int err = 0;
    if (ocamlcc_c_mkdir((const char *)(uintptr_t)path_val, (int)(mode_val >> 1), &err) != 0)
        raise_sys_error_errno(err);
    return 1;
}

int64_t caml_sys_rmdir(int64_t path_val)
{
    int err = 0;
    if (ocamlcc_c_rmdir((const char *)(uintptr_t)path_val, &err) != 0)
        raise_sys_error_errno(err);
    return 1;
}

int64_t caml_sys_getcwd(int64_t ignored)
{
    (void)ignored;
    int err = 0;
    char *p = ocamlcc_c_getcwd(&err);
    if (p == NULL) {
        raise_sys_error_errno(err);
        return 1;
    }
    int64_t s = alloc_cstr_z(p);
    ocamlcc_c_free(p);
    return s;
}

int64_t caml_sys_read_directory(int64_t path_val)
{
    char **names = NULL;
    size_t cnt = 0u;
    int err = 0;
    if (ocamlcc_c_readdir_alloc((const char *)(uintptr_t)path_val, &names, &cnt, &err) != 0) {
        raise_sys_error_errno(err);
        return 1;
    }
    if (cnt == 0u) {
        ocamlcc_c_readdir_free(names, cnt);
        return (int64_t)(uintptr_t)arc_alloc((uint16_t)ARC_TAG_ARRAY, 0u, 0u);
    }
    int64_t *arr = (int64_t *)arc_alloc(
        (uint16_t)ARC_TAG_ARRAY, 0u, (uint32_t)((uint64_t)cnt * 8u));
    for (size_t i = 0u; i < cnt; i++)
        arr[i] = alloc_cstr_z(names[i]);
    ocamlcc_c_readdir_free(names, cnt);
    return (int64_t)(uintptr_t)arr;
}

int64_t caml_sys_system_command(int64_t cmd_val)
{
    int err = 0;
    int rc = ocamlcc_c_system((const char *)(uintptr_t)cmd_val, &err);
    if (rc < 0) {
        raise_sys_error_errno(err);
        return 1;
    }
    return tag_int((int64_t)rc);
}

int64_t caml_sys_time(int64_t ignored)
{
    (void)ignored;
    return ocamlcc_alloc_float(ocamlcc_c_sys_time());
}

int64_t caml_sys_close(int64_t fd_val)
{
    int err = 0;
    if (ocamlcc_c_fd_close_raw((int)(fd_val >> 1), &err) != 0)
        raise_sys_error_errno(err);
    return 1;
}

int64_t caml_sys_random_seed(int64_t ignored)
{
    (void)ignored;
    uint32_t words[4];
    if (ocamlcc_c_random_bytes((uint8_t *)words, sizeof(words)) != 0) {
        uint64_t ns = pal_monotonic_ns();
        words[0] = (uint32_t)ns;
        words[1] = (uint32_t)(ns >> 16);
        words[2] = (uint32_t)(ns * 6364136223846793005ULL);
        words[3] = (uint32_t)((ns >> 32) ^ 0x9e3779b9ULL);
    }
    int64_t *arr = (int64_t *)arc_alloc((uint16_t)ARC_TAG_ARRAY, 0u, 32u);
    for (int i = 0; i < 4; i++)
        arr[i] = tag_int((int64_t)(words[i] & 0x3fffffffu));
    return (int64_t)(uintptr_t)arr;
}

/* ---- libm math ---- */

#define DEF_FLOAT_UNOP(caml_name, c_fn) \
    int64_t caml_name(int64_t v) { return ocamlcc_alloc_float(c_fn(unbox_float(v))); }
#define DEF_FLOAT_BINOP(caml_name, c_fn) \
    int64_t caml_name(int64_t a, int64_t b) { return ocamlcc_alloc_float(c_fn(unbox_float(a), unbox_float(b))); }

DEF_FLOAT_UNOP(caml_exp_float, ocamlcc_c_exp)
DEF_FLOAT_UNOP(caml_exp2_float, ocamlcc_c_exp2)
DEF_FLOAT_UNOP(caml_expm1_float, ocamlcc_c_expm1)
DEF_FLOAT_UNOP(caml_log_float, ocamlcc_c_log)
DEF_FLOAT_UNOP(caml_log10_float, ocamlcc_c_log10)
DEF_FLOAT_UNOP(caml_log2_float, ocamlcc_c_log2)
DEF_FLOAT_UNOP(caml_log1p_float, ocamlcc_c_log1p)
DEF_FLOAT_BINOP(caml_power_float, ocamlcc_c_pow)
DEF_FLOAT_UNOP(caml_sin_float, ocamlcc_c_sin)
DEF_FLOAT_UNOP(caml_cos_float, ocamlcc_c_cos)
DEF_FLOAT_UNOP(caml_tan_float, ocamlcc_c_tan)
DEF_FLOAT_UNOP(caml_asin_float, ocamlcc_c_asin)
DEF_FLOAT_UNOP(caml_acos_float, ocamlcc_c_acos)
DEF_FLOAT_UNOP(caml_atan_float, ocamlcc_c_atan)
DEF_FLOAT_BINOP(caml_atan2_float, ocamlcc_c_atan2)
DEF_FLOAT_UNOP(caml_sinh_float, ocamlcc_c_sinh)
DEF_FLOAT_UNOP(caml_cosh_float, ocamlcc_c_cosh)
DEF_FLOAT_UNOP(caml_tanh_float, ocamlcc_c_tanh)
DEF_FLOAT_UNOP(caml_asinh_float, ocamlcc_c_asinh)
DEF_FLOAT_UNOP(caml_acosh_float, ocamlcc_c_acosh)
DEF_FLOAT_UNOP(caml_atanh_float, ocamlcc_c_atanh)
DEF_FLOAT_UNOP(caml_cbrt_float, ocamlcc_c_cbrt)
DEF_FLOAT_BINOP(caml_hypot_float, ocamlcc_c_hypot)
DEF_FLOAT_UNOP(caml_erf_float, ocamlcc_c_erf)
DEF_FLOAT_UNOP(caml_erfc_float, ocamlcc_c_erfc)
DEF_FLOAT_UNOP(caml_trunc_float, ocamlcc_c_trunc)
DEF_FLOAT_UNOP(caml_round_float, ocamlcc_c_round)
DEF_FLOAT_BINOP(caml_nextafter_float, ocamlcc_c_nextafter)

int64_t caml_fma_float(int64_t a, int64_t b, int64_t c)
{
    return ocamlcc_alloc_float(ocamlcc_c_fma(unbox_float(a), unbox_float(b), unbox_float(c)));
}

int64_t caml_signbit_float(int64_t v)
{
    return ocamlcc_c_signbit(unbox_float(v)) ? 3 : 1;
}

int64_t caml_frexp_float(int64_t v)
{
    int e = 0;
    double m = ocamlcc_c_frexp(unbox_float(v), &e);
    int64_t *pair = (int64_t *)arc_alloc(0u, 2u, 16u);
    pair[0] = ocamlcc_alloc_float(m);
    pair[1] = tag_int((int64_t)e);
    return (int64_t)(uintptr_t)pair;
}

int64_t caml_ldexp_float(int64_t v, int64_t e_val)
{
    return ocamlcc_alloc_float(ocamlcc_c_ldexp(unbox_float(v), (int)(e_val >> 1)));
}

int64_t caml_modf_float(int64_t v)
{
    double ip = 0.0;
    double fp = ocamlcc_c_modf(unbox_float(v), &ip);
    int64_t *pair = (int64_t *)arc_alloc(0u, 2u, 16u);
    pair[0] = ocamlcc_alloc_float(fp);
    pair[1] = ocamlcc_alloc_float(ip);
    return (int64_t)(uintptr_t)pair;
}

/* ---- Sync: Mutex & Condition ---- */

int64_t caml_ml_mutex_new(int64_t ignored)
{
    (void)ignored;
    void *m = ocamlcc_c_mutex_new();
    if (m == NULL) pal_abort();
    return ocamlcc_alloc_custom(ARC_CUSTOM_MUTEX, (uint64_t)(uintptr_t)m);
}

int64_t caml_ml_mutex_lock(int64_t m_val)
{
    void *m = (void *)(uintptr_t)unbox_custom_i64(m_val);
    int entered = tls_os_mutator_active;
    if (entered)
        arc_mutator_leave(1);
    int rc = ocamlcc_c_mutex_lock(m);
    if (entered)
        (void)arc_mutator_enter();
    if (rc != 0)
        raise_sys_error_errno(rc);
    return 1;
}

int64_t caml_ml_mutex_try_lock(int64_t m_val)
{
    void *m = (void *)(uintptr_t)unbox_custom_i64(m_val);
    return (ocamlcc_c_mutex_trylock(m) == 0) ? 3 : 1;
}

int64_t caml_ml_mutex_unlock(int64_t m_val)
{
    void *m = (void *)(uintptr_t)unbox_custom_i64(m_val);
    int rc = ocamlcc_c_mutex_unlock(m);
    if (rc != 0)
        raise_sys_error_errno(rc);
    return 1;
}

int64_t caml_ml_condition_new(int64_t ignored)
{
    (void)ignored;
    void *c = ocamlcc_c_cond_new();
    if (c == NULL) pal_abort();
    return ocamlcc_alloc_custom(ARC_CUSTOM_COND, (uint64_t)(uintptr_t)c);
}

int64_t caml_ml_condition_wait(int64_t c_val, int64_t m_val)
{
    void *c = (void *)(uintptr_t)unbox_custom_i64(c_val);
    void *m = (void *)(uintptr_t)unbox_custom_i64(m_val);
    int entered = tls_os_mutator_active;
    if (entered)
        arc_mutator_leave(1);
    int rc = ocamlcc_c_cond_wait(c, m);
    if (entered)
        (void)arc_mutator_enter();
    if (rc != 0)
        raise_sys_error_errno(rc);
    return 1;
}

int64_t caml_ml_condition_signal(int64_t c_val)
{
    void *c = (void *)(uintptr_t)unbox_custom_i64(c_val);
    (void)ocamlcc_c_cond_signal(c);
    return 1;
}

int64_t caml_ml_condition_broadcast(int64_t c_val)
{
    void *c = (void *)(uintptr_t)unbox_custom_i64(c_val);
    (void)ocamlcc_c_cond_broadcast(c);
    return 1;
}

/* ---- Computed field ops & channel/bigarray helpers ---- */

int64_t caml_obj_field(int64_t obj_val, int64_t idx_val)
{
    int64_t idx = idx_val >> 1;
    const int64_t *fields = (const int64_t *)(uintptr_t)obj_val;
    int64_t v = fields[idx];
    arc_retain_val(v);
    return v;
}

int64_t caml_obj_set_field(int64_t obj_val, int64_t idx_val, int64_t new_val)
{
    int64_t idx = idx_val >> 1;
    int64_t *fields = (int64_t *)(uintptr_t)obj_val;
    int64_t old_v = fields[idx];
    arc_retain_val(new_val);
    fields[idx] = new_val;
    arc_release_val(old_v);
    return 1;
}

#include "bigarray.inc"


/* ---- Lazy & Obj primitives ---- */

static inline uint16_t map_ocaml_tag_to_arc(int64_t ocaml_tag)
{
    if (ocaml_tag == 246) return (uint16_t)ARC_TAG_LAZY;
    if (ocaml_tag == 249) return (uint16_t)ARC_TAG_FORCING;
    if (ocaml_tag == 250) return (uint16_t)ARC_TAG_FORWARD;
    return (uint16_t)ocaml_tag;
}

int64_t caml_lazy_make_block(int64_t fn_val)
{
    int64_t *blk = (int64_t *)arc_alloc((uint16_t)ARC_TAG_LAZY, 1u, 8u);
    arc_retain_val(fn_val);
    blk[0] = fn_val;
    return (int64_t)(uintptr_t)blk;
}

int64_t caml_lazy_make_forward(int64_t v_val)
{
    int64_t *blk = (int64_t *)arc_alloc((uint16_t)ARC_TAG_FORWARD, 1u, 8u);
    arc_retain_val(v_val);
    blk[0] = v_val;
    return (int64_t)(uintptr_t)blk;
}

int64_t caml_lazy_update_to_forcing(int64_t blk_val)
{
    if (!is_heap_ptr(blk_val))
        return tag_int(1);
    ArcHeader *hdr = (ArcHeader *)(uintptr_t)blk_val - 1;
    if (hdr->tag != (uint16_t)ARC_TAG_LAZY)
        return tag_int(1);
    hdr->tag = (uint16_t)ARC_TAG_FORCING;
    return tag_int(0);
}

int64_t caml_lazy_reset_to_lazy(int64_t blk_val)
{
    if (is_heap_ptr(blk_val)) {
        ArcHeader *hdr = (ArcHeader *)(uintptr_t)blk_val - 1;
        hdr->tag = (uint16_t)ARC_TAG_LAZY;
    }
    return 1;
}

int64_t caml_lazy_update_to_forward(int64_t blk_val)
{
    if (is_heap_ptr(blk_val)) {
        ArcHeader *hdr = (ArcHeader *)(uintptr_t)blk_val - 1;
        hdr->tag = (uint16_t)ARC_TAG_FORWARD;
    }
    return 1;
}

int64_t caml_obj_block(int64_t tag_val, int64_t size_val)
{
    int64_t t = tag_val >> 1;
    int64_t sz = size_val >> 1;
    if (sz < 0 || sz > 0xffff || t < 0 || t > 255 ||
        t == 247 /* Closure_tag */ || t == 249 /* Infix_tag */ ||
        t == 255 /* Custom_tag */ || (t == 252 /* String_tag */ && sz == 0)) {
        ocamlcc_raise_invalid_arg_oob();
        return 1;
    }
    uint16_t atag = map_ocaml_tag_to_arc(t);
    if (sz == 0)
        return (int64_t)(uintptr_t)arc_alloc(atag, 0u, 0u);
    if (atag == (uint16_t)ARC_TAG_FLOAT_ARRAY) {
        double *p = (double *)arc_alloc(atag, 0u, (uint32_t)((uint64_t)sz * 8u));
        pal_memset(p, 0, (size_t)sz * 8u);
        return (int64_t)(uintptr_t)p;
    }
    uint16_t scan = (atag == (uint16_t)ARC_TAG_ARRAY || is_unscanned_leaf_tag(atag))
                        ? 0u
                        : (uint16_t)sz;
    int64_t *p = (int64_t *)arc_alloc(atag, scan, (uint32_t)((uint64_t)sz * 8u));
    for (int64_t i = 0; i < sz; i++)
        p[i] = 1;
    return (int64_t)(uintptr_t)p;
}

static int64_t dup_with_tag(int64_t v, int override_tag, uint16_t new_atag)
{
    if (!is_heap_ptr(v))
        return v;
    const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)v - 1;
    uint16_t src_tag = hdr->tag;

    if (src_tag == (uint16_t)ARC_TAG_STRING) {
        char *s = (char *)arc_alloc_bytes((uint64_t)hdr->reserved);
        if (hdr->reserved > 0u)
            pal_memcpy(s, (const void *)(uintptr_t)v, (size_t)hdr->reserved);
        return (int64_t)(uintptr_t)s;
    }
    if (src_tag == (uint16_t)ARC_TAG_FLOAT)
        return ocamlcc_alloc_float(unbox_float(v));
    if (src_tag == (uint16_t)ARC_TAG_FLOAT_ARRAY) {
        uint16_t tag = override_tag ? new_atag : src_tag;
        double *p = (double *)arc_alloc(tag, 0u, hdr->byte_size);
        if (hdr->byte_size > 0u)
            pal_memcpy(p, (const void *)(uintptr_t)v, hdr->byte_size);
        return (int64_t)(uintptr_t)p;
    }
    if (src_tag == (uint16_t)ARC_TAG_CUSTOM) {
        if (hdr->reserved == ARC_CUSTOM_INT32 ||
            hdr->reserved == ARC_CUSTOM_INT64 ||
            hdr->reserved == ARC_CUSTOM_NATIVEINT) {
            return ocamlcc_alloc_custom(hdr->reserved,
                                        *(const uint64_t *)(uintptr_t)v);
        }
        /* Mutex, Cond, BLAKE2, Bigarray, and Bigarray buffers own external
         * resources or intrusive state; return a retained alias instead of
         * shallow-duplicating handles. */
        arc_retain_val(v);
        return v;
    }
    if (src_tag == (uint16_t)ARC_TAG_WEAK ||
        src_tag == (uint16_t)ARC_TAG_FIBER) {
        /* Runtime-managed objects hold intrusive list links, OS stacks, or
         * synchronization primitives that cannot be shallow-copied. */
        arc_retain_val(v);
        return v;
    }
    if (src_tag == (uint16_t)ARC_TAG_CLOSURE) {
        uint16_t n = arc_scan_count(hdr);
        ArcClosure *dst =
            (ArcClosure *)arc_alloc(src_tag, n, hdr->byte_size);
        if (hdr->byte_size > 0u)
            pal_memcpy(dst, (const void *)(uintptr_t)v, hdr->byte_size);
        for (uint16_t i = 0u; i < n; i++)
            arc_retain_val((int64_t)dst->env[i]);
        return (int64_t)(uintptr_t)dst;
    }
    if (src_tag == (uint16_t)ARC_TAG_PAP) {
        ArcPap *dst =
            (ArcPap *)arc_alloc(src_tag, arc_scan_count(hdr), hdr->byte_size);
        if (hdr->byte_size > 0u)
            pal_memcpy(dst, (const void *)(uintptr_t)v, hdr->byte_size);
        arc_retain_val((int64_t)(uintptr_t)dst->orig);
        for (uint64_t i = 0u; i < dst->n_applied; i++)
            arc_retain_val(dst->args[i]);
        return (int64_t)(uintptr_t)dst;
    }

    uint16_t tag = override_tag ? new_atag : src_tag;
    /* Only allow Obj.with_tag to target ordinary blocks or arrays. */
    if (override_tag &&
        tag != (uint16_t)ARC_TAG_ARRAY &&
        tag != 248u &&
        tag >= 245u) {
        tag = src_tag;
    }
    uint32_t nf = (src_tag == (uint16_t)ARC_TAG_ARRAY)
                      ? (hdr->byte_size / 8u)
                      : (uint32_t)arc_scan_count(hdr);
    uint16_t scan = (tag == (uint16_t)ARC_TAG_ARRAY)
                        ? 0u
                        : (nf > UINT16_MAX ? (uint16_t)UINT16_MAX : (uint16_t)nf);
    int64_t *dst = (int64_t *)arc_alloc(tag, scan, hdr->byte_size);
    if (hdr->byte_size > 0u)
        pal_memcpy(dst, (const void *)(uintptr_t)v, hdr->byte_size);
    for (uint32_t i = 0u; i < nf; i++)
        arc_retain_val(dst[i]);
    return (int64_t)(uintptr_t)dst;
}

int64_t caml_obj_dup(int64_t v)
{
    return dup_with_tag(v, 0, 0u);
}

int64_t caml_obj_with_tag(int64_t tag_val, int64_t v)
{
    return dup_with_tag(v, 1, map_ocaml_tag_to_arc(tag_val >> 1));
}

int64_t caml_floatarray_get(int64_t fa, int64_t idx_val)
{
    return ocamlcc_gen_array_get(3, fa, idx_val);
}

int64_t caml_floatarray_set(int64_t fa, int64_t idx_val, int64_t v)
{
    return ocamlcc_gen_array_set(3, fa, idx_val, v);
}

int64_t caml_obj_add_offset(int64_t v, int64_t off_val)
{
    int32_t off = (int32_t)unbox_custom_i64(off_val);
    return (int64_t)((uintptr_t)v + (intptr_t)off);
}

static int rw_visited_insert(uintptr_t **tab, size_t *cap, size_t *alloc_bytes,
                             size_t *used, uintptr_t key)
{
    if (*tab == NULL || (*used + 1u) * 2u >= *cap) {
        size_t new_bytes = (*alloc_bytes == 0u) ? (size_t)LARGE_PAGE_ALIGN : (*alloc_bytes * 2u);
        uintptr_t *nt = (uintptr_t *)pal_page_alloc(new_bytes);
        if (nt == NULL)
            return -1;
        pal_memset(nt, 0, new_bytes);
        size_t ncap = new_bytes / sizeof(uintptr_t);
        if (*tab != NULL) {
            for (size_t i = 0; i < *cap; i++) {
                if ((*tab)[i] != 0u) {
                    size_t idx = (size_t)((*tab)[i] >> 4) & (ncap - 1u);
                    while (nt[idx] != 0u)
                        idx = (idx + 1u) & (ncap - 1u);
                    nt[idx] = (*tab)[i];
                }
            }
            pal_page_free(*tab, *alloc_bytes);
        }
        *tab = nt;
        *alloc_bytes = new_bytes;
        *cap = ncap;
    }
    size_t mask = *cap - 1u;
    size_t idx = (size_t)(key >> 4) & mask;
    while ((*tab)[idx] != 0u) {
        if ((*tab)[idx] == key)
            return 0;
        idx = (idx + 1u) & mask;
    }
    (*tab)[idx] = key;
    (*used)++;
    return 1;
}

static void rw_push_val(CCVec *work, uintptr_t **tab, size_t *cap,
                        size_t *alloc_bytes, size_t *used, int64_t val)
{
    if (!is_heap_ptr(val))
        return;
    ArcHeader *h = (ArcHeader *)(uintptr_t)val - 1;
    if (atomic_load_explicit(&h->refcount, memory_order_relaxed) == ARC_IMMORTAL)
        return;
    if (rw_visited_insert(tab, cap, alloc_bytes, used, (uintptr_t)h) == 1)
        ccvec_push(work, h);
}

int64_t caml_obj_reachable_words(int64_t v)
{
    if (!is_heap_ptr(v))
        return tag_int(0);
    ArcHeader *root = (ArcHeader *)(uintptr_t)v - 1;
    if (atomic_load_explicit(&root->refcount, memory_order_relaxed) == ARC_IMMORTAL)
        return tag_int(0);

    CCVec work = { NULL, 0, 0, 0 };
    uintptr_t *tab = NULL;
    size_t cap = 0, alloc_bytes = 0, used = 0;
    if (rw_visited_insert(&tab, &cap, &alloc_bytes, &used, (uintptr_t)root) == 1)
        ccvec_push(&work, root);

    uint64_t words = 0u;
    while (work.len > 0u) {
        ArcHeader *cur = work.data[--work.len];
        words += (uint64_t)((cur->byte_size + 7u) / 8u + 2u);
        uint16_t tag = cur->tag;
        if (tag == (uint16_t)ARC_TAG_CLOSURE) {
            ArcClosure *c = (ArcClosure *)(cur + 1);
            for (uint16_t i = 0; i < arc_scan_count(cur); i++)
                rw_push_val(&work, &tab, &cap, &alloc_bytes, &used, (int64_t)c->env[i]);
        } else if (tag == (uint16_t)ARC_TAG_PAP) {
            ArcPap *p = (ArcPap *)(cur + 1);
            rw_push_val(&work, &tab, &cap, &alloc_bytes, &used, (int64_t)(uintptr_t)p->orig);
            for (uint64_t i = 0; i < p->n_applied; i++)
                rw_push_val(&work, &tab, &cap, &alloc_bytes, &used, p->args[i]);
        } else if (tag == (uint16_t)ARC_TAG_ARRAY) {
            int64_t *arr = (int64_t *)(cur + 1);
            uint32_t n = cur->byte_size / 8u;
            for (uint32_t i = 0; i < n; i++)
                rw_push_val(&work, &tab, &cap, &alloc_bytes, &used, arr[i]);
        } else if (tag == (uint16_t)ARC_TAG_CUSTOM &&
                   cur->reserved == ARC_CUSTOM_BIGARRAY) {
            ArcBigarray *a = (ArcBigarray *)(cur + 1);
            rw_push_val(&work, &tab, &cap, &alloc_bytes, &used,
                        (int64_t)(uintptr_t)a->backing);
        } else if (!is_unscanned_leaf_tag(tag) &&
                   tag != (uint16_t)ARC_TAG_FIBER) {
            int64_t *fields = (int64_t *)(cur + 1);
            for (uint16_t i = 0; i < arc_scan_count(cur); i++)
                rw_push_val(&work, &tab, &cap, &alloc_bytes, &used, fields[i]);
        }
    }

    ccvec_free(&work);
    if (tab != NULL)
        pal_page_free(tab, alloc_bytes);
    return tag_int((int64_t)words);
}

int64_t caml_obj_raw_field(int64_t obj_val, int64_t idx_val)
{
    int64_t idx = idx_val >> 1;
    const int64_t *fields = (const int64_t *)(uintptr_t)obj_val;
    return ocamlcc_alloc_custom(ARC_CUSTOM_NATIVEINT, (uint64_t)fields[idx]);
}

int64_t caml_obj_set_raw_field(int64_t obj_val, int64_t idx_val, int64_t raw_val)
{
    int64_t idx = idx_val >> 1;
    int64_t *fields = (int64_t *)(uintptr_t)obj_val;
    fields[idx] = unbox_custom_i64(raw_val);
    return 1;
}

int64_t caml_weak_blit(int64_t src_val, int64_t src_ofs_val,
                       int64_t dst_val, int64_t dst_ofs_val, int64_t len_val)
{
    ArcWeakArray *src = (ArcWeakArray *)(uintptr_t)src_val;
    ArcWeakArray *dst = (ArcWeakArray *)(uintptr_t)dst_val;
    int64_t so = src_ofs_val >> 1;
    int64_t dofs = dst_ofs_val >> 1;
    int64_t len = len_val >> 1;
    if (len < 0 || so < 0 || dofs < 0 ||
        (uint64_t)so + (uint64_t)len > src->len ||
        (uint64_t)dofs + (uint64_t)len > dst->len) {
        raise_invalid_arg_imm(g_inv_arg_oob_str.str);
        return 1;
    }
    if (len == 0)
        return 1;
    arc_lock(&g_weak_lock);
    if (src == dst && dofs > so) {
        for (int64_t i = len - 1; i >= 0; i--)
            dst->slots[dofs + i] = src->slots[so + i];
    } else {
        for (int64_t i = 0; i < len; i++)
            dst->slots[dofs + i] = src->slots[so + i];
    }
    arc_unlock(&g_weak_lock);
    return 1;
}

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
        /* A released callback still owns its local registration. Only the
         * dispatcher that holds the queue may read it or clear its gate. */
        if (!fiber->owns_finalizer_dispatch &&
            atomic_exchange_explicit(&finalizer_dispatch, DISPATCH_ACTIVE,
                                     memory_order_acquire) == DISPATCH_ACTIVE) {
            arc_mutator_leave(entered);
            return 1;
        }
        fiber->owns_finalizer_dispatch = 0;
        if (ocamlcc_get_exn() != 0)
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

int64_t caml_memprof_start(int64_t rate, int64_t sz, int64_t tracker)
{
    (void)rate; (void)sz; (void)tracker;
    raise_failure_cstr("Gc.Memprof: unsupported", 23u);
    return 1;
}

int64_t caml_memprof_is_sampling(int64_t ignored)
{
    (void)ignored;
    return 1;
}

int64_t caml_memprof_stop(int64_t ignored)
{
    (void)ignored;
    return 1;
}

int64_t caml_memprof_discard(int64_t t)
{
    (void)t;
    return 1;
}

int64_t caml_ml_gc_ramp_up(int64_t fn)
{
    int64_t res = ocamlcc_apply1_raw(fn, 1);
    if (ocamlcc_get_exn() != 0)
        return 1;
    int64_t *pair = (int64_t *)arc_alloc(0u, 2u, 16u);
    pair[0] = res;
    pair[1] = tag_int(0);
    return (int64_t)(uintptr_t)pair;
}

int64_t caml_ml_gc_ramp_down(int64_t w)
{
    (void)w;
    return 1;
}

int64_t caml_gc_tweak_set(int64_t k, int64_t v)
{
    (void)k; (void)v;
    return 1;
}

int64_t caml_gc_tweak_get(int64_t k)
{
    (void)k;
    return tag_int(0);
}

int64_t caml_gc_tweak_list_active(int64_t ignored)
{
    (void)ignored;
    return 1;
}

int64_t caml_ephe_create(int64_t n) { (void)n; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_get_key(int64_t e, int64_t i) { (void)e; (void)i; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_get_key_copy(int64_t e, int64_t i) { (void)e; (void)i; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_set_key(int64_t e, int64_t i, int64_t k) { (void)e; (void)i; (void)k; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_unset_key(int64_t e, int64_t i) { (void)e; (void)i; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_check_key(int64_t e, int64_t i) { (void)e; (void)i; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_blit_key(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e) { (void)a; (void)b; (void)c; (void)d; (void)e; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_get_data(int64_t e) { (void)e; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_get_data_copy(int64_t e) { (void)e; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_set_data(int64_t e, int64_t d) { (void)e; (void)d; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_unset_data(int64_t e) { (void)e; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_check_data(int64_t e) { (void)e; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }
int64_t caml_ephe_blit_data(int64_t a, int64_t b) { (void)a; (void)b; raise_failure_cstr("Ephemeron: unsupported", 22u); return 1; }

int64_t caml_get_public_method(int64_t obj, int64_t tag)
{
    (void)obj; (void)tag;
    raise_failure_cstr("CamlinternalOO: method dispatch unsupported", 43u);
    return 1;
}

int64_t caml_get_continuation_callstack(int64_t cont, int64_t n)
{
    (void)cont; (void)n;
    return (int64_t)(uintptr_t)arc_alloc((uint16_t)ARC_TAG_ARRAY, 0u, 0u);
}

/* Thin object-introspection helpers for pure OCaml Marshal */

int64_t ocamlcc_ptr_id(int64_t v)
{
    if (!is_heap_ptr(v))
        return tag_int(0);
    return tag_int((int64_t)((uint64_t)(uintptr_t)v >> 3));
}

int64_t ocamlcc_marshal_kind(int64_t v)
{
    if (!is_heap_ptr(v))
        return tag_int(-1);
    const ArcHeader *h = (const ArcHeader *)(uintptr_t)v - 1;
    uint16_t tag = h->tag;
    if (tag == (uint16_t)ARC_TAG_CLOSURE || tag == (uint16_t)ARC_TAG_PAP)
        return tag_int(247);
    if (tag == (uint16_t)ARC_TAG_FORCING || tag == (uint16_t)ARC_TAG_WEAK ||
        tag == (uint16_t)ARC_TAG_FIBER)
        return tag_int(251);
    if (tag == (uint16_t)ARC_TAG_ARRAY)
        return tag_int(0);
    if (tag == (uint16_t)ARC_TAG_LAZY)
        return tag_int(246);
    if (tag == (uint16_t)ARC_TAG_FORWARD)
        return tag_int(250);
    if (tag == (uint16_t)ARC_TAG_STRING)
        return tag_int(252);
    if (tag == (uint16_t)ARC_TAG_FLOAT)
        return tag_int(253);
    if (tag == (uint16_t)ARC_TAG_FLOAT_ARRAY)
        return tag_int(254);
    if (tag == (uint16_t)ARC_TAG_CUSTOM) {
        if (h->reserved == ARC_CUSTOM_INT32) return tag_int(300);
        if (h->reserved == ARC_CUSTOM_INT64) return tag_int(301);
        if (h->reserved == ARC_CUSTOM_NATIVEINT) return tag_int(302);
        if (h->reserved == ARC_CUSTOM_BIGARRAY) return tag_int(306);
        return tag_int(251);
    }
    if (tag > 250u)
        return tag_int(251);
    return tag_int((int64_t)tag);
}
