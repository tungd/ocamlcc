/*
 * arc.h — Perceus-style Automatic Reference Counting (design doc §4.2).
 *
 * Object layout: the header precedes the user data pointer. Reference
 * counts are non-atomic in this phase (single-threaded scheduler); the
 * 0xFFFFFFFF sentinel marks immortal/static objects.
 */
#ifndef OCAMLCC_ARC_H
#define OCAMLCC_ARC_H

#include <stddef.h>
#include <stdint.h>

#define ARC_IMMORTAL 0xFFFFFFFFu

/* Object tags >= 245 are reserved for runtime-managed objects; OCaml
 * algebraic constructors use 0..244. */
#define ARC_TAG_ARRAY   245u
#define ARC_TAG_PAP     246u
#define ARC_TAG_CLOSURE 247u
#define ARC_TAG_WEAK    249u
#define ARC_TAG_FIBER   250u
#define ARC_TAG_STRING  252u

typedef struct ArcHeader {
    uint32_t refcount;   /* 0xFFFFFFFF = immortal/static */
    uint16_t tag;        /* constructor tag / object kind */
    uint16_t scan_fields;/* pointer fields to dec_ref on drop */
    uint32_t byte_size;  /* total size, for slab reuse */
    uint32_t reserved;
} ArcHeader;

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
void  arc_free_reuse(void *reuse_tok);
int64_t arc_live_objects(void);
int64_t arc_reuse_hits(void);
int64_t ocamlcc_arc_live(int64_t unit);
int64_t ocamlcc_arc_reuse(int64_t unit);
int64_t ocamlcc_arc_collect(int64_t unit);

extern int64_t ocamlcc_exn_slot;
void ocamlcc_raise_invalid_arg_oob(void);
int64_t caml_fresh_oo_id(int64_t ignored);

int64_t ocamlcc_weak_create(int64_t len);
int64_t ocamlcc_weak_length(int64_t weak_val);
int64_t ocamlcc_weak_set(int64_t weak_val, int64_t idx, int64_t opt_val);
int64_t ocamlcc_weak_get(int64_t weak_val, int64_t idx);
int64_t ocamlcc_weak_get_copy(int64_t weak_val, int64_t idx);
int64_t ocamlcc_weak_check(int64_t weak_val, int64_t idx);

int64_t ocamlcc_print_int_val(int64_t val);
int64_t ocamlcc_print_char_val(int64_t val);
int64_t ocamlcc_print_string_val(int64_t val);
int64_t ocamlcc_prerr_string_val(int64_t val);
int64_t ocamlcc_print_endline_val(int64_t val);
void    ocamlcc_exit_val(int64_t val) __attribute__((noreturn));

int64_t caml_compare(int64_t a, int64_t b);
int64_t caml_equal(int64_t a, int64_t b);
int64_t caml_notequal(int64_t a, int64_t b);
int64_t caml_lessthan(int64_t a, int64_t b);
int64_t caml_lessequal(int64_t a, int64_t b);
int64_t caml_greaterthan(int64_t a, int64_t b);
int64_t caml_greaterequal(int64_t a, int64_t b);
int64_t caml_hash(int64_t count, int64_t limit, int64_t seed, int64_t obj);

int64_t caml_blit_bytes(int64_t src, int64_t src_off, int64_t dst, int64_t dst_off, int64_t len);
int64_t caml_blit_string(int64_t src, int64_t src_off, int64_t dst, int64_t dst_off, int64_t len);
int64_t caml_fill_bytes(int64_t dst, int64_t off, int64_t len, int64_t ch);
int64_t caml_string_equal(int64_t a, int64_t b);
int64_t caml_bytes_equal(int64_t a, int64_t b);
int64_t caml_string_compare(int64_t a, int64_t b);
int64_t caml_bytes_compare(int64_t a, int64_t b);

int64_t ocamlcc_apply1(int64_t clos, int64_t a0);
int64_t ocamlcc_apply2(int64_t clos, int64_t a0, int64_t a1);
int64_t ocamlcc_apply3(int64_t clos, int64_t a0, int64_t a1, int64_t a2);
int64_t ocamlcc_apply4(int64_t clos, int64_t a0, int64_t a1, int64_t a2, int64_t a3);
int64_t ocamlcc_apply_n(int64_t clos, int64_t argc, int64_t *argv);

#endif /* OCAMLCC_ARC_H */
