#ifndef OCAMLCC_CAML_LEAF_MEMORY_H
#define OCAMLCC_CAML_LEAF_MEMORY_H

#include "mlvalues.h"

#define CAMLparam1(a) ((void)(a))
#define CAMLparam2(a, b) (CAMLparam1(a), CAMLparam1(b))
#define CAMLparam3(a, b, c) (CAMLparam2(a, b), CAMLparam1(c))
#define CAMLparam4(a, b, c, d) (CAMLparam3(a, b, c), CAMLparam1(d))
#define CAMLreturn(v) return (v)

#endif
