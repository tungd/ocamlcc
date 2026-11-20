/*
 * arc.h — Perceus-style Automatic Reference Counting (design doc §4.2).
 *
 * Object layout: the header precedes the user data pointer. Reference
 * counts use C11 atomics for thread-safe multi-queue Mobile FFI; the
 * 0xFFFFFFFF sentinel marks immortal/static objects.
 */
#ifndef OCAMLCC_ARC_H
#define OCAMLCC_ARC_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#define ARC_IMMORTAL 0xFFFFFFFFu

/* Object tags >= 245 are reserved for runtime-managed objects; OCaml
 * algebraic constructors use 0..244. */
#define ARC_TAG_ARRAY       245u
#define ARC_TAG_PAP         246u
#define ARC_TAG_CLOSURE     247u
#define ARC_TAG_WEAK        249u
#define ARC_TAG_FIBER       250u
#define ARC_TAG_STRING      252u
#define ARC_TAG_FLOAT       253u
#define ARC_TAG_FLOAT_ARRAY 254u
#define ARC_TAG_CUSTOM      255u
#define ARC_TAG_LAZY        256u
#define ARC_TAG_FORCING     257u
#define ARC_TAG_FORWARD     258u

#define ARC_CUSTOM_INT32     0u
#define ARC_CUSTOM_INT64     1u
#define ARC_CUSTOM_NATIVEINT 2u
#define ARC_CUSTOM_MUTEX     3u
#define ARC_CUSTOM_COND      4u
#define ARC_CUSTOM_BIGARRAY  6u
#define ARC_CUSTOM_BIGARRAY_BUFFER 7u

/* The top scan-count bit is spare when the payload cannot hold 32768
 * fields. Larger blocks retain the full scan count. */
#define ARC_FLAG_WEAK_TARGET 0x8000u

typedef struct ArcHeader {
    _Atomic uint32_t refcount;    /* 0xFFFFFFFF = immortal/static */
    uint16_t         tag;         /* constructor tag / object kind */
    _Atomic uint16_t scan_fields; /* pointer-field count and weak-target hint */
    uint32_t         byte_size;   /* total size, for slab reuse */
    /* CC bookkeeping + custom kind. Written under g_cc_lock by the cycle
     * collector, but read lock-free in release_subtree's CC_BUFFERED check
     * (while another thread's cc_roots_remove_locked may swap-move this
     * header and rewrite it), so it must be atomic to be C11-defined. */
    _Atomic uint32_t reserved;
} ArcHeader;

_Static_assert(sizeof(ArcHeader) == 16u, "ArcHeader must remain 16 bytes");

static inline int arc_has_spare_scan_bit(const ArcHeader *header)
{
    return header->byte_size < ARC_FLAG_WEAK_TARGET * 8u;
}

static inline uint16_t arc_scan_count(const ArcHeader *header)
{
    uint16_t count = atomic_load_explicit(&header->scan_fields, memory_order_relaxed);
    if ((count & ARC_FLAG_WEAK_TARGET) != 0 && arc_has_spare_scan_bit(header))
        return (uint16_t)(count & ~ARC_FLAG_WEAK_TARGET);
    return count;
}

typedef struct ArcClosure {
    void    *code;   /* entry point (clos, arg0, ..., arg_{arity-1}) */
    uint64_t arity;  /* expected parameter count (>= 1) */
    uint64_t env[];  /* captured free variables */
} ArcClosure;

typedef struct ArcPap {
    ArcClosure *orig;        /* underlying closure */
    uint64_t    total_arity; /* orig->arity */
    uint64_t    n_applied;   /* number of arguments captured so far */
    int64_t     args[];      /* captured arguments */
} ArcPap;

void *arc_alloc(uint16_t tag, uint16_t scan_fields, uint32_t byte_size);
void *arc_alloc_bytes(uint64_t len);
void *arc_alloc_array(uint64_t len, int64_t init);
void  arc_retain(void *obj);
void  arc_release(void *obj);
void  arc_retain_val(int64_t val);
void  arc_release_val(int64_t val);
void *arc_drop_reuse(int64_t val);
void *arc_alloc_reuse(void *reuse_tok, uint16_t tag, uint16_t scan_fields, uint32_t byte_size);
void *arc_alloc_reuse_or(void *primary, void *fallback, uint16_t tag,
                         uint16_t scan_fields, uint32_t byte_size);
void  arc_free_reuse(void *reuse_tok);
int64_t arc_live_objects(void);
int64_t arc_reuse_hits(void);
int64_t ocamlcc_arc_live(int64_t unit);
int64_t ocamlcc_arc_reuse(int64_t unit);
int64_t ocamlcc_arc_collect(int64_t unit);
int64_t ocamlcc_arc_slab_count(int64_t unit);
int64_t ocamlcc_weak_table_cap(int64_t unit);

int64_t ocamlcc_get_exn(void);
void    ocamlcc_set_exn(int64_t exn);
void    ocamlcc_format_exn(int64_t ex, char *buf, size_t cap);
void    ocamlcc_raise_invalid_arg_oob(void);

/* Raise Invalid_argument for a coroutine/scheduler cross-call (e.g.
   Fiber.suspend inside a spawned fiber, Fiber.yield inside a coroutine). */
