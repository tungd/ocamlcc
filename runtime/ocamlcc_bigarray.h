#ifndef OCAMLCC_BIGARRAY_H
#define OCAMLCC_BIGARRAY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque owner of an OCaml Bigarray wrapper and its contiguous backing. */
typedef struct OcamlccBigarrayView OcamlccBigarrayView;

/* Element kinds and layouts use the OCaml Bigarray constructor numbers. */
enum OcamlccBigarrayKind {
    OCAMLCC_BA_FLOAT32, OCAMLCC_BA_FLOAT64,
    OCAMLCC_BA_INT8_SIGNED, OCAMLCC_BA_INT8_UNSIGNED,
    OCAMLCC_BA_INT16_SIGNED, OCAMLCC_BA_INT16_UNSIGNED,
    OCAMLCC_BA_INT32, OCAMLCC_BA_INT64, OCAMLCC_BA_INT, OCAMLCC_BA_NATIVEINT,
    OCAMLCC_BA_COMPLEX32, OCAMLCC_BA_COMPLEX64, OCAMLCC_BA_CHAR, OCAMLCC_BA_FLOAT16
};
enum OcamlccBigarrayLayout { OCAMLCC_BA_C_LAYOUT, OCAMLCC_BA_FORTRAN_LAYOUT };

typedef struct OcamlccBigarrayInfo {
    void *data;            /* first byte of this view */
    size_t byte_length;    /* zero for an empty view */
    const int64_t *dims;   /* rank dimensions in Bigarray order */
    int rank, kind, layout;
} OcamlccBigarrayInfo;

/* Borrow a live ocamlcc value for this call. A Bigarray returns one owned
 * reference, any other valid value returns NULL. */
OcamlccBigarrayView *ocamlcc_bigarray_view_acquire(int64_t value);

/* Each retain creates one more owner. Release once per acquired or retained
 * reference. Both functions accept NULL. */
OcamlccBigarrayView *ocamlcc_bigarray_view_retain(OcamlccBigarrayView *view);
void ocamlcc_bigarray_view_release(OcamlccBigarrayView *view);

/* Give the compiled OCaml callee one owned argument from a live view. */
int64_t ocamlcc_bigarray_view_to_value(OcamlccBigarrayView *view);

/* Requires a live view. Data and dimensions remain valid while an owner is
 * held. Copying this descriptor borrows those pointers. Coordinate writes
 * across aliases and keep an owner until all asynchronous access finishes. */
OcamlccBigarrayInfo ocamlcc_bigarray_view_info(const OcamlccBigarrayView *view);

#ifdef __cplusplus
}
#endif
#endif
