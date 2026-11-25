/* Private implementation shared by the ARC runtime translation units. */
#ifndef OCAMLCC_ARC_INTERNAL_H
#define OCAMLCC_ARC_INTERNAL_H

#include "arc.h"
#include "ocamlcc_bigarray.h"

#include "fiber.h"
#include "pal.h"
#include <stdbool.h>
#include <pthread.h>

#define ARC_PRIVATE __attribute__((visibility("hidden")))

#define SLAB_SIZE        (64u * 1024u)
#define LARGE_PAGE_ALIGN (16u * 1024u)
#define NUM_SIZE_CLASSES 12
static const uint32_t k_class_sizes[NUM_SIZE_CLASSES] = {
    16u, 32u, 48u, 64u, 96u, 128u, 192u, 256u, 384u, 512u, 1024u, 2048u
};

typedef struct ArcWeakArray {
    struct ArcWeakArray *prev;
    struct ArcWeakArray *next;
    uint64_t             len;
    int64_t              slots[];
} ArcWeakArray;
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

typedef struct ArcSpinLock {
    _Atomic uint32_t locked;
} ArcSpinLock;

typedef struct OcamlccThreadCtx {
    pthread_t tid;
    int64_t fn;      /* owned closure until the worker runs it */
    int64_t result;  /* owned result after completion (0 until then) */
    int64_t exn;     /* owned exception after completion (0 until then) */
    int32_t id;
} OcamlccThreadCtx;

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


/* Cross-file allocator and collector state. Mutator and registry access
 * follows the same lock order throughout the runtime. */
extern ARC_PRIVATE _Atomic int64_t g_live_objects;
extern ARC_PRIVATE _Atomic int64_t g_active_slabs;
extern ARC_PRIVATE _Atomic uint64_t g_alloc_words;
extern ARC_PRIVATE ArcSpinLock g_weak_lock;
extern ARC_PRIVATE _Atomic uint64_t g_weak_count;
extern ARC_PRIVATE ArcSpinLock g_cc_lock;
extern ARC_PRIVATE _Atomic int g_cc_active;
extern ARC_PRIVATE _Atomic int g_cc_waiting;
extern ARC_PRIVATE _Atomic int g_active_mutators;
extern ARC_PRIVATE _Thread_local int tls_os_mutator_active;

#ifdef OCAMLCC_SINGLE_THREAD_RC
extern ARC_PRIVATE _Atomic unsigned g_rc_owner_claimed;
extern ARC_PRIVATE _Thread_local int tls_rc_owner;
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

static inline int is_heap_ptr(int64_t val)
{
    return val != 0 && (val & 1) == 0;
}

/* The caller either owns the last drop or is the single mutator. A
 * shared-runtime decrement may not inspect fields that can still change. */
static inline int is_small_immediate_block(const ArcHeader *hdr)
{
    if (hdr->tag >= ARC_TAG_ARRAY || hdr->byte_size > 2u * sizeof(int64_t))
        return 0;
    uint16_t count = arc_scan_count(hdr);
    const int64_t *fields = (const int64_t *)(hdr + 1);
    return count <= 2u &&
           (count == 0u || !is_heap_ptr(fields[0])) &&
           (count < 2u || !is_heap_ptr(fields[1]));
}

static inline int is_unscanned_leaf_tag(uint16_t tag)
{
    return tag == (uint16_t)ARC_TAG_STRING ||
           tag == (uint16_t)ARC_TAG_WEAK ||
           tag == (uint16_t)ARC_TAG_FLOAT ||
           tag == (uint16_t)ARC_TAG_FLOAT_ARRAY ||
           tag == (uint16_t)ARC_TAG_CUSTOM;
}

/* Word arrays use scan_fields as a presence bit. Arrays with pointers
 * always traverse their full length, which can exceed UINT16_MAX. */
static inline uint32_t array_pointer_slots(const ArcHeader *hdr)
{
    return arc_scan_count(hdr) == 0u ? 0u : hdr->byte_size / 8u;
}

static inline void array_enable_scan(ArcHeader *hdr)
{
    if (arc_scan_count(hdr) == 0u)
        atomic_fetch_or_explicit(&hdr->scan_fields, 1u, memory_order_relaxed);
}

static inline int has_cycle_edges(const ArcHeader *hdr)
{
    uint16_t tag = hdr->tag;
    if (is_unscanned_leaf_tag(tag))
        return 0;
    if (tag == (uint16_t)ARC_TAG_FIBER)
        return 1; /* the shadow stack holds owning references (see
                     cc_visit_children); queued fibers keep the scheduler's
                     +1 from spawn and survive every trial */
    if (tag == (uint16_t)ARC_TAG_PAP)
        return 1;
    return arc_scan_count(hdr) > 0u;
}

static inline int is_cycle_candidate_obj(const ArcHeader *hdr)
{
    return atomic_load_explicit(&hdr->refcount, memory_order_relaxed) != ARC_IMMORTAL &&
           has_cycle_edges(hdr);
}


ARC_PRIVATE void *alloc_object(uint16_t tag, uint16_t scan_fields, uint32_t byte_size);
#define SLAB_MAGAZINE_CAPACITY 16u

typedef struct FreeSlot {
    struct FreeSlot *next;
} FreeSlot;

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

typedef struct {
    ArcHeader *slots[SLAB_MAGAZINE_CAPACITY];
    uint32_t count;
} SlabMagazine;

