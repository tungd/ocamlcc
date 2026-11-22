#ifndef OCAMLCC_CAML_CUSTOM_H
#define OCAMLCC_CAML_CUSTOM_H

#include "alloc.h"

struct custom_fixed_length {
    intnat bsize_32;
    intnat bsize_64;
};

struct custom_operations {
    const char *identifier;
    void (*finalize)(value);
    int (*compare)(value, value);
    intnat (*hash)(value);
    void (*serialize)(value, uintnat *, uintnat *);
    uintnat (*deserialize)(void *);
    int (*compare_ext)(value, value);
    const struct custom_fixed_length *fixed_length;
};

/* Operations live for the lifetime of the program. Compare and hash are
   leaf callbacks. This allocator admits inline data with no finalizer. */
#define custom_finalize_default NULL
#define custom_fixed_length_default NULL
#define Custom_ops_val(v) (*(const struct custom_operations *const *)(uintptr_t)(v))
#define Data_custom_val(v) ((void *)((value *)(uintptr_t)(v) + 1))

value caml_alloc_custom(const struct custom_operations *, uintnat size,
                        uintnat mem, uintnat max);
void caml_register_custom_operations(const struct custom_operations *);

#endif
