/* Public C runtime contracts for standard library primitives and ARC views. */
#include "../runtime/arc.h"
#include "../runtime/fiber.h"
#include "../runtime/ocamlcc_bigarray.h"
#include "../runtime/pal.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

extern int64_t caml_input_value_from_bytes(int64_t, int64_t);
extern int64_t caml_output_value_to_bytes(int64_t, int64_t);
extern int64_t caml_ba_create(int64_t, int64_t, int64_t);
extern int64_t caml_ba_sub(int64_t, int64_t, int64_t);
extern int64_t caml_ba_set_1(int64_t, int64_t, int64_t);
extern int64_t caml_ba_get_1(int64_t, int64_t);
extern int64_t caml_obj_dup(int64_t);
extern int64_t caml_obj_with_tag(int64_t, int64_t);
extern int64_t caml_array_sub(int64_t, int64_t, int64_t);
extern int64_t caml_array_blit(int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t caml_array_fill(int64_t, int64_t, int64_t, int64_t);
extern int64_t caml_output_value_to_buffer(int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t caml_input_value(int64_t);
extern int64_t caml_ml_open_descriptor_in(int64_t);
extern int64_t caml_ml_open_descriptor_out(int64_t);
extern int64_t caml_ml_close_channel(int64_t);
extern int64_t caml_ml_output_bytes(int64_t, int64_t, int64_t, int64_t);
extern int64_t caml_ml_input(int64_t, int64_t, int64_t, int64_t);
extern int64_t caml_ml_flush(int64_t);
extern int64_t caml_ml_input_bigarray(int64_t, int64_t, int64_t, int64_t);
extern int64_t caml_ml_output_bigarray(int64_t, int64_t, int64_t, int64_t);
extern int64_t ocamlcc_fiber_create(int64_t);
extern int64_t ocamlcc_fiber_resume(int64_t, int64_t);
extern int64_t ocamlcc_fiber_fd_wait_read(int64_t);
extern int64_t ocamlcc_fiber_await(int64_t);
extern int64_t caml_lazy_make_forward(int64_t);
extern int64_t caml_compare(int64_t, int64_t);
extern int64_t caml_ml_mutex_new(int64_t);
extern int64_t caml_md5_chan(int64_t, int64_t);
extern int64_t caml_md5_bytes(int64_t, int64_t, int64_t);
extern int64_t caml_gc_full_major(int64_t);
extern int64_t caml_final_register_called_without_value(int64_t, int64_t);
extern int64_t ocamlcc_poll_finalizers(void);
extern int64_t ocamlcc_finalizers_due(void);
extern int64_t caml_obj_reachable_words(int64_t);

static int64_t tagged(int64_t n) { return (int64_t)(((uint64_t)n << 1) | 1); }

static void expect_format(int64_t (*format)(int64_t, int64_t),
                          const char *fmt, size_t len, int64_t value,
                          const char *expected)
{
    char *input = arc_alloc_bytes(len);
    memcpy(input, fmt, len);
    int64_t result = format((int64_t)(uintptr_t)input, value);
    const ArcHeader *header = (const ArcHeader *)(uintptr_t)result - 1;
    assert(!ocamlcc_get_exn());
    assert(header->reserved == strlen(expected));
    assert(memcmp((const char *)(uintptr_t)result, expected, header->reserved) == 0);
    arc_release_val(result);
    arc_release(input);
}

static void test_float_format(void)
{
    int64_t value = ocamlcc_alloc_float(1.25);
    expect_format(caml_format_float, "%+07.2f", sizeof("%+07.2f") - 1, value, "+001.25");
    expect_format(caml_format_float, "%.f", sizeof("%.f") - 1, value, "1");
    expect_format(caml_format_float, "value=%.2f", sizeof("value=%.2f") - 1, value, "");
    expect_format(caml_format_float, "%.2f%%", sizeof("%.2f%%") - 1, value, "");
    expect_format(caml_format_float, "%lf", sizeof("%lf") - 1, value, "");
    expect_format(caml_format_float, "%f\0", sizeof("%f\0") - 1, value, "");
    expect_format(caml_format_float, "%512f", sizeof("%512f") - 1, value, "");
    arc_release_val(value);
}

static void test_integer_format(void)
{
    expect_format(caml_format_int, "%+4i", sizeof("%+4i") - 1, tagged(42), " +42");
    expect_format(caml_format_int, "%l4d", sizeof("%l4d") - 1, tagged(42), "");
    expect_format(caml_format_int, "%\0", sizeof("%\0") - 1, tagged(42), "");
    expect_format(caml_format_int, "%128d", sizeof("%128d") - 1, tagged(42), "");

    int64_t i32 = ocamlcc_alloc_custom(ARC_CUSTOM_INT32, UINT32_MAX);
    expect_format(caml_int32_format, "%ld", sizeof("%ld") - 1, i32, "-1");
    expect_format(caml_int32_format, "%lu", sizeof("%lu") - 1, i32, "4294967295");
    expect_format(caml_int32_format, "%c", sizeof("%c") - 1, i32, "");
    expect_format(caml_int32_format, "%d%%", sizeof("%d%%") - 1, i32, "");
    arc_release_val(i32);

    int64_t i64 = ocamlcc_alloc_custom(ARC_CUSTOM_INT64, UINT64_MAX);
    expect_format(caml_int64_format, "%#LX", sizeof("%#LX") - 1, i64, "0XFFFFFFFFFFFFFFFF");
    expect_format(caml_int64_format, "%lld", sizeof("%lld") - 1, i64, "-1");
    arc_release_val(i64);

    int64_t native = ocamlcc_alloc_custom(ARC_CUSTOM_NATIVEINT, 42);
    expect_format(caml_nativeint_format, "%#.4no", sizeof("%#.4no") - 1, native, "0052");
    arc_release_val(native);
}

static void test_buffered_dummy_update(void)
{
    int64_t before = arc_live_objects();
    int64_t dummy = caml_alloc_dummy(tagged(1));
    arc_retain_val(dummy);
    arc_release_val(dummy);

    char *bytes = arc_alloc_bytes(4);
    memcpy(bytes, "text", 4);
    caml_update_dummy(dummy, (int64_t)(uintptr_t)bytes);
    assert(ocamlcc_arc_collect(1) == tagged(0));
    const ArcHeader *header = (const ArcHeader *)(uintptr_t)dummy - 1;
    assert(header->tag == ARC_TAG_STRING && header->reserved == 4);
    assert(memcmp((const void *)(uintptr_t)dummy, "text", 4) == 0);
    arc_release(bytes);
    arc_release_val(dummy);
    assert(arc_live_objects() == before);
}

static void clear_exception(void)
{
    int64_t ex = ocamlcc_get_exn(); assert(ex);
    ocamlcc_set_exn(0); arc_release_val(ex);
}
static int64_t stream(const unsigned char *payload, size_t n, unsigned objects)
{
    unsigned char *p = arc_alloc_bytes(20 + n);
    memset(p, 0, 20);
    p[0] = 0x84; p[1] = 0x95; p[2] = 0xa6; p[3] = 0xbe;
    p[7] = (unsigned char)n; p[11] = (unsigned char)objects;
    p[15] = 8; p[19] = 8;
    memcpy(p + 20, payload, n);
    return (int64_t)(uintptr_t)p;
}
static void test_partial_cycle(void)
{
    int64_t before = arc_live_objects();
    /* tuple(ref(self), <invalid code pointer>) creates a cycle before error */
    const unsigned char payload[] = {0xa0, 0x90, 0x04, 0x01, 0x10};
    int64_t bytes = stream(payload, sizeof(payload), 2);
    caml_input_value_from_bytes(bytes, 1); clear_exception();
    arc_release_val(bytes);
    assert(arc_live_objects() == before);
}
static void test_complete_cycle(void)
{
    int64_t before = arc_live_objects();
    const unsigned char payload[] = {0x90, 0x04, 0x01};
    int64_t bytes = stream(payload, sizeof(payload), 1);
    int64_t v = caml_input_value_from_bytes(bytes, 1);
    assert(!ocamlcc_get_exn()); assert(((int64_t *)(uintptr_t)v)[0] == v);
    arc_release_val(bytes); arc_release_val(v);
    ocamlcc_arc_collect(1);
    assert(arc_live_objects() == before);
}
static void test_truncation_and_mutation(void)
{
    int64_t before = arc_live_objects();
    int64_t *root = arc_alloc_array(2, 1);
    root[0] = tagged(42); root[1] = (int64_t)(uintptr_t)arc_alloc_bytes(50);
    memset((void *)(uintptr_t)root[1], 'a', 50);
    int64_t good = caml_output_value_to_bytes((int64_t)(uintptr_t)root, 1);
    assert(!ocamlcc_get_exn());
    size_t n = ((ArcHeader *)(uintptr_t)good - 1)->reserved;
    for (size_t i = 0; i < n; i++) {
        void *p = arc_alloc_bytes(i); memcpy(p, (void *)(uintptr_t)good, i);
        caml_input_value_from_bytes((int64_t)(uintptr_t)p, 1); clear_exception(); arc_release(p);
    }
    for (size_t i = 20; i < n; i++) {
        for (unsigned byte = 0; byte < 256; byte += 17) {
            unsigned char *p = arc_alloc_bytes(n); memcpy(p, (void *)(uintptr_t)good, n); p[i] = byte;
            int64_t value = caml_input_value_from_bytes((int64_t)(uintptr_t)p, 1);
            if (ocamlcc_get_exn()) clear_exception(); else arc_release_val(value);
            arc_release(p);
        }
    }
    arc_release_val(good); arc_release(root); ocamlcc_arc_collect(1);
    assert(arc_live_objects() == before);
}
static void test_view_lifetime(void)
{
    int64_t before = arc_live_objects();
    int64_t *dims = arc_alloc_array(1, tagged(4));
    int64_t owner = caml_ba_create(tagged(8), tagged(0), (int64_t)(uintptr_t)dims);
    int64_t view = caml_ba_sub(owner, tagged(1), tagged(2));
    caml_ba_set_1(view, tagged(0), tagged(99));
    arc_release_val(owner);
    assert(caml_ba_get_1(view, tagged(0)) == tagged(99));
    arc_release_val(view); arc_release(dims);
    assert(arc_live_objects() == before);
}
static void test_retained_c_subview(void)
{
    int64_t before = arc_live_objects();
    int64_t *dims = arc_alloc_array(1, tagged(4));
    int64_t parent = caml_ba_create(tagged(OCAMLCC_BA_INT), tagged(OCAMLCC_BA_C_LAYOUT),
                                    (int64_t)(uintptr_t)dims);
    arc_release(dims);
    int64_t sub = caml_ba_sub(parent, tagged(1), tagged(2));
    caml_ba_set_1(parent, tagged(1), tagged(42));
    int64_t sibling = caml_ba_sub(parent, tagged(2), tagged(1));
    int64_t weak = ocamlcc_weak_create(tagged(1));
    arc_retain_val(sub); /* transfer this owner into Some */
    int64_t *some = arc_alloc(0, 1, sizeof(*some));
    some[0] = sub;
    ocamlcc_weak_set(weak, tagged(0), (int64_t)(uintptr_t)some);
    arc_release(some);

    OcamlccBigarrayView *first = ocamlcc_bigarray_view_acquire(sub);
    assert(first != NULL);
    OcamlccBigarrayView *second = ocamlcc_bigarray_view_retain(first);
    assert(second != NULL);
    OcamlccBigarrayInfo info = ocamlcc_bigarray_view_info(first);
    arc_release_val(parent);
    arc_release_val(sub);
    ocamlcc_bigarray_view_release(first);
    ocamlcc_arc_collect(1);

    assert(ocamlcc_weak_check(weak, tagged(0)) == tagged(1));
    assert(info.kind == OCAMLCC_BA_INT && info.layout == OCAMLCC_BA_C_LAYOUT);
    assert(info.rank == 1 && info.dims[0] == 2);
    assert(info.byte_length == 2 * sizeof(int64_t));
    int64_t *data = info.data;
    assert(data[0] == 42);
    data[1] = 73;
    assert(caml_ba_get_1(sibling, tagged(0)) == tagged(73));

    arc_release_val(sibling);
    ocamlcc_arc_collect(1);
    assert(data[1] == 73 && info.dims[0] == 2);
    data[0] = 17;
    int64_t upgraded = ocamlcc_weak_get(weak, tagged(0));
    assert(upgraded != tagged(0));
    assert(caml_ba_get_1(*(int64_t *)(uintptr_t)upgraded, tagged(0)) == tagged(17));
    arc_release_val(upgraded);
    ocamlcc_bigarray_view_release(second);
    assert(ocamlcc_weak_check(weak, tagged(0)) == tagged(0));
    arc_release_val(weak);
    assert(arc_live_objects() == before);
}

static void test_c_view_shapes(void)
{
    int64_t before = arc_live_objects();
    int64_t *dims = arc_alloc_array(2, tagged(3));
    dims[1] = tagged(2);
    int64_t parent = caml_ba_create(tagged(OCAMLCC_BA_FLOAT64), tagged(OCAMLCC_BA_FORTRAN_LAYOUT),
                                    (int64_t)(uintptr_t)dims);
    arc_release(dims);
    /* Fortran sub indexes the last dimension from one. */
    int64_t column = caml_ba_sub(parent, tagged(2), tagged(1));
    int64_t empty = caml_ba_sub(parent, tagged(3), tagged(0));
    OcamlccBigarrayView *whole = ocamlcc_bigarray_view_acquire(parent);
    OcamlccBigarrayView *part = ocamlcc_bigarray_view_acquire(column);
    OcamlccBigarrayView *end = ocamlcc_bigarray_view_acquire(empty);
    assert(whole && part && end);
    OcamlccBigarrayInfo base = ocamlcc_bigarray_view_info(whole);
    OcamlccBigarrayInfo slice = ocamlcc_bigarray_view_info(part);
    OcamlccBigarrayInfo tail = ocamlcc_bigarray_view_info(end);
    assert(slice.kind == OCAMLCC_BA_FLOAT64 && slice.layout == OCAMLCC_BA_FORTRAN_LAYOUT);
    assert(slice.rank == 2 && slice.dims[0] == 3 && slice.dims[1] == 1);
    assert(slice.byte_length == 3 * sizeof(double) && slice.data == (double *)base.data + 3);
    assert(tail.byte_length == 0 && tail.dims[1] == 0);
    ocamlcc_bigarray_view_release(end);
    ocamlcc_bigarray_view_release(part);
    ocamlcc_bigarray_view_release(whole);
    arc_release_val(empty);
    arc_release_val(column);
    arc_release_val(parent);

    dims = arc_alloc_array(0, tagged(0));
    int64_t scalar = caml_ba_create(tagged(OCAMLCC_BA_COMPLEX64), tagged(OCAMLCC_BA_C_LAYOUT),
                                    (int64_t)(uintptr_t)dims);
    arc_release(dims);
    OcamlccBigarrayView *point = ocamlcc_bigarray_view_acquire(scalar);
    assert(point);
    OcamlccBigarrayInfo info = ocamlcc_bigarray_view_info(point);
    assert(info.rank == 0 && info.byte_length == 2 * sizeof(double));
    ocamlcc_bigarray_view_release(point);
    arc_release_val(scalar);

    int64_t boxed = ocamlcc_alloc_custom(ARC_CUSTOM_INT64, 42);
    assert(ocamlcc_bigarray_view_acquire(boxed) == NULL);
    assert(ocamlcc_bigarray_view_acquire(tagged(0)) == NULL);
    assert(ocamlcc_bigarray_view_retain(NULL) == NULL);
    ocamlcc_bigarray_view_release(NULL);
    assert(ocamlcc_get_exn() == 0);
    arc_release_val(boxed);
    assert(arc_live_objects() == before);
}

static void count_release(void *base, void *context)
{
    assert(base != NULL);
    assert(!ocamlcc_get_exn());
    int entered = arc_mutator_enter();
    assert(entered); /* A release callback can reenter from outside the gate. */
    arc_mutator_leave(entered);
    (*(int *)context)++;
}

static void release_with_exception(void *base, void *context)
{
    count_release(base, context);
    /* A native callback used a runtime primitive that left its own exception. */
    ocamlcc_set_exn((int64_t)(uintptr_t)arc_alloc_bytes(5));
}

static void test_import_contract(void)
{
    int64_t before = arc_live_objects();
    int released = 0;
    double storage[2];
    int64_t dims[] = {1, 2};
    OcamlccBigarrayInfo src = {storage, sizeof(storage), dims, 2, OCAMLCC_BA_FLOAT64, OCAMLCC_BA_FORTRAN_LAYOUT};
    OcamlccBigarrayInfo bad[] = {
        src, src, src, src, src, src, src, src
    };
    bad[0].rank = -1;
    bad[1].rank = 17;
    bad[2].dims = NULL;
    bad[3].byte_length--;
    bad[4].data = (char *)storage + 1;
    bad[5].kind = -1;
    bad[6].layout = 2;
    bad[7].data = NULL;
    int64_t saved_exn = (int64_t)(uintptr_t)arc_alloc_bytes(3);
    ocamlcc_set_exn(saved_exn);
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++)
        assert(!ocamlcc_bigarray_view_import(&bad[i], count_release, &released));
    assert(!ocamlcc_bigarray_view_import(NULL, count_release, &released));
    assert(!ocamlcc_bigarray_view_import(&src, NULL, &released));
    dims[0] = -1;
    assert(!ocamlcc_bigarray_view_import(&src, count_release, &released));
    dims[0] = INT64_MAX / 2;
    assert(!ocamlcc_bigarray_view_import(&src, count_release, &released));
    assert(!released && ocamlcc_get_exn() == saved_exn);

    dims[0] = 0;
    src.byte_length = 0;
    OcamlccBigarrayView *empty = ocamlcc_bigarray_view_import(&src, count_release, &released);
    assert(empty && ocamlcc_bigarray_view_info(empty).byte_length == 0);
    ocamlcc_bigarray_view_release(empty);
    assert(released == 1 && ocamlcc_get_exn() == saved_exn);
    src.rank = 0;
    src.dims = NULL;
    src.byte_length = sizeof(storage);
    OcamlccBigarrayView *scalar = ocamlcc_bigarray_view_import(&src, release_with_exception, &released);
    assert(scalar && ocamlcc_bigarray_view_info(scalar).byte_length == sizeof(double));
    ocamlcc_bigarray_view_release(scalar);
    assert(released == 2 && ocamlcc_get_exn() == saved_exn);
    clear_exception();
    assert(arc_live_objects() == before);
}

static int64_t dummy_closure_code(int64_t clos, int64_t a, int64_t b)
{
    (void)clos;
    return a + b;
}

static void test_weak_get_copy_and_obj_dup(void)
{
    int64_t before = arc_live_objects();
    int64_t w = ocamlcc_weak_create(tagged(8));
    int64_t *some = arc_alloc(0, 1, 8);

    /* 1. String (non-8-byte length). */
    char *str = arc_alloc_bytes(5);
    memcpy(str, "hello", 5);
    some[0] = (int64_t)(uintptr_t)str;
    ocamlcc_weak_set(w, tagged(0), (int64_t)(uintptr_t)some);
    int64_t cp_opt = ocamlcc_weak_get_copy(w, tagged(0));
    assert(cp_opt != 1);
    int64_t cp_str = ((int64_t *)(uintptr_t)cp_opt)[0];
    const ArcHeader *sh = (const ArcHeader *)(uintptr_t)cp_str - 1;
    assert(sh->tag == ARC_TAG_STRING && sh->reserved == 5);
    assert(memcmp((const void *)(uintptr_t)cp_str, "hello", 5) == 0);
    arc_release_val(cp_opt);

    /* 2. Closure with .text code pointer, arity=2, and heap env[0]. */
    ArcClosure *clos = arc_alloc(ARC_TAG_CLOSURE, 1, sizeof(ArcClosure) + 8);
    clos->code = (void *)dummy_closure_code;
    clos->arity = 2;
    arc_retain(str);
    clos->env[0] = (uint64_t)(uintptr_t)str;
    some[0] = (int64_t)(uintptr_t)clos;
    arc_release(str); /* some[0] still holds clos which holds str */
    ocamlcc_weak_set(w, tagged(1), (int64_t)(uintptr_t)some);

    cp_opt = ocamlcc_weak_get_copy(w, tagged(1));
    assert(cp_opt != 1);
    arc_release_val(cp_opt);

    int64_t dup_clos = caml_obj_dup((int64_t)(uintptr_t)clos);
    assert(dup_clos != (int64_t)(uintptr_t)clos);
    arc_release_val(dup_clos);

    /* 3. PAP with orig closure, total_arity=2, n_applied=1, and heap args[0]. */
    ArcPap *pap = arc_alloc(ARC_TAG_PAP, 0, sizeof(ArcPap) + 8);
    arc_retain(clos);
    pap->orig = clos;
    pap->total_arity = 2;
    pap->n_applied = 1;
    char *arg0 = arc_alloc_bytes(3);
    memcpy(arg0, "arg", 3);
    pap->args[0] = (int64_t)(uintptr_t)arg0;
    some[0] = (int64_t)(uintptr_t)pap;
    ocamlcc_weak_set(w, tagged(2), (int64_t)(uintptr_t)some);

    cp_opt = ocamlcc_weak_get_copy(w, tagged(2));
    assert(cp_opt != 1);
    arc_release_val(cp_opt);

    int64_t dup_pap = caml_obj_dup((int64_t)(uintptr_t)pap);
    assert(dup_pap != (int64_t)(uintptr_t)pap);
    arc_release_val(dup_pap);
    arc_release(pap);
    arc_release(clos);

    /* 4. Array from caml_array_sub (scan_fields == 0) holding heap strings. */
    char *elem = arc_alloc_bytes(4);
    memcpy(elem, "elem", 4);
    int64_t *arr = arc_alloc_array(2, (int64_t)(uintptr_t)elem);
    arc_release(elem);
    int64_t sub = caml_array_sub((int64_t)(uintptr_t)arr, tagged(0), tagged(2));
    arc_release(arr);
    some[0] = sub;
    ocamlcc_weak_set(w, tagged(3), (int64_t)(uintptr_t)some);
    cp_opt = ocamlcc_weak_get_copy(w, tagged(3));
    assert(cp_opt != 1);
    arc_release_val(cp_opt);
    arc_release_val(sub);

    /* 5. Weak array inside weak array / Obj.dup on weak array. */
    int64_t inner_w = ocamlcc_weak_create(tagged(2));
    some[0] = inner_w;
    ocamlcc_weak_set(w, tagged(4), (int64_t)(uintptr_t)some);
    cp_opt = ocamlcc_weak_get_copy(w, tagged(4));
    assert(cp_opt != 1);
    arc_release_val(cp_opt);
    int64_t dup_w = caml_obj_dup(inner_w);
    arc_release_val(dup_w);
    arc_release_val(inner_w);

    /* 6. Custom blocks: Bigarray and boxed int64. */
    int64_t *dims = arc_alloc_array(1, tagged(4));
    int64_t ba = caml_ba_create(tagged(OCAMLCC_BA_INT), tagged(OCAMLCC_BA_C_LAYOUT),
                                (int64_t)(uintptr_t)dims);
    arc_release(dims);
    int64_t dup_ba = caml_obj_dup(ba);
    arc_release_val(dup_ba);
    arc_release_val(ba);

    int64_t i64 = ocamlcc_alloc_custom(ARC_CUSTOM_INT64, 123456789ULL);
    int64_t dup_i64 = caml_obj_dup(i64);
    const ArcHeader *i64h = (const ArcHeader *)(uintptr_t)dup_i64 - 1;
    assert(i64h->tag == ARC_TAG_CUSTOM && i64h->reserved == ARC_CUSTOM_INT64);
    arc_release_val(dup_i64);
    arc_release_val(i64);

    arc_release(some);
    arc_release_val(w);
    assert(arc_live_objects() == before);
}

static void test_poller_multi_waiters_and_overflow(void)
{
    int pfd = pal_poller_create();
    assert(pfd >= 0);

    int fds[2];
    assert(pipe(fds) == 0);
    assert(write(fds[1], "x", 1) == 1);

    /* Two watchers on the same (fd, PAL_POLL_READ) must both be delivered. */
    assert(pal_poller_watch(pfd, fds[0], PAL_POLL_READ, (void *)0x101) == 0);
    assert(pal_poller_watch(pfd, fds[0], PAL_POLL_READ, (void *)0x102) == 0);

    PalPollEvent evs[2];
    int n = pal_poller_wait(pfd, evs, 1, 100);
    assert(n == 1 && evs[0].fd == fds[0] && evs[0].events == PAL_POLL_READ);
    assert(evs[0].udata == (void *)0x101);

    n = pal_poller_wait(pfd, evs, 1, 100);
    assert(n == 1 && evs[0].fd == fds[0] && evs[0].events == PAL_POLL_READ);
    assert(evs[0].udata == (void *)0x102);

    close(fds[0]);
    close(fds[1]);

    /* Both READ and WRITE ready on the same fd with max_events == 1 must not
     * overflow out[1] and must deliver both events across two waits. */
    int sp[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sp) == 0);
    assert(write(sp[1], "y", 1) == 1);
    assert(pal_poller_watch(pfd, sp[0], PAL_POLL_READ, (void *)0x201) == 0);
    assert(pal_poller_watch(pfd, sp[0], PAL_POLL_WRITE, (void *)0x202) == 0);

    memset(evs, 0xAA, sizeof(evs));
    n = pal_poller_wait(pfd, evs, 1, 100);
    assert(n == 1);
    /* Guard slot evs[1] must remain untouched. */
    unsigned char *guard = (unsigned char *)&evs[1];
    for (size_t i = 0; i < sizeof(evs[1]); i++)
        assert(guard[i] == 0xAA);
    void *first_udata = evs[0].udata;
    assert(first_udata == (void *)0x201 || first_udata == (void *)0x202);

    n = pal_poller_wait(pfd, evs, 1, 100);
    assert(n == 1);
    assert(evs[0].udata != first_udata);
    assert(evs[0].udata == (void *)0x201 || evs[0].udata == (void *)0x202);

    close(sp[0]);
    close(sp[1]);
    pal_poller_close(pfd);
}

