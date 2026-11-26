#ifndef OCAMLCC_CAML_LEAF_BIGARRAY_H
#define OCAMLCC_CAML_LEAF_BIGARRAY_H

/* Some borrowed-byte stubs include this header without using the API. */
#include "mlvalues.h"
#include "ocamlcc_bigarray.h"

/* Borrowed data pointer of a live Bigarray value. The caller holds the
 * value, so the backing stays valid after the temporary view is released. */
static inline void *Caml_ba_data_val(value v)
{
    OcamlccBigarrayView *view = ocamlcc_bigarray_view_acquire(v);
    if (view == NULL)
        return NULL;
    OcamlccBigarrayInfo info = ocamlcc_bigarray_view_info(view);
    void *data = info.data;
    ocamlcc_bigarray_view_release(view);
    return data;
}

#endif
