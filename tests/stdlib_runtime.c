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

extern int64_t caml_ba_create(int64_t, int64_t, int64_t);
extern int64_t caml_ba_sub(int64_t, int64_t, int64_t);
extern int64_t caml_ba_set_1(int64_t, int64_t, int64_t);
extern int64_t caml_ba_get_1(int64_t, int64_t);
extern int64_t caml_obj_dup(int64_t);
extern int64_t caml_obj_set_field(int64_t, int64_t, int64_t);
extern int64_t caml_obj_with_tag(int64_t, int64_t);
extern int64_t ocamlcc_raw_fd_read(int64_t, int64_t, int64_t, int64_t);
extern int64_t ocamlcc_raw_fd_write(int64_t, int64_t, int64_t, int64_t);
extern int64_t ocamlcc_raw_fd_close(int64_t);
extern int64_t ocamlcc_ba_to_bytes(int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t ocamlcc_ba_of_bytes_slice(int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t ocamlcc_fiber_create(int64_t);
extern int64_t ocamlcc_fiber_resume(int64_t, int64_t);
extern int64_t ocamlcc_fiber_suspend(int64_t);
extern int64_t ocamlcc_fiber_is_done(int64_t);
extern int64_t ocamlcc_fiber_can_yield(int64_t);
extern int64_t ocamlcc_fiber_sched_set(int64_t);
extern int64_t ocamlcc_poller_watch(int64_t, int64_t, int64_t);
extern int64_t caml_lazy_make_forward(int64_t);
extern int64_t caml_compare(int64_t, int64_t);
extern int64_t caml_ml_mutex_new(int64_t);
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

static void test_buffered_dummy_update(void)
{
    int64_t before = arc_live_objects();
    int64_t dummy = caml_alloc_dummy(tagged(1));
    int64_t weak = ocamlcc_weak_create(tagged(1));
    int64_t *some = arc_alloc(0, 1, sizeof(*some));
    arc_retain_val(dummy);
    *some = dummy;
    ocamlcc_weak_set(weak, tagged(0), (int64_t)(uintptr_t)some);
    arc_release(some);

    char *bytes = arc_alloc_bytes(4);
    memcpy(bytes, "text", 4);
    caml_update_dummy(dummy, (int64_t)(uintptr_t)bytes);
    assert(ocamlcc_arc_collect(1) == tagged(0));
    const ArcHeader *header = (const ArcHeader *)(uintptr_t)dummy - 1;
    assert(header->tag == ARC_TAG_STRING && header->reserved == 4);
    assert(memcmp((const void *)(uintptr_t)dummy, "text", 4) == 0);
    arc_release(bytes);
    arc_release_val(dummy);
    assert(ocamlcc_weak_check(weak, tagged(0)) == tagged(0));
    arc_release_val(weak);
    assert(arc_live_objects() == before);
}

static void clear_exception(void)
{
    int64_t ex = ocamlcc_get_exn(); assert(ex);
    ocamlcc_set_exn(0); arc_release_val(ex);
}

static void test_cycle_loses_external_owner_at_immutable_member(void)
{
    int64_t before = arc_live_objects();
    int64_t *mutable = arc_alloc(0, 1, sizeof(*mutable));
    *mutable = tagged(0);
    int64_t *immutable = arc_alloc(17, 1, sizeof(*immutable));
    *immutable = (int64_t)(uintptr_t)mutable; /* transfer the initial owner */
    caml_obj_set_field((int64_t)(uintptr_t)mutable, tagged(0),
                       (int64_t)(uintptr_t)immutable);

    /* Let the first trial clear the buffered root at the mutable member.
     * The external owner of the immutable member keeps the cycle reachable. */
    arc_retain(mutable);
    arc_release(mutable);
    assert(ocamlcc_arc_collect(1) == tagged(0));
    arc_release(immutable);
    assert(ocamlcc_arc_collect(1) == tagged(2));
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

static void test_weak_target_header_and_reuse(void)
{
    int64_t live_before = arc_live_objects();
    int64_t weak = ocamlcc_weak_create(tagged(1));
    int64_t *child = arc_alloc(0, 0, sizeof(*child));
    *child = tagged(17);
    int64_t *target = arc_alloc(0, 1, sizeof(*target));
    *target = (int64_t)(uintptr_t)child;
    ArcHeader *hdr = (ArcHeader *)target - 1;
    int64_t val = (int64_t)(uintptr_t)target;
    assert(hdr->scan_fields == 1);

    int64_t *some = arc_alloc(0, 1, sizeof(*some));
    arc_retain(target);
    *some = val;
    ocamlcc_weak_set(weak, tagged(0), (int64_t)(uintptr_t)some);
    arc_release(some);
    assert((hdr->scan_fields & ARC_FLAG_WEAK_TARGET) != 0);
    assert(ocamlcc_weak_check(weak, tagged(0)) == tagged(1));

    int64_t snapshot = caml_obj_dup(val);
    assert((((ArcHeader *)(uintptr_t)snapshot - 1)->scan_fields & ARC_FLAG_WEAK_TARGET) == 0);
    arc_release_val(snapshot);
    void *token = arc_drop_reuse(val);
    assert(token == hdr);
    assert(ocamlcc_weak_check(weak, tagged(0)) == tagged(0));

    int64_t *replacement = arc_alloc_reuse(token, 0, 1, sizeof(*replacement));
    assert(replacement == target);
    assert(hdr->scan_fields == 1);
    *replacement = tagged(8);
    arc_release(replacement);

    /* A scan count using the high bit keeps its original meaning. */
    int64_t *large = arc_alloc_array(ARC_FLAG_WEAK_TARGET, tagged(0));
    ArcHeader *large_hdr = (ArcHeader *)large - 1;
    assert(arc_scan_count(large_hdr) == ARC_FLAG_WEAK_TARGET);
    some = arc_alloc(0, 1, sizeof(*some));
    arc_retain(large);
    *some = (int64_t)(uintptr_t)large;
    ocamlcc_weak_set(weak, tagged(0), (int64_t)(uintptr_t)some);
    arc_release(some);
    assert(arc_scan_count(large_hdr) == ARC_FLAG_WEAK_TARGET);
    arc_release(large);
    assert(ocamlcc_weak_check(weak, tagged(0)) == tagged(0));

    arc_release_val(weak);
    assert(arc_live_objects() == live_before);
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

    /* 4. Array with scan_fields == 0 holding heap strings. */
    char *elem = arc_alloc_bytes(4);
    memcpy(elem, "elem", 4);
    int64_t *sub_arr = (int64_t *)arc_alloc((uint16_t)ARC_TAG_ARRAY, 0u, 16u);
    sub_arr[0] = (int64_t)(uintptr_t)elem;
    sub_arr[1] = (int64_t)(uintptr_t)elem;
    arc_retain_val((int64_t)(uintptr_t)elem);
    arc_retain_val((int64_t)(uintptr_t)elem);
    arc_release(elem);
    int64_t sub = (int64_t)(uintptr_t)sub_arr;
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

    /* ocamlcc_raw_fd_write and ocamlcc_raw_fd_read bounds. */
    int fds[2];
    assert(pipe(fds) == 0);

    ocamlcc_raw_fd_write(tagged(fds[1]), (int64_t)(uintptr_t)buf, tagged(-1), tagged(2));
    clear_exception();
    ocamlcc_raw_fd_write(tagged(fds[1]), (int64_t)(uintptr_t)buf, tagged(6), tagged(4));
    clear_exception();
    ocamlcc_raw_fd_read(tagged(fds[0]), (int64_t)(uintptr_t)buf, tagged(-1), tagged(2));
    clear_exception();
    ocamlcc_raw_fd_read(tagged(fds[0]), (int64_t)(uintptr_t)buf, tagged(6), tagged(4));
    clear_exception();

    ocamlcc_raw_fd_close(tagged(fds[1]));
    ocamlcc_raw_fd_close(tagged(fds[0]));

    arc_release(buf);
    assert(arc_live_objects() == before);
}

static int64_t noop_fiber_fn(int64_t clos, int64_t arg)
{
    (void)clos;
    return arg;
}

static int64_t yield_from_effect_stack(int64_t clos, int64_t arg)
{
    (void)clos;
    assert(ocamlcc_fiber_is_main(1) == 1);
    return ocamlcc_fiber_suspend(arg);
}

static int64_t wren_with_effect_stack(int64_t closure, int64_t arg)
{
    const ArcClosure *c = (const ArcClosure *)(uintptr_t)closure;
    int64_t handler = (int64_t)c->env[1];
    int64_t stack = caml_alloc_stack(handler, handler, handler);
    arc_fiber_push(stack);
    int64_t result = ocamlcc_effect_runstack(stack, (int64_t)c->env[0], arg);
    arc_fiber_pop(1);
    arc_release_val(stack);
    return result;
}

static void test_wren_suspend_through_effect_stack(void)
{
    int64_t before = arc_live_objects();
    ArcClosure *yield = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    yield->code = (void *)yield_from_effect_stack;
    yield->arity = 1;
    ArcClosure *ret = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    ret->code = (void *)noop_fiber_fn;
    ret->arity = 1;
    ArcClosure *outer = arc_alloc(ARC_TAG_CLOSURE, 2,
                                  sizeof(ArcClosure) + 2 * sizeof(int64_t));
    outer->code = (void *)wren_with_effect_stack;
    outer->arity = 1;
    outer->env[0] = (uintptr_t)yield;
    outer->env[1] = (uintptr_t)ret;

    int64_t fiber = ocamlcc_fiber_create((int64_t)(uintptr_t)outer);
    assert(ocamlcc_fiber_resume(fiber, tagged(10)) == tagged(10));
    assert(ocamlcc_fiber_is_done(fiber) == 1);
    assert(ocamlcc_fiber_resume(fiber, tagged(20)) == tagged(20));
    assert(ocamlcc_fiber_is_done(fiber) == 3);
    arc_release_val(fiber);

    fiber = ocamlcc_fiber_create((int64_t)(uintptr_t)outer);
    assert(ocamlcc_fiber_resume(fiber, tagged(30)) == tagged(30));
    arc_release_val(fiber); /* abandons both the Wren and effect stacks */
    arc_release(outer);
    assert(!ocamlcc_get_exn() && arc_live_objects() == before);
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

    /* 2. Passing an invalid fd to poller_watch must raise, not abort. */
    ocamlcc_poller_watch(tagged(-1), tagged(1), tagged(1));
    clear_exception();

    /* 3. Invoking a closure with > 32 parameters must raise and not leak args. */
    ArcClosure *big_clos = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    big_clos->code = (void *)noop_fiber_fn;
    big_clos->arity = 33;
    int64_t args[33];
    for (int i = 0; i < 33; i++)
        args[i] = (int64_t)(uintptr_t)arc_alloc_bytes(2);
    ocamlcc_apply_n((int64_t)(uintptr_t)big_clos, 33, args);
    clear_exception();
    arc_release(big_clos);

    /* 4. Suspending on the main fiber must raise Invalid_argument. */
    ocamlcc_fiber_suspend(tagged(1));
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

    /* 3. Stranded pending finalizers after an exception must stay DISPATCH_READY. */
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
    assert(ocamlcc_finalizers_due() == 1);
    ocamlcc_fiber_suspend(1);
    expect_invalid("suspend");
    ocamlcc_fiber_can_yield(1);
    expect_invalid("can_yield");
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
    assert(ocamlcc_finalizers_due() == 1);

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
    assert(ocamlcc_finalizers_due() == 1);
    if (ocamlcc_get_exn())
        clear_exception();
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
    int64_t *queued = arc_alloc(ARC_TAG_ARRAY, 3, 24);
    for (int i = 0; i < 3; i++)
        queued[i] = ocamlcc_fiber_create((int64_t)(uintptr_t)clos);
    arc_release(clos);
    int64_t *some_sched = arc_alloc(0, 1, 8);
    some_sched[0] = (int64_t)(uintptr_t)queued;
    ocamlcc_fiber_sched_set((int64_t)(uintptr_t)some_sched);
    arc_release(some_sched);
    if (g_probe_key_ok)
        pthread_setspecific(g_probe_key, (void *)(uintptr_t)1);
    return NULL; /* thread exits with 3 fibers still held in TLS sched_val */
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
    char *xf = arc_alloc_bytes(8);

    /* 1. ba_to_bytes copies the array slice into bytes for raw fd write. */
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

    ocamlcc_ba_to_bytes(ba, tagged(0), (int64_t)(uintptr_t)xf, tagged(0), tagged(8));
    assert(!ocamlcc_get_exn());
    ocamlcc_raw_fd_write(tagged(fds[1]), (int64_t)(uintptr_t)xf, tagged(0), tagged(8));
    assert(!ocamlcc_get_exn());

    /* 2. A valid sub-range copies only that slice. */
    ocamlcc_ba_to_bytes(ba, tagged(2), (int64_t)(uintptr_t)xf, tagged(0), tagged(3));
    assert(!ocamlcc_get_exn());
    ocamlcc_raw_fd_write(tagged(fds[1]), (int64_t)(uintptr_t)xf, tagged(0), tagged(3));
    assert(!ocamlcc_get_exn());

    /* 3. Out-of-range slices raise Invalid_argument, not UB. */
    ocamlcc_ba_to_bytes(ba, tagged(7), (int64_t)(uintptr_t)xf, tagged(0), tagged(4));
    clear_exception();
    ocamlcc_ba_to_bytes(ba, tagged(-1), (int64_t)(uintptr_t)xf, tagged(0), tagged(2));
    clear_exception();
    ocamlcc_ba_to_bytes(ba, tagged(0), (int64_t)(uintptr_t)xf, tagged(6), tagged(4));
    clear_exception();

    /* 4. ba_of_bytes_slice populates ba2 from raw fd read (page-aligned data). */
    int64_t *dims2 = arc_alloc_array(1, tagged(8));
    int64_t ba2 = caml_ba_create(tagged(OCAMLCC_BA_CHAR), tagged(OCAMLCC_BA_C_LAYOUT),
                                 (int64_t)(uintptr_t)dims2);
    arc_release(dims2);
    int64_t n = ocamlcc_raw_fd_read(tagged(fds[0]), (int64_t)(uintptr_t)xf, tagged(0), tagged(8));
    assert(!ocamlcc_get_exn());
    assert(n == tagged(8));
    ocamlcc_ba_of_bytes_slice(ba2, tagged(0), (int64_t)(uintptr_t)xf, tagged(0), n);
    assert(!ocamlcc_get_exn());
    OcamlccBigarrayView *check = ocamlcc_bigarray_view_acquire(ba2);
    assert(check != NULL);
    OcamlccBigarrayInfo ci = ocamlcc_bigarray_view_info(check);
    assert(memcmp(ci.data, "helloBA!", 8) == 0);
    ocamlcc_bigarray_view_release(check);

    /* 5. The sub-range write lands "llo". */
    int64_t n2 = ocamlcc_raw_fd_read(tagged(fds[0]), (int64_t)(uintptr_t)xf, tagged(0), tagged(8));
    assert(!ocamlcc_get_exn());
    assert(n2 == tagged(3));
    ocamlcc_ba_of_bytes_slice(ba2, tagged(0), (int64_t)(uintptr_t)xf, tagged(0), n2);
    assert(!ocamlcc_get_exn());
    check = ocamlcc_bigarray_view_acquire(ba2);
    ci = ocamlcc_bigarray_view_info(check);
    assert(memcmp(ci.data, "llo", 3) == 0);
    ocamlcc_bigarray_view_release(check);

    /* 6. Out-of-range input slices raise Invalid_argument. */
    ocamlcc_ba_of_bytes_slice(ba2, tagged(0), (int64_t)(uintptr_t)xf, tagged(0), tagged(9));
    clear_exception();
    ocamlcc_ba_of_bytes_slice(ba2, tagged(-1), (int64_t)(uintptr_t)xf, tagged(0), tagged(2));
    clear_exception();

    ocamlcc_raw_fd_close(tagged(fds[1]));
    ocamlcc_raw_fd_close(tagged(fds[0]));
    arc_release(xf);
    arc_release_val(ba);
    arc_release_val(ba2);
    ocamlcc_arc_collect(1);
    assert(arc_live_objects() == before);
}

static int64_t sum20_fn(int64_t clos,
                        int64_t a0, int64_t a1, int64_t a2, int64_t a3,
                        int64_t a4, int64_t a5, int64_t a6, int64_t a7,
                        int64_t a8, int64_t a9, int64_t a10, int64_t a11,
                        int64_t a12, int64_t a13, int64_t a14, int64_t a15,
                        int64_t a16, int64_t a17, int64_t a18, int64_t a19)
{
    (void)clos;
    int64_t sum = (a0 >> 1) + (a1 >> 1) + (a2 >> 1) + (a3 >> 1)
                + (a4 >> 1) + (a5 >> 1) + (a6 >> 1) + (a7 >> 1)
                + (a8 >> 1) + (a9 >> 1) + (a10 >> 1) + (a11 >> 1)
                + (a12 >> 1) + (a13 >> 1) + (a14 >> 1) + (a15 >> 1)
                + (a16 >> 1) + (a17 >> 1) + (a18 >> 1) + (a19 >> 1);
    return tagged(sum);
}

static void test_high_arity_closure(void)
{
    int64_t before = arc_live_objects();
    ArcClosure *c = arc_alloc(ARC_TAG_CLOSURE, 0u, (uint32_t)sizeof(ArcClosure));
    c->code = (void *)(uintptr_t)sum20_fn;
    c->arity = 20u;
    int64_t args[20];
    for (int i = 0; i < 20; i++)
        args[i] = tagged(i + 1);
    /* Direct apply_n with 20 args: 1+2+...+20 = 210. */
    int64_t r1 = ocamlcc_apply_n((int64_t)(uintptr_t)c, 20, args);
    assert(!ocamlcc_get_exn());
    assert(r1 == tagged(210));
    /* Partial application (12 args) followed by remaining 8 args. */
    int64_t pap = ocamlcc_apply_n((int64_t)(uintptr_t)c, 12, args);
    assert(!ocamlcc_get_exn());
    int64_t r2 = ocamlcc_apply_n(pap, 8, args + 12);
    assert(!ocamlcc_get_exn());
    assert(r2 == tagged(210));
    arc_release_val(pap);
    arc_release(c);
    assert(arc_live_objects() == before);
}

static void test_string_bytes_rel_compare(void)
{
    int64_t before = arc_live_objects();
    char *a = arc_alloc_bytes(3); memcpy(a, "a\0b", 3);
    char *b = arc_alloc_bytes(3); memcpy(b, "a\0c", 3);
    int64_t va = (int64_t)(uintptr_t)a;
    int64_t vb = (int64_t)(uintptr_t)b;

    assert(caml_lessthan(va, vb) == tagged(1));
    assert(caml_lessthan(va, va) == tagged(0));
    assert(caml_lessthan(vb, va) == tagged(0));
    assert(caml_lessequal(va, vb) == tagged(1));
    assert(caml_lessequal(va, va) == tagged(1));
    assert(caml_lessequal(vb, va) == tagged(0));
    assert(caml_greaterthan(vb, va) == tagged(1));
    assert(caml_greaterthan(va, va) == tagged(0));
    assert(caml_greaterequal(vb, va) == tagged(1));
    assert(caml_greaterequal(va, va) == tagged(1));
    assert(caml_greaterequal(va, vb) == tagged(0));
    assert(caml_equal(va, va) == tagged(1));
    assert(caml_equal(va, vb) == tagged(0));

    arc_release(a);
    arc_release(b);
    assert(arc_live_objects() == before);
}

static void test_main_shadow_stack(void)
{
    Fiber *main_fiber = arc_fiber_current();
    arc_fiber_push(1);
    arc_fiber_push_reuse(NULL);
    assert(main_fiber->shadow_base == NULL);
    assert(main_fiber->reuse_base == NULL);

    /* The scope began before the first stackful fiber was created. */
    ArcClosure *clos = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(ArcClosure));
    clos->code = (void *)tls_exit_body_fn;
    clos->arity = 1;
    int64_t child = ocamlcc_fiber_create((int64_t)(uintptr_t)clos);
    arc_fiber_pop_reuse(1);
    arc_fiber_pop(1);
    arc_fiber_push(1);
    arc_fiber_pop(1);
    assert(main_fiber->shadow_base == NULL);
    assert(main_fiber->reuse_base == NULL);
    arc_release_val(child);
    arc_release(clos);
}

static void test_bulk_array_ownership(void)
{
    int64_t before = arc_live_objects();
    /* Zero scan fields does not make a generic array immediate-only. */
    int64_t *a = arc_alloc(ARC_TAG_ARRAY, 0, 4 * sizeof(*a));
    int64_t x = (int64_t)(uintptr_t)arc_alloc_bytes(1);
    int64_t y = (int64_t)(uintptr_t)arc_alloc_bytes(1);
    int64_t z = (int64_t)(uintptr_t)arc_alloc_bytes(1);
    a[0] = x;
    a[1] = tagged(7);
    a[2] = y;
    a[3] = z;

    int64_t av = (int64_t)(uintptr_t)a;
    int64_t cv = ocamlcc_bulk_array_sub(av, tagged(0), tagged(4));
    int64_t *copy = (int64_t *)(uintptr_t)cv;
    ocamlcc_bulk_array_blit(av, tagged(0), av, tagged(1), tagged(3));
    assert(a[0] == x && a[1] == x && a[2] == tagged(7) && a[3] == y);
    ocamlcc_bulk_array_blit(av, tagged(1), av, tagged(0), tagged(3));
    assert(a[0] == x && a[1] == tagged(7) && a[2] == y && a[3] == y);
    assert(copy[0] == x && copy[1] == tagged(7) && copy[2] == y && copy[3] == z);
    assert(arc_live_objects() == before + 5);

    ocamlcc_bulk_array_fill(av, tagged(1), tagged(2), z);
    assert(a[0] == x && a[1] == z && a[2] == z && a[3] == y);
    ocamlcc_bulk_array_fill(cv, tagged(0), tagged(4), tagged(-42));
    for (int i = 0; i < 4; i++)
        assert(copy[i] == tagged(-42));
    arc_release(a);
    assert(arc_live_objects() == before + 1);
    arc_release(copy);
    assert(arc_live_objects() == before);
}

static void test_aligned_slab_reclamation(void)
{
    enum { slab_bytes = 64 * 1024, slot_bytes = 2048, count = 96 };
    uintptr_t mask = (uintptr_t)slab_bytes - 1;
    int64_t objects = arc_live_objects();
    int64_t slabs = ocamlcc_arc_slab_count(1) >> 1;
    void *slots[count];
    uintptr_t owner = 0;
    int distinct = 0;

    for (int i = 0; i < count; i++) {
        slots[i] = arc_alloc(0, 0, slot_bytes - sizeof(ArcHeader));
        uintptr_t header = (uintptr_t)((ArcHeader *)slots[i] - 1);
        uintptr_t base = header & ~mask;
        if (base != owner) {
            /* The first slot in each fresh slab follows its header. */
            assert((header & mask) < slot_bytes);
            owner = base;
            distinct++;
        }
        assert((header & mask) <= slab_bytes - slot_bytes);
    }
    assert(distinct == 4);
    assert((ocamlcc_arc_slab_count(1) >> 1) == slabs + distinct);

    /* The large-object mapping has its own retirement path. */
    void *large = arc_alloc(0, 0, slot_bytes);
    assert((ocamlcc_arc_slab_count(1) >> 1) == slabs + distinct);
    arc_release(large);
    for (int parity = 0; parity < 2; parity++)
        for (int i = parity; i < count; i += 2)
            arc_release(slots[i]);
    assert(arc_live_objects() == objects);
    assert((ocamlcc_arc_slab_count(1) >> 1) == slabs + 1);
}

int main(void)
{
    test_aligned_slab_reclamation();
    test_main_shadow_stack();
    test_bulk_array_ownership();
    test_float_format();
    test_buffered_dummy_update();
    test_cycle_loses_external_owner_at_immutable_member();
    test_weak_target_header_and_reuse();
    test_weak_get_copy_and_obj_dup();
    test_poller_multi_waiters_and_overflow();
    test_bounds_and_marshal_dos();
    test_fiber_robustness();
    test_wren_suspend_through_effect_stack();
    test_runtime_3_3();
    test_reachable_words();
    test_view_lifetime();
    test_retained_c_subview();
    test_c_view_shapes();
    test_import_contract();
    test_bigarray_channel_io();
    test_finalizer_no_suspend();
    test_poller_unwatch_waiter();
    test_tls_cleanup_queued_fibers();
    test_high_arity_closure();
    test_string_bytes_rel_compare();
    puts("stdlib runtime: formats, malformed cleanup, cycles, truncation, views");
    return 0;
}
