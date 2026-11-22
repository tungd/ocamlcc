/* Slab pages, size-class allocation, and per-thread magazines. */
#include "arc_internal.h"

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

_Static_assert((SLAB_SIZE & (SLAB_SIZE - 1u)) == 0u,
               "Slab lookup requires power-of-two alignment");
_Static_assert((sizeof(SlabPage) % 16u) == 0u,
               "SlabPage header must preserve 16-byte slot alignment");

static SlabPage  *g_partial_slabs[NUM_SIZE_CLASSES];
static SlabPage  *g_full_slabs[NUM_SIZE_CLASSES];
static uint32_t   g_class_slab_count[NUM_SIZE_CLASSES];

_Atomic int64_t g_active_slabs = 0;
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

#ifdef OCAMLCC_SINGLE_THREAD_RC
SlabMagazine single_magazines[NUM_SIZE_CLASSES];

static inline SlabMagazine *slab_magazine(int cls)
{
    return &single_magazines[cls];
}
#else
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
#endif

#ifdef OCAMLCC_SINGLE_THREAD_RC
void slab_spill_single(SlabMagazine *m)
{
    /* No thread teardown will drain these slots. Age them out as
     * newer slots move through the process-owned magazine. */
    m->count /= 2u;
    slab_return_slots(m->slots, m->count);
    pal_memmove(m->slots, m->slots + m->count, m->count * sizeof(*m->slots));
}
#else
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
        SlabMagazine *m = slab_magazine(cls);
        if (m != NULL) {
            if (m->count != 0)
                return m->slots[--m->count];
            return slab_alloc_shared(cls, m->slots, &m->count);
        }
        return slab_alloc_shared(cls, NULL, NULL);
    }

    size_t page_sz = align_up_large(total_bytes);
    ArcHeader *hdr = (ArcHeader *)pal_page_alloc(page_sz);
    if (hdr == NULL)
        pal_abort();
    return hdr;
}

#ifndef OCAMLCC_SINGLE_THREAD_RC
void slab_free(ArcHeader *hdr)
{
    uint32_t total_bytes = (uint32_t)sizeof(ArcHeader) + hdr->byte_size;
    if (total_bytes <= k_class_sizes[NUM_SIZE_CLASSES - 1]) {
        SlabMagazine *m = slab_magazine((int)slab_owner(hdr)->cls);
        if (m != NULL) {
            slab_cache_slot(m, hdr);
            return;
        }
        slab_return_slots(&hdr, 1u);
    } else {
        pal_page_free(hdr, align_up_large(total_bytes));
    }
}

#endif

void *alloc_object(uint16_t tag, uint16_t scan_fields, uint32_t byte_size)
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

void *arc_alloc(uint16_t tag, uint16_t scan_fields, uint32_t byte_size)
{
    return alloc_object(tag, raw_scan_fields(tag, scan_fields, byte_size), byte_size);
}

void *ocamlcc_alloc_immediate_array(uint32_t byte_size)
{
    return alloc_object(ARC_TAG_ARRAY, 0u, byte_size);
}
