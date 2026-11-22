#ifndef OCAMLCC_CAML_MEMORY_H
#define OCAMLCC_CAML_MEMORY_H

#include "mlvalues.h"

#define CAMLparam1(a) ((void)(a))
#define CAMLparam2(a, b) (CAMLparam1(a), CAMLparam1(b))
#define CAMLparam3(a, b, c) (CAMLparam2(a, b), CAMLparam1(c))
#define CAMLparam4(a, b, c, d) (CAMLparam3(a, b, c), CAMLparam1(d))
#define CAMLreturn(v) return (v)

#ifdef OCAMLCC_CAML_ALLOC
/* The surrounding call owns the allocations even if a local is overwritten
   or the primitive returns directly without CAMLreturn. */
#define CAMLlocal1(a) value a = Val_unit
#define CAMLlocal2(a, b) CAMLlocal1(a), b = Val_unit
#define CAMLlocal3(a, b, c) CAMLlocal2(a, b), c = Val_unit
#define CAMLlocal4(a, b, c, d) CAMLlocal3(a, b, c), d = Val_unit
#define CAMLlocal5(a, b, c, d, e) CAMLlocal4(a, b, c, d), e = Val_unit
#endif

#endif