static void test_bounds_and_marshal_dos(void)
{
    int64_t before = arc_live_objects();
    char *buf = arc_alloc_bytes(8);
    memset(buf, 'A', 8);

    /* 1. Marshal.to_buffer bounds: negative offset, negative length, and overflow. */
    caml_output_value_to_buffer((int64_t)(uintptr_t)buf, tagged(-1), tagged(4), tagged(42), 1);
    clear_exception();
    caml_output_value_to_buffer((int64_t)(uintptr_t)buf, tagged(0), tagged(-1), tagged(42), 1);
    clear_exception();
    caml_output_value_to_buffer((int64_t)(uintptr_t)buf, tagged(6), tagged(4), tagged(42), 1);
    clear_exception();

    /* 2. caml_array_blit and caml_array_fill bounds. */
    int64_t *a1 = arc_alloc_array(3, tagged(1));
    int64_t *a2 = arc_alloc_array(3, tagged(2));
    caml_array_blit((int64_t)(uintptr_t)a1, tagged(-1), (int64_t)(uintptr_t)a2, tagged(0), tagged(1));
    clear_exception();
    caml_array_blit((int64_t)(uintptr_t)a1, tagged(2), (int64_t)(uintptr_t)a2, tagged(0), tagged(2));
    clear_exception();
    caml_array_blit((int64_t)(uintptr_t)a1, tagged(0), (int64_t)(uintptr_t)a2, tagged(2), tagged(2));
    clear_exception();
    caml_array_fill((int64_t)(uintptr_t)a1, tagged(-1), tagged(1), tagged(9));
    clear_exception();
    caml_array_fill((int64_t)(uintptr_t)a1, tagged(2), tagged(2), tagged(9));
    clear_exception();
    arc_release(a1);
    arc_release(a2);

    /* 3. caml_ml_output_bytes and caml_ml_input bounds. */
    int fds[2];
    assert(pipe(fds) == 0);
    int64_t ch_in = caml_ml_open_descriptor_in(tagged(fds[0]));
    int64_t ch_out = caml_ml_open_descriptor_out(tagged(fds[1]));

    caml_ml_output_bytes(ch_out, (int64_t)(uintptr_t)buf, tagged(-1), tagged(2));
    clear_exception();
    caml_ml_output_bytes(ch_out, (int64_t)(uintptr_t)buf, tagged(6), tagged(4));
    clear_exception();
    caml_ml_input(ch_in, (int64_t)(uintptr_t)buf, tagged(-1), tagged(2));
    clear_exception();
    caml_ml_input(ch_in, (int64_t)(uintptr_t)buf, tagged(6), tagged(4));
    clear_exception();

    /* 4. caml_input_value with a 4 GB header on a truncated pipe must not OOM/abort. */
    uint8_t huge_hdr[20] = {
        0x84, 0x95, 0xa6, 0xbe, /* magic */
        0xff, 0xff, 0xff, 0x00, /* length ~= 4 GB */
        0x00, 0x00, 0x00, 0x01, /* objects */
        0x00, 0x00, 0x00, 0x01, /* words32 */
        0x00, 0x00, 0x00, 0x01  /* words64 */
    };
    assert(write(fds[1], huge_hdr, sizeof(huge_hdr)) == (ssize_t)sizeof(huge_hdr));
    caml_ml_close_channel(ch_out);
    arc_release_val(ch_out);

    caml_input_value(ch_in);
    clear_exception();
    caml_ml_close_channel(ch_in);
    arc_release_val(ch_in);

    /* 5. m_read_bigarray failure must not leak caml_ba_create's exception. */
    uint8_t bad_ba[] = {
        0x84, 0x95, 0xa6, 0xbe,
        0x00, 0x00, 0x00, 0x18, /* length = 24 */
        0x00, 0x00, 0x00, 0x01, /* objects = 1 */
        0x00, 0x00, 0x00, 0x01, /* words32 = 1 */
        0x00, 0x00, 0x00, 0x01, /* words64 = 1 */
        0x12,                   /* CODE_CUSTOM */
        '_', 'b', 'i', 'g', 'a', 'r', 'r', 'a', 'y', '\0',
        0x00, 0x00, 0x00, 0x01, /* ndims = 1 */
        0x00, 0x00, 0x00, 0x63, /* invalid kind = 99 (triggers caml_ba_create error if reached, or kind=0 + bad flags) */
        0x00, 0x00, 0x00, 0x00  /* dim[0] = 0 */
    };
    /* Note: kind=0, layout=0x200 (invalid layout=2 -> triggers caml_ba_create exn) */
    bad_ba[37] = 0x02;
    bad_ba[38] = 0x00;
    char *ba_bytes = arc_alloc_bytes(sizeof(bad_ba));
    memcpy(ba_bytes, bad_ba, sizeof(bad_ba));
    caml_input_value_from_bytes((int64_t)(uintptr_t)ba_bytes, tagged(0));
    clear_exception();
    arc_release(ba_bytes);

    arc_release(buf);
    assert(arc_live_objects() == before);
}