void ocamlcc_fiber_raise_invalid(void);

/* Raise Sys_error when a PAL pipe cannot be created. */
void ocamlcc_raise_sys_error_pipe(void);
int64_t caml_fresh_oo_id(int64_t ignored);
int64_t caml_alloc_dummy(int64_t size_val);
int64_t caml_alloc_dummy_float(int64_t size_val);
int64_t caml_alloc_dummy_lazy(int64_t size_val);
int64_t caml_update_dummy(int64_t dummy_val, int64_t new_val);
int64_t caml_update_dummy_lazy(int64_t dummy_val, int64_t new_val);

int64_t ocamlcc_weak_create(int64_t len);
int64_t ocamlcc_weak_length(int64_t weak_val);
int64_t ocamlcc_weak_set(int64_t weak_val, int64_t idx, int64_t opt_val);
int64_t ocamlcc_weak_get(int64_t weak_val, int64_t idx);
int64_t ocamlcc_weak_get_copy(int64_t weak_val, int64_t idx);
int64_t ocamlcc_weak_check(int64_t weak_val, int64_t idx);

int64_t ocamlcc_print_int_val(int64_t val);
int64_t ocamlcc_print_char_val(int64_t val);
int64_t ocamlcc_print_float_val(int64_t val);
int64_t ocamlcc_print_string_val(int64_t val);
int64_t ocamlcc_prerr_string_val(int64_t val);
int64_t ocamlcc_print_endline_val(int64_t val);
void    ocamlcc_exit_val(int64_t val) __attribute__((noreturn));

int64_t ocamlcc_alloc_float(double d);
int64_t ocamlcc_alloc_custom(uint32_t kind, uint64_t bits);
int64_t ocamlcc_gen_makearray(int64_t n, const int64_t *elems);
int64_t ocamlcc_gen_array_get(int64_t safe, int64_t arr, int64_t idx_val);
int64_t ocamlcc_gen_array_set(int64_t safe, int64_t arr, int64_t idx_val, int64_t v);

int64_t caml_format_float(int64_t fmt_val, int64_t float_val);
int64_t caml_float_of_string(int64_t s_val);

int64_t caml_int32_to_float(int64_t v);
int64_t caml_int32_of_float(int64_t v);
int64_t caml_int32_bits_of_float(int64_t v);
int64_t caml_int32_float_of_bits(int64_t v);
int64_t caml_int64_to_float(int64_t v);
int64_t caml_int64_of_float(int64_t v);
int64_t caml_int64_bits_of_float(int64_t v);
int64_t caml_int64_float_of_bits(int64_t v);
int64_t caml_nativeint_to_float(int64_t v);
int64_t caml_nativeint_of_float(int64_t v);

int64_t caml_sqrt_float(int64_t v);
int64_t caml_floor_float(int64_t v);
int64_t caml_ceil_float(int64_t v);
int64_t caml_fmod_float(int64_t a, int64_t b);
int64_t caml_copysign_float(int64_t a, int64_t b);
int64_t caml_classify_float(int64_t v);

int64_t caml_compare(int64_t a, int64_t b);
int64_t caml_equal(int64_t a, int64_t b);
int64_t caml_notequal(int64_t a, int64_t b);
int64_t caml_lessthan(int64_t a, int64_t b);
int64_t caml_lessequal(int64_t a, int64_t b);
int64_t caml_greaterthan(int64_t a, int64_t b);
int64_t caml_greaterequal(int64_t a, int64_t b);
int64_t caml_hash(int64_t count, int64_t limit, int64_t seed, int64_t obj);

int64_t ocamlcc_apply1(int64_t clos, int64_t a0);
int64_t ocamlcc_apply2(int64_t clos, int64_t a0, int64_t a1);
int64_t ocamlcc_apply3(int64_t clos, int64_t a0, int64_t a1, int64_t a2);
int64_t ocamlcc_apply4(int64_t clos, int64_t a0, int64_t a1, int64_t a2, int64_t a3);
int64_t ocamlcc_apply_n(int64_t clos, int64_t argc, int64_t *argv);
/* Internal entry points. The calling OS thread is already a mutator. */
int64_t ocamlcc_apply1_raw(int64_t clos, int64_t a0);
int64_t ocamlcc_apply2_raw(int64_t clos, int64_t a0, int64_t a1);
int64_t ocamlcc_apply3_raw(int64_t clos, int64_t a0, int64_t a1, int64_t a2);
int64_t ocamlcc_apply4_raw(int64_t clos, int64_t a0, int64_t a1, int64_t a2, int64_t a3);
int64_t ocamlcc_apply_n_raw(int64_t clos, int64_t argc, int64_t *argv);

/* Mutator-gate hooks used at C->OCaml FFI entrypoints so ocamlcc_arc_collect
   drains active FFI mutators safely. C hosts must not drop/mutate cycle-
   candidate objects directly outside ocamlcc_apply* during collection. */
/* The optional single-thread RC build binds to the first thread to enter
   here or initialize an OCaml module. Raw C runtime calls in that build
   must execute on the same thread. Generated bindings enter automatically. */
int  arc_mutator_enter(void);
void arc_mutator_leave(int entered);

#endif /* OCAMLCC_ARC_H */
