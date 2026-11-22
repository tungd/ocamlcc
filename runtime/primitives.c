/* Native implementations of standard-library primitives and Bigarray. */
#include "arc_internal.h"

#define OCAMLCC_CAML_ALLOC 1
#include "caml/custom.h"
#include <string.h>

static int ba_compare(const ArcBigarray *, const ArcBigarray *, int);
static uint32_t ba_hash(const ArcBigarray *);

static _Atomic int64_t lexing_engine;

int64_t ocamlcc_lexing_install_engine(int64_t engine)
{
    int64_t empty = 0;
    arc_retain_val(engine);
    if (!atomic_compare_exchange_strong_explicit(&lexing_engine, &empty, engine,
            memory_order_release, memory_order_relaxed))
        arc_release_val(engine);
    return 1;
}

static int64_t apply_lexing_engine(bool with_memory, int64_t tables,
                                  int64_t state, int64_t buffer)
{
    int64_t engine = atomic_load_explicit(&lexing_engine, memory_order_acquire);
    if (engine == 0)
        pal_abort();
    /* C primitives borrow their arguments. The OCaml closure takes owners. */
    arc_retain_val(tables);
    arc_retain_val(buffer);
    return ocamlcc_apply4_raw(engine, tag_int(with_memory), tables, state, buffer);
}

int64_t caml_lex_engine(int64_t tables, int64_t state, int64_t buffer)
{
    return apply_lexing_engine(false, tables, state, buffer);
}

int64_t caml_new_lex_engine(int64_t tables, int64_t state, int64_t buffer)
{
    return apply_lexing_engine(true, tables, state, buffer);
}

static _Atomic int64_t g_next_oo_id = 0;

int64_t caml_fresh_oo_id(int64_t ignored)
{
    (void)ignored;
    int64_t id = atomic_fetch_add_explicit(&g_next_oo_id, 1, memory_order_relaxed);
    return tag_int(id);
}

DEFINE_IMMORTAL_STR(g_inv_arg_fn_str, "compare: functional value");
DEFINE_IMMORTAL_STR(g_inv_arg_bytes_str, "Bytes.create");
DEFINE_IMMORTAL_STR(g_inv_arg_array_str, "Array.make");
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
    uint16_t scan = len != 0 && is_heap_ptr(init) ? 1u : 0u;
    int64_t *arr = alloc_object(ARC_TAG_ARRAY, scan, (uint32_t)(len * 8u));
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

