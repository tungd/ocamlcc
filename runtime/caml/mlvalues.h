#ifndef OCAMLCC_CAML_LEAF_MLVALUES_H
#define OCAMLCC_CAML_LEAF_MLVALUES_H

#ifndef OCAMLCC_CAML_LEAF
#error "ARC leaf C compatibility requires -DOCAMLCC_CAML_LEAF"
#endif

#include "arc.h"

/* Borrowed inputs for leaf stubs that neither allocate ARC values nor call
   back into OCaml. ARC strings have an explicit length and a flat payload. */
typedef int64_t value;
typedef int64_t intnat;
typedef uint64_t uintnat;

#define CAMLprim
#define Long_val(v) ((intnat)(v) >> 1)
#define Int_val(v) ((int)Long_val(v))
#define Bool_val(v) ((int)Long_val(v))
#define Val_long(n) ((value)(((uintnat)(n) << 1) | UINT64_C(1)))
#define Val_int(n) Val_long(n)
#define Val_bool(b) Val_int((b) != 0)
#define Val_false Val_int(0)
#define Val_unit Val_int(0)

#define Bp_val(v) ((char *)(uintptr_t)(v))
#define String_val(v) ((const char *)(uintptr_t)(v))
#define Bytes_val(v) ((unsigned char *)(uintptr_t)(v))
#define Field(v, i) (((const value *)(uintptr_t)(v))[i])

static inline uintnat caml_string_length(value v)
{
    const ArcHeader *header = (const ArcHeader *)(uintptr_t)v - 1;
    return atomic_load_explicit(&header->reserved, memory_order_relaxed);
}

#endif
