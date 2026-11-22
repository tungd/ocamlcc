#ifndef OCAMLCC_CAML_MLVALUES_H
#define OCAMLCC_CAML_MLVALUES_H

#if !defined(OCAMLCC_CAML_LEAF) && !defined(OCAMLCC_CAML_ALLOC)
#error "ARC C compatibility requires OCAMLCC_CAML_LEAF or OCAMLCC_CAML_ALLOC"
#endif

#include "arc.h"

/* Borrowed inputs. ARC strings have an explicit length and a flat payload. */
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
#define Val_true Val_int(1)
#define Val_unit Val_int(0)

#define Bp_val(v) ((char *)(uintptr_t)(v))
#define String_val(v) ((const char *)(uintptr_t)(v))
#define Bytes_val(v) ((unsigned char *)(uintptr_t)(v))
#ifdef OCAMLCC_CAML_ALLOC
#define ARCH_SIXTYFOUR 1
#define Max_long (INT64_MAX >> 1)
#define Is_long(v) (((v) & 1) != 0)
#define Is_block(v) (!Is_long(v))
#define Field(v, i) (((value *)(uintptr_t)(v))[i])
#define Double_val(v) (*(const double *)(uintptr_t)(v))
#define Int32_val(v) (*(const int32_t *)(uintptr_t)(v))
#define Int64_val(v) (*(const int64_t *)(uintptr_t)(v))
#define Nativeint_val(v) Int64_val(v)
#else
#define Field(v, i) (((const value *)(uintptr_t)(v))[i])
#endif

static inline uintnat caml_string_length(value v)
{
    const ArcHeader *header = (const ArcHeader *)(uintptr_t)v - 1;
    return atomic_load_explicit(&header->reserved, memory_order_relaxed);
}

#endif
