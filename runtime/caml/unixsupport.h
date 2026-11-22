#ifndef OCAMLCC_CAML_LEAF_UNIXSUPPORT_H
#define OCAMLCC_CAML_LEAF_UNIXSUPPORT_H

#include "mlvalues.h"

/* Supplied by arc-unix. The wrapped function borrows its arguments and
   calls uerror only with Nothing. The jump stays inside this C boundary. */
typedef value (*arc_unix_leaf3_fn)(value, value, value);

value arc_unix_call_leaf3(arc_unix_leaf3_fn leaf, value a, value b, value c);
_Noreturn void arc_unix_leaf_uerror(const char *operation, value argument);

#define Nothing ((value)0)
#define uerror arc_unix_leaf_uerror

#endif
