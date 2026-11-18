#ifndef OCAMLCC_BIGARRAY_H
#define OCAMLCC_BIGARRAY_H

#include "ocamlcc_bigarray_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Borrow a live ocamlcc value for this call. A Bigarray returns one owned
 * reference, any other valid value returns NULL. */
OcamlccBigarrayView *ocamlcc_bigarray_view_acquire(int64_t value);

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