static int64_t noop_fiber_fn(int64_t clos, int64_t arg)
{
    (void)clos;
    return arg;
}

static void test_fiber_robustness(void)
{
    int64_t before = arc_live_objects();

    /* 1. Resuming a FIBER_DONE fiber must raise Invalid_argument, not abort. */
    ArcClosure *clos = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    clos->code = (void *)noop_fiber_fn;
    clos->arity = 1;
    int64_t fib = ocamlcc_fiber_create((int64_t)(uintptr_t)clos);
    arc_release(clos);

    const Fiber *fobj = (const Fiber *)(uintptr_t)fib;
    assert(fobj->c_stack_bytes > 256u * 1024u); /* includes guard page */

    int64_t r1 = ocamlcc_fiber_resume(fib, tagged(7));
    assert(!ocamlcc_get_exn() && r1 == tagged(7));
    ocamlcc_fiber_resume(fib, tagged(8));
    clear_exception();
    arc_release_val(fib);

    /* 2. Passing an invalid fd to fiber_fd_wait must raise, not abort. */
    ocamlcc_fiber_fd_wait_read(tagged(-1));
    clear_exception();

    /* 3. Invoking a closure with > 16 parameters must raise and not leak args. */
    ArcClosure *big_clos = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    big_clos->code = (void *)noop_fiber_fn;
    big_clos->arity = 17;
    int64_t args[17];
    for (int i = 0; i < 17; i++)
        args[i] = (int64_t)(uintptr_t)arc_alloc_bytes(2);
    ocamlcc_apply_n((int64_t)(uintptr_t)big_clos, 17, args);
    clear_exception();
    arc_release(big_clos);

    /* 4. Self-await on current fiber must not deadlock. */
    ocamlcc_fiber_await((int64_t)(uintptr_t)arc_fiber_current());
    clear_exception();

    assert(arc_live_objects() == before);
}

