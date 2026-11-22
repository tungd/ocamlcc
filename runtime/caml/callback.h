#ifndef OCAMLCC_CAML_CALLBACK_H
#define OCAMLCC_CAML_CALLBACK_H

#include "alloc.h"

/* Borrowed for the duration of the current primitive. */
const value *caml_named_value(const char *name);

#endif
