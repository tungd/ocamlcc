/* arc.c — freestanding slab allocator, O(1)-stack tail-drop ARC, and
 * Perceus reuse over ArcHeader (design doc §4.2).
 *
 * Uses pal_page_alloc / pal_page_free directly with no libc heap calls. */
#include "arc.h"

#include "fiber.h"
#include "pal.h"

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

static ArcSpinLock g_alloc_lock = { 0u };
static ArcSpinLock g_weak_lock = { 0u };
static ArcSpinLock g_cc_lock = { 0u };
static _Atomic int g_cc_active = 0;

static FreeSlot *g_free_lists[NUM_SIZE_CLASSES];
static uint8_t  *g_slab_cur[NUM_SIZE_CLASSES];
static uint8_t  *g_slab_end[NUM_SIZE_CLASSES];

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

static inline int is_cycle_candidate_obj(const ArcHeader *hdr)
{
    if (atomic_load_explicit(&hdr->refcount, memory_order_relaxed) == ARC_IMMORTAL)
        return 0;
    uint16_t tag = hdr->tag;
    if (tag == (uint16_t)ARC_TAG_STRING || tag == (uint16_t)ARC_TAG_WEAK)
        return 0;
    if (tag == (uint16_t)ARC_TAG_FIBER)
        return 1; /* the shadow stack holds owning references (see
                     cc_visit_children); queued fibers keep the scheduler's
                     +1 from spawn and survive every trial */
    if (tag == (uint16_t)ARC_TAG_ARRAY)
        return hdr->byte_size >= 8u;
    if (tag == (uint16_t)ARC_TAG_PAP)
        return 1;
    return hdr->scan_fields > 0u;
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
    if (!is_cycle_candidate_obj(hdr))
        return;
    arc_lock(&g_cc_lock);
    if ((hdr->reserved & CC_BUFFERED) != 0u) {
        arc_unlock(&g_cc_lock);
        return;
    }
    if (g_cc_roots.len >= CC_MAX_ROOTS) {
        arc_unlock(&g_cc_lock);
        return;
    }
    uint32_t idx = (uint32_t)g_cc_roots.len;
    ccvec_push(&g_cc_roots, hdr);
    hdr->reserved =
        (hdr->reserved & CC_COLOR_MASK) | CC_BUFFERED | (idx << CC_INDEX_SHIFT);
    arc_unlock(&g_cc_lock);
}

