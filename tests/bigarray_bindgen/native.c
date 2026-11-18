#include "../../runtime/arc.h"
#include "../../runtime/ocamlcc_bigarray.h"

/* The OCaml allocation primitive borrows an array of tagged dimensions. */
extern int64_t caml_ba_create(int64_t kind, int64_t layout, int64_t dims);

OcamlccBigarrayView *vectors_native_buffer(unsigned rank)
{
    int entered = arc_mutator_enter();
    int64_t *dims = arc_alloc_array(rank, 2 * 2 + 1);
    int64_t value = caml_ba_create(2 * OCAMLCC_BA_FLOAT64 + 1,
                                   2 * OCAMLCC_BA_C_LAYOUT + 1,
                                   (int64_t)(uintptr_t)dims);
    OcamlccBigarrayView *view = ocamlcc_bigarray_view_acquire(value);
    arc_release_val(value);
    arc_release(dims);
    arc_mutator_leave(entered);
    return view;
}
