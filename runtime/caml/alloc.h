#ifndef OCAMLCC_CAML_ALLOC_H
#define OCAMLCC_CAML_ALLOC_H

#ifndef OCAMLCC_CAML_ALLOC
#error "ARC allocating C compatibility requires OCAMLCC_CAML_ALLOC"
#endif

#include "mlvalues.h"

/* Enter before calling an unchanged allocating primitive. The result owns
   its references at exit. Field writes may only initialize fresh blocks.
   A primitive may call C helpers within the scope. It may not yield. */
value ocamlcc_caml_call(value (*primitive)(const value *), const value *args);

value caml_alloc_small(uintnat fields, unsigned tag);
value caml_alloc_string(uintnat length);
value caml_copy_string(const char *str);
value caml_copy_int32(int32_t n);
value caml_copy_int64(int64_t n);
value caml_copy_nativeint(intnat n);

#endif