static inline void cc_roots_remove_locked(ArcHeader *hdr)
{
    if (hdr->tag == (uint16_t)ARC_TAG_STRING ||
        hdr->tag == (uint16_t)ARC_TAG_WEAK)
        return;
    if ((hdr->reserved & CC_BUFFERED) == 0u)
        return;
    uint32_t idx = hdr->reserved >> CC_INDEX_SHIFT;
    uint32_t last = (uint32_t)--g_cc_roots.len;
    if (idx != last) {
        ArcHeader *moved = g_cc_roots.data[last];
        g_cc_roots.data[idx] = moved;
        moved->reserved =
            (moved->reserved & CC_COLOR_MASK) | CC_BUFFERED | (idx << CC_INDEX_SHIFT);
    }
    hdr->reserved &= CC_COLOR_MASK;
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

static uint64_t weak_target_hash(int64_t v)
{
    uint64_t x = (uint64_t)v;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return x;
}

static void weak_targets_grow(void)
{
    uint64_t new_cap = (g_weak_targets_mask + 1) * 2u;
    if (new_cap == 0u)
        new_cap = 1024u;
    int64_t *nt = (int64_t *)pal_page_alloc((size_t)new_cap * sizeof(int64_t));
    if (nt == NULL)
        pal_abort();
    for (uint64_t i = 0; i < new_cap; i++)
        nt[i] = 0;
    uint64_t old_cap = g_weak_targets_mask + 1u;
    uint64_t used = 0;
    if (g_weak_targets != NULL) {
        for (uint64_t i = 0; i < old_cap; i++) {
            int64_t v = g_weak_targets[i];
            if (v != 0 && v != WEAK_TARGET_TOMBSTONE) {
                uint64_t j = weak_target_hash(v) & (new_cap - 1u);
                while (nt[j] != 0)
                    j = (j + 1u) & (new_cap - 1u);
                nt[j] = v;
                used++;
            }
        }
        pal_page_free(g_weak_targets, (size_t)old_cap * sizeof(int64_t));
    }
    g_weak_targets = nt;
    g_weak_targets_mask = new_cap - 1u;
    g_weak_targets_used = used;
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
    if (weak_targets_contains(v))
        return;
    /* Keep at least a third of the table empty so linear probing (which
       terminates on the first empty slot) always terminates, even for
       lookups of absent keys. */
    if (g_weak_targets == NULL ||
        (g_weak_targets_used + 1u) * 3u > (g_weak_targets_mask + 1u) * 2u)
        weak_targets_grow();
    uint64_t j = weak_target_hash(v) & g_weak_targets_mask;
    while (g_weak_targets[j] != 0 && g_weak_targets[j] != WEAK_TARGET_TOMBSTONE)
        j = (j + 1u) & g_weak_targets_mask;
    if (g_weak_targets[j] == 0)
        g_weak_targets_used++;
    g_weak_targets[j] = v;
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

static void weak_clear_target(int64_t dead_obj)
{
    arc_lock(&g_weak_lock);
    weak_clear_target_locked(dead_obj);
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

static _Thread_local int64_t tls_exn_slot = 0;
static _Atomic int64_t g_next_oo_id = 0;

int64_t ocamlcc_get_exn(void) { return tls_exn_slot; }
void ocamlcc_set_exn(int64_t exn) { tls_exn_slot = exn; }

static inline int64_t tag_int(int64_t n)
{
    return (int64_t)(((uint64_t)n << 1) | 1ull);
}

int64_t caml_fresh_oo_id(int64_t ignored)
{
    (void)ignored;
    int64_t id = atomic_fetch_add_explicit(&g_next_oo_id, 1, memory_order_relaxed);
    return tag_int(id);
}

static inline int is_heap_ptr(int64_t val)
{
    return val != 0 && (val & 1) == 0;
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

static ArcHeader *slab_alloc(uint32_t total_bytes)
{
    int cls = size_class_for(total_bytes);
    if (cls >= 0) {
        arc_lock(&g_alloc_lock);
        if (g_free_lists[cls] != NULL) {
            FreeSlot *slot = g_free_lists[cls];
            g_free_lists[cls] = slot->next;
            arc_unlock(&g_alloc_lock);
            return (ArcHeader *)slot;
        }
        uint32_t step = k_class_sizes[cls];
        if (g_slab_cur[cls] == NULL ||
            (size_t)(g_slab_end[cls] - g_slab_cur[cls]) < (size_t)step) {
            uint8_t *page = (uint8_t *)pal_page_alloc(SLAB_SIZE);
            if (page == NULL) {
                arc_unlock(&g_alloc_lock);
                pal_abort();
            }
            g_slab_cur[cls] = page;
            g_slab_end[cls] = page + SLAB_SIZE;
        }
        ArcHeader *hdr = (ArcHeader *)g_slab_cur[cls];
        g_slab_cur[cls] += step;
        arc_unlock(&g_alloc_lock);
        return hdr;
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
        arc_lock(&g_alloc_lock);
        FreeSlot *slot = (FreeSlot *)hdr;
        slot->next = g_free_lists[cls];
        g_free_lists[cls] = slot;
        arc_unlock(&g_alloc_lock);
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
    hdr->scan_fields = scan_fields;
    hdr->byte_size = byte_size;
    hdr->reserved = 0;
    atomic_fetch_add_explicit(&g_live_objects, 1, memory_order_relaxed);
    return hdr + 1;
}

extern const void *ocamlcc_global_Invalid_argument;
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

void *arc_alloc_array(uint64_t len, int64_t init)
{
    if (len > ((uint64_t)UINT32_MAX - (uint64_t)sizeof(ArcHeader)) / 8u) {
        arc_release_val(init);
        raise_invalid_arg_imm(g_inv_arg_array_str.str);
        return (void *)(uintptr_t)1;
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
            atomic_fetch_add_explicit(&ihdr->refcount, (uint32_t)extra,
                                      memory_order_relaxed);
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
        atomic_fetch_add_explicit(&hdr->refcount, 1u, memory_order_relaxed);
}

static int arc_try_retain(ArcHeader *hdr)
{
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
    if (atomic_fetch_sub_explicit(&chdr->refcount, 1u, memory_order_acq_rel) == 1u) {
        atomic_thread_fence(memory_order_acquire);
        if (*tail != NULL)
            work_push(w, *tail);
        *tail = chdr;
    }
}

/* Releases children of [root] with O(1) stack on right-spines / tail fields.
 * Frees every dead descendant; frees [root] iff [free_root] is non-zero. */
static void release_subtree(ArcHeader *root, int free_root)
{
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
            uint32_t n = cur->scan_fields;
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
        } else if (tag != ARC_TAG_STRING) {
            int64_t *fields = (int64_t *)(cur + 1);
            uint32_t n = cur->scan_fields;
            for (uint32_t i = 0; i < n; i++)
                drop_child_val(&w, fields[i], &tail);
        }

        if (atomic_load_explicit(&g_weak_count, memory_order_acquire) > 0u)
            weak_clear_target((int64_t)(uintptr_t)(cur + 1));

        if (is_cycle_candidate_obj(cur) ||
            atomic_load_explicit(&g_cc_active, memory_order_acquire) != 0) {
            arc_lock(&g_cc_lock);
            cc_roots_remove_locked(cur);
            arc_unlock(&g_cc_lock);
        }

        atomic_fetch_sub_explicit(&g_live_objects, 1, memory_order_relaxed);
        if (cur != root || free_root)
            slab_free(cur);

        cur = (tail != NULL) ? tail : work_pop(&w);
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
    if (atomic_fetch_sub_explicit(&hdr->refcount, 1u, memory_order_acq_rel) == 1u) {
        atomic_thread_fence(memory_order_acquire);
        release_subtree(hdr, 1);
    }
}

void arc_retain_val(int64_t val)
{
    if (is_heap_ptr(val))
        arc_retain((void *)(uintptr_t)val);
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
    if (atomic_fetch_sub_explicit(&hdr->refcount, 1u, memory_order_acq_rel) == 1u) {
        atomic_thread_fence(memory_order_acquire);
        release_subtree(hdr, 0);
        return (void *)hdr;
    }
    return NULL;
}

void *arc_alloc_reuse(void *reuse_tok, uint16_t tag, uint16_t scan_fields, uint32_t byte_size)
{
    if (reuse_tok == NULL)
        return arc_alloc(tag, scan_fields, byte_size);

    if ((uint64_t)sizeof(ArcHeader) + (uint64_t)byte_size > (uint64_t)UINT32_MAX)
        pal_abort();

    ArcHeader *hdr = (ArcHeader *)reuse_tok;
    int old_cls = size_class_for((uint32_t)sizeof(ArcHeader) + hdr->byte_size);
    int new_cls = size_class_for((uint32_t)sizeof(ArcHeader) + byte_size);
    if (old_cls >= 0 && old_cls == new_cls) {
        atomic_init(&hdr->refcount, 1u);
        hdr->tag = tag;
        hdr->scan_fields = scan_fields;
        hdr->byte_size = byte_size;
        hdr->reserved = 0;
        atomic_fetch_add_explicit(&g_live_objects, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&g_reuse_hits, 1, memory_order_relaxed);
        return hdr + 1;
    }

    slab_free(hdr);
    return arc_alloc(tag, scan_fields, byte_size);
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

typedef void (*CcChildFn)(int64_t val, void *ctx);

static void cc_visit_children(ArcHeader *hdr, CcChildFn fn, void *ctx)
{
    uint16_t tag = hdr->tag;
    if (tag == (uint16_t)ARC_TAG_CLOSURE) {
        ArcClosure *c = (ArcClosure *)(hdr + 1);
        uint32_t n = hdr->scan_fields;
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
    } else if (tag != (uint16_t)ARC_TAG_STRING &&
               tag != (uint16_t)ARC_TAG_WEAK) {
        int64_t *fields = (int64_t *)(hdr + 1);
        uint32_t n = hdr->scan_fields;
        for (uint32_t i = 0; i < n; i++)
            fn(fields[i], ctx);
    }
}

static ArcHeader *cc_candidate_child(int64_t val)
{
    if (!is_heap_ptr(val))
        return NULL;
    ArcHeader *chdr = (ArcHeader *)(uintptr_t)val - 1;
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
                size_t j = trial_hash(tm->entries[i].hdr) & (new_cap - 1u);
                while (ne[j].hdr != NULL)
                    j = (j + 1u) & (new_cap - 1u);
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
    /* Keep power-of-2-friendly probing by using modulo when cap is non-pow2,
       or mask if pow2; trial_grow derives cap from page size / sizeof(TrialEntry)
       (sizeof(TrialEntry) = 24, so cap may not be a power of 2). */
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
    ArcHeader *chdr = cc_candidate_child(val);
    if (chdr == NULL)
        return;
    CCTrialCtx *tc = (CCTrialCtx *)ctx;
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
    ArcHeader *chdr = cc_candidate_child(val);
    if (chdr == NULL)
        return;
    CCTrialCtx *tc = (CCTrialCtx *)ctx;
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
    ArcHeader *chdr = cc_candidate_child(val);
    if (chdr == NULL)
        return;
    CCTrialCtx *tc = (CCTrialCtx *)ctx;
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
    ArcHeader *chdr = cc_candidate_child(val);
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

static void cc_collect_leaf_cb(int64_t val, void *ctx)
{
    if (!is_heap_ptr(val))
        return;
    ArcHeader *chdr = (ArcHeader *)(uintptr_t)val - 1;
    if (atomic_load_explicit(&chdr->refcount, memory_order_relaxed) == ARC_IMMORTAL)
        return;
    if (!is_cycle_candidate_obj(chdr))
        ccvec_push((CCVec *)ctx, (ArcHeader *)(uintptr_t)val);
}

int64_t ocamlcc_arc_collect(int64_t unit)
{
    (void)unit;
    arc_lock(&g_cc_lock);
    if (g_cc_roots.len == 0u) {
        arc_unlock(&g_cc_lock);
        return 1;
    }

    atomic_store_explicit(&g_cc_active, 1, memory_order_release);

    TrialMap tm = { NULL, 0, 0, 0 };
    CCVec work = { NULL, 0, 0, 0 };
    CCVec black_work = { NULL, 0, 0, 0 };
    CCVec dead = { NULL, 0, 0, 0 };
    CCVec leaves = { NULL, 0, 0, 0 };

    for (size_t i = 0; i < g_cc_roots.len; i++) {
        ArcHeader *r = g_cc_roots.data[i];
        if (trial_get(&tm, r)->color == CC_COLOR_BLACK)
            cc_mark_gray(&tm, &work, r);
    }

    for (size_t i = 0; i < g_cc_roots.len; i++)
        cc_scan(&tm, &work, &black_work, g_cc_roots.data[i]);

    for (size_t i = 0; i < g_cc_roots.len; i++) {
        ArcHeader *r = g_cc_roots.data[i];
        if (trial_get(&tm, r)->color == CC_COLOR_WHITE)
            cc_collect_white(&tm, &work, &dead, r);
        r->reserved &= CC_COLOR_MASK;
    }
    g_cc_roots.len = 0;

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
        if (atomic_load_explicit(&g_weak_count, memory_order_acquire) > 0u)
            weak_clear_target((int64_t)(uintptr_t)(w + 1));
        cc_visit_children(w, cc_collect_leaf_cb, &leaves);
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

    for (size_t i = 0; i < leaves.len; i++)
        arc_release((void *)leaves.data[i]);
    for (size_t i = 0; i < dead.len; i++) {
        atomic_fetch_sub_explicit(&g_live_objects, 1, memory_order_relaxed);
        slab_free(dead.data[i]);
    }

    int64_t reclaimed = (int64_t)dead.len;
    trial_free(&tm);
    ccvec_free(&work);
    ccvec_free(&black_work);
    ccvec_free(&dead);
    ccvec_free(&leaves);
    return tag_int(reclaimed);
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
    int64_t result = val;
    if (is_heap_ptr(val)) {
        /* Copy the block one level deep (same tag / scan_fields / size), so
         * mutating the copy never reaches the value stored in the slot. */
        ArcHeader *hdr = (ArcHeader *)(uintptr_t)val - 1;
        uint32_t nbytes = hdr->byte_size;
        int64_t *copy = (int64_t *)arc_alloc(hdr->tag, hdr->scan_fields, nbytes);
        uint64_t *dst = (uint64_t *)(void *)copy;
        uint64_t *src = (uint64_t *)(void *)(uintptr_t)val;
        for (uint32_t i = 0; i < nbytes / 8u; i++)
            dst[i] = src[i];
        for (uint16_t i = 0; i < hdr->scan_fields; i++)
            arc_retain_val(copy[i]);
        arc_release_val(val);
        result = (int64_t)(uintptr_t)copy;
    }
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

int64_t caml_blit_bytes(int64_t src, int64_t src_off,
                        int64_t dst, int64_t dst_off, int64_t len)
{
    const ArcHeader *hs = (const ArcHeader *)(uintptr_t)src - 1;
    const ArcHeader *hd = (const ArcHeader *)(uintptr_t)dst - 1;
    int64_t soff = src_off >> 1;
    int64_t doff = dst_off >> 1;
    int64_t n = len >> 1;
    if (soff < 0 || doff < 0 || n < 0 ||
        (uint64_t)soff + (uint64_t)n > hs->reserved ||
        (uint64_t)doff + (uint64_t)n > hd->reserved) {
        raise_invalid_arg_imm(g_inv_arg_oob_str.str);
        return 1;
    }
    const uint8_t *s = (const uint8_t *)(uintptr_t)src + soff;
    uint8_t *d = (uint8_t *)(uintptr_t)dst + doff;
    if (d < s || d >= s + n) {
        pal_memcpy(d, s, (size_t)n);
    } else if (d > s) {
        for (int64_t i = n; i > 0; i--)
            d[i - 1] = s[i - 1];
    }
    return 1;
}

int64_t caml_blit_string(int64_t src, int64_t src_off,
                         int64_t dst, int64_t dst_off, int64_t len)
{
    return caml_blit_bytes(src, src_off, dst, dst_off, len);
}

int64_t caml_fill_bytes(int64_t dst, int64_t off_val, int64_t len_val, int64_t ch)
{
    const ArcHeader *hd = (const ArcHeader *)(uintptr_t)dst - 1;
    int64_t off = off_val >> 1;
    int64_t n = len_val >> 1;
    if (off < 0 || n < 0 || (uint64_t)off + (uint64_t)n > hd->reserved) {
        raise_invalid_arg_imm(g_inv_arg_oob_str.str);
        return 1;
    }
    uint8_t *d = (uint8_t *)(uintptr_t)dst + off;
    pal_memset(d, (int)((ch >> 1) & 0xff), (size_t)n);
    return 1;
}

int64_t caml_string_equal(int64_t a, int64_t b)
{
    if (a == b)
        return 3;
    const ArcHeader *ha = (const ArcHeader *)(uintptr_t)a - 1;
    const ArcHeader *hb = (const ArcHeader *)(uintptr_t)b - 1;
    if (ha->reserved != hb->reserved)
        return 1;
    return (bytes_compare_raw(a, b) == 0) ? 3 : 1;
}

int64_t caml_bytes_equal(int64_t a, int64_t b)
{
    return caml_string_equal(a, b);
}

int64_t caml_string_compare(int64_t a, int64_t b)
{
    int c = bytes_compare_raw(a, b);
    return tag_int((int64_t)c);
}

int64_t caml_bytes_compare(int64_t a, int64_t b)
{
    return caml_string_compare(a, b);
}

/* ------------------------------------------------------------------ */
/* Polymorphic structural comparison & bounded hashing                 */
/* ------------------------------------------------------------------ */

/* C recursion depth is bounded so cyclic records cannot smash the C
 * stack; the shared step budget bounds tail-iterated cycles (e.g. cyclic
 * lists), which would otherwise spin forever without growing the stack. */
#define COMPARE_MAX_DEPTH 50000
#define COMPARE_MAX_STEPS 100000000LL

DEFINE_IMMORTAL_STR(g_inv_arg_cyc_str, "compare: cyclic structure");

static int val_compare_raw(int64_t a, int64_t b, int total, int depth,
                           int64_t *steps)
{
    for (;;) {
        if (*steps <= 0) {
            raise_invalid_arg_imm(g_inv_arg_cyc_str.str);
            return 1;
        }
        (*steps)--;
        if (a == b)
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
        uint16_t ta = ha->tag;
        uint16_t tb = hb->tag;
        if (ta != tb)
            return (ta < tb) ? -1 : 1;

        if (ta == (uint16_t)ARC_TAG_STRING)
            return bytes_compare_raw(a, b);

        /* Functional values (closures / partial applications): ordered
         * comparison is undefined in OCaml and must raise; ( = ) / ( <> )
         * fall through to physical equality below. */
        if (total &&
            (ta == (uint16_t)ARC_TAG_CLOSURE || ta == (uint16_t)ARC_TAG_PAP)) {
            raise_invalid_arg_imm(g_inv_arg_fn_str.str);
            return 1;
        }

        /* Exception-constructor id blocks (tag 248: field 0 = name string,
         * field 1 = OID) compare structurally, like real OCaml, instead of
         * by raw heap address. */
        if (ta == (uint16_t)ARC_TAG_ARRAY || ta == 248u || ta < 245u) {
            uint32_t fa = (ta == (uint16_t)ARC_TAG_ARRAY || ta == 248u)
                              ? (ha->byte_size / 8u)
                              : (uint32_t)ha->scan_fields;
            uint32_t fb = (tb == (uint16_t)ARC_TAG_ARRAY || tb == 248u)
                              ? (hb->byte_size / 8u)
                              : (uint32_t)hb->scan_fields;
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

        /* Physical comparison: distinct closures under ( = ), weak/fiber
         * arrays, and partial applications compared by address. */
        uintptr_t ua = (uintptr_t)a;
        uintptr_t ub = (uintptr_t)b;
        return (ua < ub) ? -1 : 1;
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
    return (val_compare(a, b, 1) < 0) ? 3 : 1;
}

int64_t caml_lessequal(int64_t a, int64_t b)
{
    return (val_compare(a, b, 1) <= 0) ? 3 : 1;
}

int64_t caml_greaterthan(int64_t a, int64_t b)
{
    return (val_compare(a, b, 1) > 0) ? 3 : 1;
}

int64_t caml_greaterequal(int64_t a, int64_t b)
{
    return (val_compare(a, b, 1) >= 0) ? 3 : 1;
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

int64_t caml_hash(int64_t count_val, int64_t limit_val,
                  int64_t seed_val, int64_t obj)
{
    int64_t num = count_val >> 1;
    int64_t limit = limit_val >> 1;
    uint32_t h = (uint32_t)(seed_val >> 1);
    if (num <= 0)
        num = 1;
    if (limit <= 0)
        limit = 1;

    int64_t stack[256];
    int sp = 0;
    stack[sp++] = obj;

    while (sp > 0 && num > 0 && limit > 0) {
        int64_t v = stack[--sp];
        limit--;
        if ((v & 1) != 0) {
            uint64_t u = (uint64_t)(v >> 1);
            h = hash_mix32(h, (uint32_t)u);
            h = hash_mix32(h, (uint32_t)(u >> 32));
            num--;
        } else {
            const ArcHeader *hdr = (const ArcHeader *)(uintptr_t)v - 1;
            uint16_t tag = hdr->tag;
            if (tag == (uint16_t)ARC_TAG_STRING) {
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
                for (uint32_t k = 0; i + k < len; k++)
                    rem |= (uint32_t)s[i + k] << (8u * k);
                if (len > 0u)
                    h = hash_mix32(h, rem);
                h = hash_mix32(h, len);
                num--;
            } else if (tag == (uint16_t)ARC_TAG_ARRAY || tag < 245u) {
                uint32_t nf = (tag == (uint16_t)ARC_TAG_ARRAY)
                                  ? (hdr->byte_size / 8u)
                                  : (uint32_t)hdr->scan_fields;
                h = hash_mix32(h, ((uint32_t)tag << 16) ^ nf);
                const int64_t *fields = (const int64_t *)(uintptr_t)v;
                for (uint32_t i = nf; i > 0u && sp < 256; i--)
                    stack[sp++] = fields[i - 1u];
            } else {
                h = hash_mix32(h, (uint32_t)tag);
                num--;
            }
        }
    }

    h ^= h >> 16;
    h *= 0x85ebca6bu;
    h ^= h >> 13;
    h *= 0xc2b2ae35u;
    h ^= h >> 16;
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
