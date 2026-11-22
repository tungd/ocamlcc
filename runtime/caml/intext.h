#ifndef OCAMLCC_CAML_INTEXT_H
#define OCAMLCC_CAML_INTEXT_H

#include "alloc.h"

void caml_serialize_int_1(int n);
void caml_serialize_int_4(int32_t n);
int caml_deserialize_uint_1(void);
uint32_t caml_deserialize_uint_4(void);
_Noreturn void caml_deserialize_error(const char *message);

#endif
