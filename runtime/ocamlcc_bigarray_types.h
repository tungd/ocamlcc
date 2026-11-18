#ifndef OCAMLCC_BIGARRAY_TYPES_H
#define OCAMLCC_BIGARRAY_TYPES_H

#include <stddef.h>
#include <stdint.h>

/* Opaque owner of an OCaml Bigarray wrapper and its contiguous backing. */
typedef struct OcamlccBigarrayView OcamlccBigarrayView;
typedef void (*OcamlccBigarrayRelease)(void *base, void *context);

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

#endif