static int g_fin2_ran = 0;

static int64_t fin_raise_fn(int64_t clos, int64_t unit)
{
    (void)clos;
    (void)unit;
    ocamlcc_fiber_raise_invalid();
    return 1;
}

static int64_t fin_count_fn(int64_t clos, int64_t unit)
{
    (void)clos;
    (void)unit;
    g_fin2_ran++;
    return 1;
}

static void test_runtime_3_3(void)
{
    int64_t before = arc_live_objects();

    /* 1. val_compare_raw follows ARC_TAG_FORWARD and rejects Mutex custom blocks. */
    int64_t fwd = caml_lazy_make_forward(tagged(42));
    assert(caml_compare(fwd, tagged(42)) == tagged(0));
    assert(!ocamlcc_get_exn());
    arc_release_val(fwd);

    int64_t m1 = caml_ml_mutex_new(1);
    int64_t m2 = caml_ml_mutex_new(1);
    caml_compare(m1, m2);
    clear_exception();
    arc_release_val(m1);
    arc_release_val(m2);

    /* 2. ocamlcc_bigarray_view_info(NULL) must not dereference NULL. */
    OcamlccBigarrayInfo null_info = ocamlcc_bigarray_view_info(NULL);
    assert(null_info.data == NULL && null_info.byte_length == 0);

    /* 3. caml_md5_chan streaming (> 8 KB) matches caml_md5_bytes. */
    size_t sz = 10000;
    char *data = arc_alloc_bytes(sz);
    memset(data, 'a', sz);
    int64_t expected_md5 = caml_md5_bytes((int64_t)(uintptr_t)data, tagged(0), tagged((int64_t)sz));

    int fds[2];
    assert(pipe(fds) == 0);
    assert(write(fds[1], data, sz) == (ssize_t)sz);
    close(fds[1]);
    int64_t ch_in = caml_ml_open_descriptor_in(tagged(fds[0]));
    int64_t stream_md5 = caml_md5_chan(ch_in, tagged(-1));
    assert(!ocamlcc_get_exn());
    assert(memcmp((const void *)(uintptr_t)stream_md5,
                  (const void *)(uintptr_t)expected_md5, 16) == 0);
    caml_ml_close_channel(ch_in);
    arc_release_val(ch_in);
    arc_release_val(stream_md5);
    arc_release_val(expected_md5);
    arc_release(data);

    /* 4. Stranded pending finalizers after an exception must stay DISPATCH_READY. */
    g_fin2_ran = 0;
    int64_t *t1 = arc_alloc(0, 0, 8);
    int64_t *t2 = arc_alloc(0, 0, 8);
    ArcClosure *c1 = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    c1->code = (void *)fin_raise_fn;
    c1->arity = 1;
    ArcClosure *c2 = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    c2->code = (void *)fin_count_fn;
    c2->arity = 1;
    caml_final_register_called_without_value((int64_t)(uintptr_t)c2, (int64_t)(uintptr_t)t2);
    caml_final_register_called_without_value((int64_t)(uintptr_t)c1, (int64_t)(uintptr_t)t1);
    arc_release(c1);
    arc_release(c2);
    arc_release(t1);
    arc_release(t2);
    caml_gc_full_major(1);
    if (ocamlcc_get_exn())
        clear_exception();
    ocamlcc_poll_finalizers();
    if (ocamlcc_get_exn())
        clear_exception();
    assert(g_fin2_ran == 1);

    assert(arc_live_objects() == before);
}

