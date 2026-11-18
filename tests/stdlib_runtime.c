/* Public C runtime contracts: malformed Marshal cleanup and ARC view lifetime. */
#include "../runtime/arc.h"
#include "../runtime/ocamlcc_bigarray.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

extern int64_t caml_input_value_from_bytes(int64_t, int64_t);
extern int64_t caml_output_value_to_bytes(int64_t, int64_t);
extern int64_t caml_ba_create(int64_t, int64_t, int64_t);
extern int64_t caml_ba_sub(int64_t, int64_t, int64_t);
extern int64_t caml_ba_set_1(int64_t, int64_t, int64_t);
extern int64_t caml_ba_get_1(int64_t, int64_t);

static int64_t tagged(int64_t n) { return (int64_t)(((uint64_t)n << 1) | 1); }
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

int main(void)
{
    test_partial_cycle(); test_complete_cycle(); test_truncation_and_mutation(); test_view_lifetime();
    test_retained_c_subview();
    test_c_view_shapes();
    test_import_contract();
    puts("stdlib runtime: malformed cleanup, cycles, truncation, views");
    return 0;
}