static inline SlabPage *slab_owner(const ArcHeader *hdr)
{
    return (SlabPage *)((uintptr_t)hdr & ~((uintptr_t)SLAB_SIZE - 1u));
}

static inline size_t align_up_large(uint32_t total_bytes)
{
    size_t mask = (size_t)LARGE_PAGE_ALIGN - 1u;
    return ((size_t)total_bytes + mask) & ~mask;
}

#ifdef OCAMLCC_SINGLE_THREAD_RC
extern ARC_PRIVATE SlabMagazine single_magazines[NUM_SIZE_CLASSES];
ARC_PRIVATE void slab_spill_single(SlabMagazine *magazine);

/* The process-owned magazine can accept small drops without a call.
 * Spilling and returning pages are the allocator's slow paths. */
static inline void slab_free(ArcHeader *hdr)
{
    uint32_t total_bytes = (uint32_t)sizeof(ArcHeader) + hdr->byte_size;
    if (total_bytes <= k_class_sizes[NUM_SIZE_CLASSES - 1]) {
        SlabMagazine *magazine = &single_magazines[slab_owner(hdr)->cls];
        if (magazine->count == SLAB_MAGAZINE_CAPACITY)
            slab_spill_single(magazine);
        magazine->slots[magazine->count++] = hdr;
    } else {
        pal_page_free(hdr, align_up_large(total_bytes));
    }
}
#else
ARC_PRIVATE void slab_free(ArcHeader *hdr);
#endif

ARC_PRIVATE void ccvec_push(CCVec *v, ArcHeader *h);
ARC_PRIVATE void ccvec_free(CCVec *v);
typedef void (*CcChildFn)(int64_t val, void *ctx);
ARC_PRIVATE void cc_visit_children(ArcHeader *hdr, CcChildFn fn, void *ctx);
ARC_PRIVATE void cc_roots_add_slow(ArcHeader *hdr);
ARC_PRIVATE void cc_roots_remove_locked(ArcHeader *hdr);
ARC_PRIVATE int64_t collect_cycles(int discover_finalizers);

ARC_PRIVATE void weak_targets_insert(int64_t val);
ARC_PRIVATE void clear_weak_target(ArcHeader *hdr);
ARC_PRIVATE void weak_unlink(ArcWeakArray *w);
ARC_PRIVATE void raise_invalid_arg_imm(const char *imm_str);
ARC_PRIVATE int64_t dup_with_tag(int64_t v, int override_tag, uint16_t new_atag);

ARC_PRIVATE void defer_foreign_releases(void);
ARC_PRIVATE void resume_foreign_releases(void);

static inline __attribute__((always_inline)) void cc_roots_add(ArcHeader *hdr)
{
    /* Callers hold an owner and have already rejected immortal objects.
     * Keep the common eligibility check separate from lock and vector growth. */
    if ((atomic_load_explicit(&hdr->reserved, memory_order_relaxed) & CC_BUFFERED) != 0u ||
        !has_cycle_edges(hdr))
        return;
#ifdef OCAMLCC_SINGLE_THREAD_RC
    if (is_small_immediate_block(hdr))
        return;
#endif
    cc_roots_add_slow(hdr);
}

static inline int might_be_weak_target(ArcHeader *hdr)
{
    /* Registration has an owning reference. The final decrement or the
     * collector's mutator handoff makes its mark visible before retirement.
     * Oversized payloads keep the original scan-count representation. */
    if (arc_has_spare_scan_bit(hdr))
        return (atomic_load_explicit(&hdr->scan_fields, memory_order_relaxed) &
                ARC_FLAG_WEAK_TARGET) != 0u;
    return atomic_load_explicit(&g_weak_count, memory_order_acquire) != 0u;
}

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
static inline int64_t tag_int(int64_t n)
{
    return (int64_t)(((uint64_t)n << 1) | 1ull);
}

static inline int size_class_for(uint32_t total_bytes)
{
    /* The first eight classes in k_class_sizes rounded up to 16 bytes. */
    static const uint8_t small_class[] = {
        0, 0, 1, 2, 3, 4, 4, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7
    };
    if (total_bytes <= 256u)
        return small_class[(total_bytes + 15u) >> 4];
    for (int i = 8; i < NUM_SIZE_CLASSES; i++) {
        if (total_bytes <= k_class_sizes[i])
            return i;
    }
    return -1;
}

static inline uint16_t raw_scan_fields(uint16_t tag, uint16_t scan, uint32_t size)
{
    /* A C caller can populate raw array storage with pointers. */
    return tag == ARC_TAG_ARRAY && size >= 8u && scan == 0u ? 1u : scan;
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
/* Registrations own both their callback and a temporary pin on the target.
 * The major-collection trial discounts these pins to find unreachable values.
 * Ordinary ARC release and reuse therefore need no registry lookup or lock. */
typedef struct Finalizer {
    struct Finalizer *next;
    int64_t value; /* ordinary target, or a one-slot weak array for last callbacks */
    int64_t callback;
    int last;
} Finalizer;
static inline ArcHeader *finalizer_target(Finalizer *f)
{
    return (ArcHeader *)(uintptr_t)f->value - 1;
}


extern const void *ocamlcc_global_Not_found;

extern ARC_PRIVATE Finalizer *finalizers; /* protected by g_cc_lock */
ARC_PRIVATE void append_pending(Finalizer *ready);

#endif