static int g_fin_probe_failures = 0;

static void expect_invalid(const char *what)
{
    if (ocamlcc_get_exn() == 0) {
        fprintf(stderr, "finalizer %s did not raise Invalid_argument\n", what);
        g_fin_probe_failures++;
    } else
        clear_exception();
}

/* A finalizer callback: poll_finalizers marked yields = false means the
 * dispatcher fiber has no shadow-stack window, so every suspension entry
 * point must refuse (Invalid_argument) while owns_finalizer_dispatch is
 * set instead of stranding the fiber mid-dispatch. */
static int64_t fin_suspend_probe_fn(int64_t clos, int64_t unit)
{
    (void)clos;
    (void)unit;
    ocamlcc_fiber_yield(1);
    expect_invalid("yield");
    ocamlcc_fiber_suspend(1);
    expect_invalid("suspend");
    ocamlcc_fiber_sleep_ms(tagged(5));
    expect_invalid("sleep_ms");
    ocamlcc_fiber_fd_wait_read(tagged(0));
    expect_invalid("fd_wait_read");
    ArcClosure *noop = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    noop->code = (void *)noop_fiber_fn;
    noop->arity = 1;
    int64_t done_fib = ocamlcc_fiber_create((int64_t)(uintptr_t)noop);
    arc_release(noop);
    ocamlcc_fiber_resume(done_fib, tagged(0));
    if (ocamlcc_get_exn())
        clear_exception();
    ocamlcc_fiber_await(done_fib);
    expect_invalid("await");
    arc_release_val(done_fib);
    return 1;
}

