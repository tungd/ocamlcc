/* Public C runtime contracts: malformed Marshal cleanup and ARC view lifetime. */
#include "../runtime/arc.h"
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
int main(void)
{
    test_partial_cycle(); test_complete_cycle(); test_truncation_and_mutation(); test_view_lifetime();
    puts("stdlib runtime: malformed cleanup, cycles, truncation, views");
    return 0;
}
