/* Weak arrays, target registration, and retirement. */
#include "arc_internal.h"

ArcSpinLock g_weak_lock = { 0u };
static ArcWeakArray     *g_weak_head = NULL;
_Atomic uint64_t  g_weak_count = 0;

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

void weak_targets_insert(int64_t v)
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

__attribute__((noinline)) void clear_weak_target(ArcHeader *hdr)
{
    arc_lock(&g_weak_lock);
    weak_clear_target_locked((int64_t)(uintptr_t)(hdr + 1));
    arc_unlock(&g_weak_lock);
}

void weak_unlink(ArcWeakArray *w)
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

DEFINE_IMMORTAL_STR(g_inv_arg_weak_str, "Weak.create");
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

int64_t ocamlcc_weak_table_cap(int64_t unit)
{
    (void)unit;
    arc_lock(&g_weak_lock);
    uint64_t cap = (g_weak_targets == NULL) ? 0u : (g_weak_targets_mask + 1u);
    arc_unlock(&g_weak_lock);
    return tag_int((int64_t)cap);
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
        ocamlcc_raise_invalid_arg_oob();
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
        ocamlcc_raise_invalid_arg_oob();
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
        ocamlcc_raise_invalid_arg_oob();
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
        ocamlcc_raise_invalid_arg_oob();
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
        ocamlcc_raise_invalid_arg_oob();
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