static int64_t fin_poll_body_fn(int64_t clos, int64_t arg)
{
    (void)clos;
    /* Push allocation progress past the finalizer budget (g_gc_ctrl[0]) so
       the pending finalizer is dispatched inside this fiber. */
    int guard = 0;
    while (ocamlcc_finalizers_due() != 3 && guard++ < 4096) {
        int64_t *bump = arc_alloc_array(4096, 1);
        arc_release(bump);
    }
    ocamlcc_poll_finalizers();
    if (ocamlcc_get_exn())
        clear_exception();
    return arg;
}

static void test_finalizer_no_suspend(void)
{
    int64_t before = arc_live_objects();
    g_fin_probe_failures = 0;

    int64_t *target = arc_alloc(0, 0, 8);
    ArcClosure *cb = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    cb->code = (void *)fin_suspend_probe_fn;
    cb->arity = 1;
    caml_final_register_called_without_value((int64_t)(uintptr_t)cb,
                                             (int64_t)(uintptr_t)target);
    arc_release(cb);
    arc_release(target);

    /* Dispatch the finalizer inside a spawned fiber: poll_finalizers is
       marked yields = false, so the fiber must survive the callback. */
    ArcClosure *body = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    body->code = (void *)fin_poll_body_fn;
    body->arity = 1;
    int64_t fib = ocamlcc_fiber_create((int64_t)(uintptr_t)body);
    arc_release(body);
    int64_t r = tagged(0);
    for (int i = 0; i < 8 && ((const Fiber *)(uintptr_t)fib)->state != FIBER_DONE;
         i++)
        r = ocamlcc_fiber_resume(fib, tagged(0));
    assert(!ocamlcc_get_exn());
    assert(((const Fiber *)(uintptr_t)fib)->state == FIBER_DONE);
    assert(r == tagged(0));
    assert(g_fin_probe_failures == 0);
    arc_release_val(fib);

    /* Drain leftover dispatch state on the main fiber. */
    ocamlcc_poll_finalizers();
    if (ocamlcc_get_exn())
        clear_exception();
    ocamlcc_arc_collect(1);
    assert(arc_live_objects() == before);
}

