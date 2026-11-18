#ifndef OCAMLCC_BIGARRAY_H
#define OCAMLCC_BIGARRAY_H

#include "ocamlcc_bigarray_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Borrow a live ocamlcc value for this call. A Bigarray returns one owned
 * reference, any other valid value returns NULL. */
OcamlccBigarrayView *ocamlcc_bigarray_view_acquire(int64_t value);

/* Transfer a contiguous writable allocation into this runtime. data must be
 * non-NULL and element-aligned, including for empty views. byte_length is the
 * available capacity. The dimensions are copied. NULL means invalid input:
 * ownership stays with the caller. The thread dropping the last backing owner
 * calls release(original data, context) once, after ARC traversal and outside
 * the collector and FFI mutator gates. Keep context and callback code live
 * until delivery. The callback may reenter the runtime and must return normally. */
OcamlccBigarrayView *ocamlcc_bigarray_view_import(const OcamlccBigarrayInfo *buffer,
    OcamlccBigarrayRelease release, void *context);

/* Each retain creates one more owner. Release once per acquired or retained
 * reference. Both functions accept NULL. */
OcamlccBigarrayView *ocamlcc_bigarray_view_retain(OcamlccBigarrayView *view);
void ocamlcc_bigarray_view_release(OcamlccBigarrayView *view);

/* Requires a live view. Data and dimensions remain valid while an owner is
 * held. Copying this descriptor borrows those pointers. Coordinate writes
 * across aliases and keep an owner until all asynchronous access finishes. */
OcamlccBigarrayInfo ocamlcc_bigarray_view_info(const OcamlccBigarrayView *view);

#ifdef __cplusplus
}
#endif
#endif