void ocamlcc_store_boxed_float(int64_t *slot, double value)
{
    int64_t old = *slot;
    if (is_heap_ptr(old)) {
        ArcHeader *hdr = (ArcHeader *)(uintptr_t)old - 1;
        /* A strong alias or a possible Weak.get must still see the old box. */
        if (hdr->tag == ARC_TAG_FLOAT &&
            atomic_load_explicit(&hdr->refcount, memory_order_acquire) == 1u &&
            !might_be_weak_target(hdr)) {
            *(double *)(uintptr_t)old = value;
            return;
        }
    }
    *slot = ocamlcc_alloc_float(value);
    arc_release_val(old);
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
    int64_t *arr = ocamlcc_alloc_immediate_array((uint32_t)((uint64_t)n * 8u));
    int has_pointer = 0;
    for (int64_t i = 0; i < n; i++) {
        arr[i] = elems[i];
        has_pointer |= is_heap_ptr(elems[i]);
    }
    if (has_pointer)
        array_enable_scan((ArcHeader *)arr - 1);
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

static inline void array_replace_owned(ArcHeader *hdr, int64_t *slot, int64_t value)
{
    if (is_heap_ptr(value))
        array_enable_scan(hdr);
    int64_t old = *slot;
    *slot = value;
    arc_release_val(old);
}

void ocamlcc_addr_array_set(int64_t arr, int64_t idx_val, int64_t value)
{
    ArcHeader *hdr = (ArcHeader *)(uintptr_t)arr - 1;
    int64_t *slot = (int64_t *)(uintptr_t)arr + (idx_val >> 1);
    array_replace_owned(hdr, slot, value);
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
    ocamlcc_addr_array_set(arr, idx_val, v);
    return 1;
}

static int array_is_flat_float(int64_t value)
{
    return ((const ArcHeader *)(uintptr_t)value - 1)->tag == ARC_TAG_FLOAT_ARRAY;
}

/* A marked array can still have immediate-only ranges. */
static int array_words_are_immediate(int64_t arr, const int64_t *words, size_t count)
{
    if (arc_scan_count((const ArcHeader *)(uintptr_t)arr - 1) == 0u)
        return 1;
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
    int needs_retain = !flat_float && !array_words_are_immediate(src, from, count);
    uint16_t tag = flat_float ? ARC_TAG_FLOAT_ARRAY : ARC_TAG_ARRAY;
    int64_t *copy = alloc_object(tag, (uint16_t)needs_retain,
                                 (uint32_t)(count * sizeof(*copy)));
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
    int immediate = src_float || array_words_are_immediate(src, from, count);
    if (immediate && (src_float || array_words_are_immediate(dst, to, count))) {
        pal_memmove(dst_slice, src_slice, count * sizeof(*to));
        return 1;
    }
    if (!immediate)
        array_enable_scan((ArcHeader *)(uintptr_t)dst - 1);
    if (src == dst && dst_off > src_off) {
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
        if ((value & 1) && array_words_are_immediate(dst, to, count)) {
            for (size_t i = 0; i < count; i++)
                to[i] = value;
        } else {
            if (is_heap_ptr(value))
                array_enable_scan((ArcHeader *)(uintptr_t)dst - 1);
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

static const struct custom_operations *foreign_custom_ops(int64_t v)
{
    if (!is_heap_ptr(v))
        return NULL;
    const ArcHeader *header = (const ArcHeader *)(uintptr_t)v - 1;
    if (header->tag != ARC_TAG_CUSTOM || header->reserved != ARC_CUSTOM_FOREIGN)
        return NULL;
    return Custom_ops_val(v);
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
        if (ia || ib) {
            const struct custom_operations *ops = foreign_custom_ops(ia ? b : a);
            if (ops != NULL && ops->compare_ext != NULL)
                return ops->compare_ext(a, b);
            return ia ? -1 : 1;
        }

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
            if (ha->reserved == ARC_CUSTOM_FOREIGN) {
                const struct custom_operations *left = Custom_ops_val(a);
                const struct custom_operations *right = Custom_ops_val(b);
                if (left != right) {
                    int order = strcmp(left->identifier, right->identifier);
                    if (order != 0)
                        return order;
                }
                if (left->compare != NULL)
                    return left->compare(a, b);
            }
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
                if (hdr->reserved == ARC_CUSTOM_INT32 ||
                    hdr->reserved == ARC_CUSTOM_NATIVEINT) {
                    h = hash_mix_intnat(h, unbox_custom_i64(v));
                    num--;
                } else if (hdr->reserved == ARC_CUSTOM_BIGARRAY) {
                    h = hash_mix_intnat(h, ba_hash((void *)(uintptr_t)v));
                    num--;
                } else if (hdr->reserved == ARC_CUSTOM_INT64) {
                    h = hash_mix_int64(h, unbox_custom_i64(v));
                    num--;
                } else if (hdr->reserved == ARC_CUSTOM_FOREIGN && Custom_ops_val(v)->hash != NULL) {
                    h = hash_mix32(h, (uint32_t)Custom_ops_val(v)->hash(v));
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

static inline void mark_obj_pointer_store(int64_t obj_val, int64_t new_val)
{
    if (!is_heap_ptr(new_val))
        return;
    ArcHeader *hdr = (ArcHeader *)(uintptr_t)obj_val - 1;
    if (hdr->tag == ARC_TAG_ARRAY) {
        array_enable_scan(hdr);
    } else if ((hdr->tag < ARC_TAG_ARRAY || hdr->tag == 248u) &&
               arc_scan_count(hdr) == 0u) {
        /* Obj and computed atomic stores can add a pointer to an ordinary
         * block originally constructed with a zero scan count. Preserve the
         * weak-target hint when restoring the full scan count. */
        atomic_fetch_or_explicit(&hdr->scan_fields, (uint16_t)(hdr->byte_size / 8u),
                                 memory_order_relaxed);
    }
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
    /* Publish the scan bit before any successful pointer store. */
    mark_obj_pointer_store(obj_val, desired_val);
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
    mark_obj_pointer_store(obj_val, desired_val);
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
        ocamlcc_raise_invalid_arg_oob();
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
    mark_obj_pointer_store(obj_val, new_val);
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
    int64_t *p = alloc_object(atag, scan, (uint32_t)((uint64_t)sz * 8u));
    for (int64_t i = 0; i < sz; i++)
        p[i] = 1;
    return (int64_t)(uintptr_t)p;
}

int64_t dup_with_tag(int64_t v, int override_tag, uint16_t new_atag)
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
    uint32_t pointers = src_tag == ARC_TAG_ARRAY ? array_pointer_slots(hdr) : nf;
    uint16_t scan = tag == ARC_TAG_ARRAY ? (uint16_t)(pointers != 0u)
        : (nf > UINT16_MAX ? UINT16_MAX : (uint16_t)nf);
    int64_t *dst = alloc_object(tag, scan, hdr->byte_size);
    if (hdr->byte_size > 0u)
        pal_memcpy(dst, (const void *)(uintptr_t)v, hdr->byte_size);
    for (uint32_t i = 0u; i < pointers; i++)
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
            uint32_t n = array_pointer_slots(cur);
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
    if (!is_heap_ptr(obj))
        return 0;
    const int64_t *self = (const int64_t *)(uintptr_t)obj;
    const ArcHeader *object = (const ArcHeader *)self - 1;
    if (object->tag != ARC_TAG_OBJECT || object->byte_size < 2 * sizeof *self ||
        !is_heap_ptr(self[0]))
        return 0;

    /* The public prefix is [count; cache mask; method; label; ...]. */
    const int64_t *methods = (const int64_t *)(uintptr_t)self[0];
    const ArcHeader *table = (const ArcHeader *)methods - 1;
    size_t words = table->byte_size / sizeof *methods;
    if ((table->tag != ARC_TAG_ARRAY && table->tag != 0) || words < 2)
        return 0;
    size_t count = (size_t)(methods[0] >> 1);
    if (!(methods[0] & 1) || count > (words - 2) / 2)
        return 0;

    size_t low = 0, high = count;
    while (low < high) {
        size_t mid = low + (high - low) / 2;
        if (methods[3 + 2 * mid] < tag)
            low = mid + 1;
        else
            high = mid;
    }
    if (low == count || methods[3 + 2 * low] != tag)
        return 0;
    int64_t method = methods[2 + 2 * low];
    arc_retain_val(method);
    return method;
}

int64_t ocamlcc_public_method(int64_t obj, int64_t tag)
{
    int64_t method = caml_get_public_method(obj, tag);
    if (is_heap_ptr(method))
        return method;
    static const char message[] = "object method unavailable";
    raise_failure_cstr(message, sizeof message - 1);
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

#include "caml_compat.inc"