static int64_t g_test_rfd = 0;

static int64_t fd_wait_body_fn(int64_t clos, int64_t arg)
{
    (void)clos;
    (void)arg;
    ocamlcc_fiber_fd_wait_read(tagged(g_test_rfd));
    return 1;
}

static int64_t g_await_target = 0;

static int64_t await_body_fn(int64_t clos, int64_t arg)
{
    (void)clos;
    (void)arg;
    ocamlcc_fiber_await(g_await_target);
    return 1;
}

static void run_one_ready_fiber(void)
{
    /* Run exactly one queued fiber until it parks or completes. */
    ocamlcc_fiber_yield(1);
}

static void test_destroy_waiter_cleanup(void)
{
    int64_t before = arc_live_objects();
    int fds[2];
    assert(pipe(fds) == 0);
    g_test_rfd = (int64_t)fds[0];

    /* fB parks on the pipe fd. */
    ArcClosure *bodB = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    bodB->code = (void *)fd_wait_body_fn;
    bodB->arity = 1;
    int64_t fB = ocamlcc_fiber_spawn((int64_t)(uintptr_t)bodB);
    arc_release(bodB);
    run_one_ready_fiber();
    const Fiber *fbobj = (const Fiber *)(uintptr_t)fB;
    assert(fbobj->state == FIBER_WAITING_IO);

    /* fA awaits fB: it sits on fB->waiter_head. */
    g_await_target = fB;
    ArcClosure *bodA = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    bodA->code = (void *)await_body_fn;
    bodA->arity = 1;
    int64_t fA = ocamlcc_fiber_spawn((int64_t)(uintptr_t)bodA);
    arc_release(bodA);
    run_one_ready_fiber();
    const Fiber *faobj = (const Fiber *)(uintptr_t)fA;
    assert(faobj->state == FIBER_WAITING_IO);
    assert(fbobj->waiter_head == (Fiber *)(uintptr_t)fA);

    /* Collector-style teardown of the abandoned awaiter: it must be
       unlinked from fB's waiter list, or fB's later completion wakes a
       freed fiber. */
    fiber_destroy((Fiber *)(uintptr_t)fA);
    assert(fbobj->waiter_head == NULL);

    /* fB still completes and wakes on data; the destroyed awaiter must not
       be touched. */
    assert(write(fds[1], "x", 1) == 1);
    run_one_ready_fiber();
    assert(((const Fiber *)(uintptr_t)fB)->state == FIBER_DONE);

    /* The scheduler's spawn pin for the manually destroyed fA is settled by
       hand (fiber_destroy stood in for the completion path). */
    arc_release((Fiber *)(uintptr_t)fA);
    arc_release_val(fB);
    arc_release_val(fA);
    close(fds[0]);
    close(fds[1]);
    ocamlcc_arc_collect(1);
    assert(arc_live_objects() == before);
}

static void test_poller_unwatch_waiter(void)
{
    int pfd = pal_poller_create();
    assert(pfd >= 0);
    int fds[2];
    assert(pipe(fds) == 0);
    int x = 1;
    int y = 2;

    /* Two waiters on the same (fd, READ): removing one must leave the other
       registered (pal_poller_unwatch would clear both). */
    assert(pal_poller_watch(pfd, fds[0], PAL_POLL_READ, &x) == 0);
    assert(pal_poller_watch(pfd, fds[0], PAL_POLL_READ, &y) == 0);
    assert(pal_poller_unwatch_waiter(pfd, fds[0], PAL_POLL_READ, &x) == 0);
    assert(pal_poller_unwatch_waiter(pfd, fds[0], PAL_POLL_READ, &x) == -1);
    assert(write(fds[1], "a", 1) == 1);
    PalPollEvent evs[8];
    int n = pal_poller_wait(pfd, evs, 8, 100);
    assert(n == 1 && evs[0].udata == &y);

    /* A fresh single waiter: removing it unregisters the fd entirely (the
       earlier ONESHOT fire already consumed and freed the old watch). */
    int z = 3;
    assert(pal_poller_watch(pfd, fds[0], PAL_POLL_READ, &z) == 0);
    assert(pal_poller_unwatch_waiter(pfd, fds[0], PAL_POLL_READ, &z) == 0);
    assert(write(fds[1], "b", 1) == 1);
    n = pal_poller_wait(pfd, evs, 8, 10);
    assert(n == 0);
    assert(pal_poller_unwatch_waiter(pfd, fds[0], PAL_POLL_READ, &z) == -1);

    close(fds[0]);
    close(fds[1]);
    pal_poller_close(pfd);
}

static _Atomic int g_probe_ran = 0;
static _Atomic int g_probe_is_done = 0;
static pthread_key_t g_probe_key;
static int g_probe_key_ok = 0;

static void tls_probe_dtor(void *arg)
{
    (void)arg;
    /* Runs alongside fiber_tls_cleanup at thread exit: touching fiber state
     * here must never dereference freed TLS (ASan catches that ordering). */
    Fiber *cur = arc_fiber_current();
    atomic_store(&g_probe_is_done,
                 (int)(ocamlcc_fiber_is_done((int64_t)(uintptr_t)cur) >> 1));
    atomic_store(&g_probe_ran, 1);
}

static int64_t tls_exit_body_fn(int64_t clos, int64_t arg)
{
    (void)clos;
    (void)arg;
    return 1;
}

static void *tls_queued_exit_worker(void *arg)
{
    (void)arg;
    arc_fiber_current(); /* create this thread's fiber TLS */
    ArcClosure *clos = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    clos->code = (void *)tls_exit_body_fn;
    clos->arity = 1;
    /* Spawn fibers and drop our handles: the scheduler queue owns +1 each,
     * so they survive queued until the thread's TLS is cleaned up. */
    for (int i = 0; i < 3; i++) {
        int64_t fib = ocamlcc_fiber_spawn((int64_t)(uintptr_t)clos);
        arc_release_val(fib);
    }
    arc_release(clos);
    if (g_probe_key_ok)
        pthread_setspecific(g_probe_key, (void *)(uintptr_t)1);
    return NULL; /* thread exits with 3 fibers still queued */
}

