/* Public C runtime contracts for standard library primitives and ARC views. */
#include "../runtime/arc.h"
#include "../runtime/ocamlcc_bigarray.h"
#include "../runtime/pal.h"
#include <assert.h>
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

int main(void)
{
    test_float_format();
    test_integer_format();
    test_buffered_dummy_update();
    test_weak_get_copy_and_obj_dup();
    test_poller_multi_waiters_and_overflow();
    test_bounds_and_marshal_dos();
    test_partial_cycle(); test_complete_cycle(); test_truncation_and_mutation(); test_view_lifetime();
    test_retained_c_subview();
    test_c_view_shapes();
    test_import_contract();
    puts("stdlib runtime: formats, malformed cleanup, cycles, truncation, views");
    return 0;
}
