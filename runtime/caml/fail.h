#ifndef OCAMLCC_CAML_FAIL_H
#define OCAMLCC_CAML_FAIL_H

#include "alloc.h"

_Noreturn void caml_raise_constant(value exception);
_Noreturn void caml_raise_zero_divide(void);
_Noreturn void caml_invalid_argument(const char *message);
_Noreturn void caml_failwith(const char *message);

#endif