static void test_tls_cleanup_queued_fibers(void)
{
    int64_t before = arc_live_objects();
    if (!g_probe_key_ok) {
        if (pthread_key_create(&g_probe_key, tls_probe_dtor) == 0)
            g_probe_key_ok = 1;
    }
    pthread_t th;
    assert(pthread_create(&th, NULL, tls_queued_exit_worker, NULL) == 0);
    pthread_join(th, NULL);

    /* The probe destructor ran alongside the fiber TLS cleanup. */
    assert(atomic_load(&g_probe_ran) == 1);
    /* Every queued fiber must have been released with its scheduler pin:
       nothing may leak past the thread's exit. */
    assert(arc_live_objects() == before);
}

static void test_reachable_words(void)
{
    int64_t before = arc_live_objects();

    /* 1. Tree: pair -> (s1, s2). */
    char *s1 = arc_alloc_bytes(4);
    char *s2 = arc_alloc_bytes(4);
    int64_t *pair = arc_alloc(0, 2, 16);
    pair[0] = (int64_t)(uintptr_t)s1;
    pair[1] = (int64_t)(uintptr_t)s2;
    assert((caml_obj_reachable_words((int64_t)(uintptr_t)pair) >> 1) == 10);

    /* 2. Diamond DAG: pair2 -> (s1, s1) counts s1 once. */
    int64_t *pair2 = arc_alloc(0, 2, 16);
    arc_retain(s1);
    arc_retain(s1);
    pair2[0] = (int64_t)(uintptr_t)s1;
    pair2[1] = (int64_t)(uintptr_t)s1;
    assert((caml_obj_reachable_words((int64_t)(uintptr_t)pair2) >> 1) == 7);

    /* 3. Cycle: c1 <-> c2 terminates and counts each once. */
    int64_t *c1 = arc_alloc(0, 1, 8);
    int64_t *c2 = arc_alloc(0, 1, 8);
    arc_retain(c2);
    c1[0] = (int64_t)(uintptr_t)c2;
    arc_retain(c1);
    c2[0] = (int64_t)(uintptr_t)c1;
    assert((caml_obj_reachable_words((int64_t)(uintptr_t)c1) >> 1) == 6);

    arc_release(pair);
    arc_release(pair2);
    arc_release(c1);
    arc_release(c2);
    assert(ocamlcc_arc_collect(1) == tagged(2));
    assert(arc_live_objects() == before);
}

static void test_bigarray_channel_io(void)
{
    int64_t before = arc_live_objects();
    int fds[2];
    assert(pipe(fds) == 0);
    int64_t ch_in = caml_ml_open_descriptor_in(tagged(fds[0]));
    int64_t ch_out = caml_ml_open_descriptor_out(tagged(fds[1]));

    /* 1. output_bigarray writes the array bytes (data has no ArcHeader). */
    int64_t *dims = arc_alloc_array(1, tagged(8));
    int64_t ba = caml_ba_create(tagged(OCAMLCC_BA_CHAR), tagged(OCAMLCC_BA_C_LAYOUT),
                                (int64_t)(uintptr_t)dims);
    arc_release(dims);
    OcamlccBigarrayView *fill = ocamlcc_bigarray_view_acquire(ba);
    assert(fill != NULL);
    OcamlccBigarrayInfo fi = ocamlcc_bigarray_view_info(fill);
    assert(fi.kind == OCAMLCC_BA_CHAR && fi.byte_length == 8);
    memcpy(fi.data, "helloBA!", 8);
    ocamlcc_bigarray_view_release(fill);

    caml_ml_output_bigarray(ch_out, ba, tagged(0), tagged(8));
    assert(!ocamlcc_get_exn());
    caml_ml_flush(ch_out);

    /* 2. A valid sub-range writes only that slice. */
    caml_ml_output_bigarray(ch_out, ba, tagged(2), tagged(3));
    assert(!ocamlcc_get_exn());
    caml_ml_flush(ch_out);

    /* 3. Out-of-range slices raise Invalid_argument, not UB. */
    caml_ml_output_bigarray(ch_out, ba, tagged(7), tagged(4));
    clear_exception();
    caml_ml_output_bigarray(ch_out, ba, tagged(-1), tagged(2));
    clear_exception();

    /* 4. input_bigarray reads back what output wrote (page-aligned data:
       no header probe at data-16). */
    int64_t *dims2 = arc_alloc_array(1, tagged(8));
    int64_t ba2 = caml_ba_create(tagged(OCAMLCC_BA_CHAR), tagged(OCAMLCC_BA_C_LAYOUT),
                                 (int64_t)(uintptr_t)dims2);
    arc_release(dims2);
    int64_t n = caml_ml_input_bigarray(ch_in, ba2, tagged(0), tagged(8));
    assert(!ocamlcc_get_exn());
    assert(n == tagged(8));
    OcamlccBigarrayView *check = ocamlcc_bigarray_view_acquire(ba2);
    assert(check != NULL);
    OcamlccBigarrayInfo ci = ocamlcc_bigarray_view_info(check);
    assert(memcmp(ci.data, "helloBA!", 8) == 0);
    ocamlcc_bigarray_view_release(check);

    /* 5. The sub-range write lands "llo". */
    int64_t n2 = caml_ml_input_bigarray(ch_in, ba2, tagged(0), tagged(8));
    assert(!ocamlcc_get_exn());
    assert(n2 == tagged(3));
    check = ocamlcc_bigarray_view_acquire(ba2);
    ci = ocamlcc_bigarray_view_info(check);
    assert(memcmp(ci.data, "llo", 3) == 0);
    ocamlcc_bigarray_view_release(check);

    /* 6. Out-of-range input slices raise Invalid_argument. */
    caml_ml_input_bigarray(ch_in, ba2, tagged(0), tagged(9));
    clear_exception();
    caml_ml_input_bigarray(ch_in, ba2, tagged(-1), tagged(2));
    clear_exception();

    caml_ml_close_channel(ch_out);
    arc_release_val(ch_out);
    caml_ml_close_channel(ch_in);
    arc_release_val(ch_in);
    arc_release_val(ba);
    arc_release_val(ba2);
    ocamlcc_arc_collect(1);
    assert(arc_live_objects() == before);
}

int main(void)
{
    test_float_format();
    test_integer_format();
    test_buffered_dummy_update();
    test_weak_get_copy_and_obj_dup();
    test_poller_multi_waiters_and_overflow();
    test_bounds_and_marshal_dos();
    test_fiber_robustness();
    test_runtime_3_3();
    test_reachable_words();
    test_partial_cycle(); test_complete_cycle(); test_truncation_and_mutation(); test_view_lifetime();
    test_retained_c_subview();
    test_c_view_shapes();
    test_import_contract();
    test_bigarray_channel_io();
    test_finalizer_no_suspend();
    test_destroy_waiter_cleanup();
    test_poller_unwatch_waiter();
    test_tls_cleanup_queued_fibers();
    puts("stdlib runtime: formats, malformed cleanup, cycles, truncation, views");
    return 0;
}
