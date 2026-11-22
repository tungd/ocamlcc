/* Included by primitives.c. Each frame keeps one owner for every allocation
   until the primitive returns or raises, including discarded local values. */
#include "caml/callback.h"
#include "caml/fail.h"
#include "caml/hash.h"
#include "caml/intext.h"

#include <setjmp.h>
#include <stdlib.h>

typedef struct {
    value value;
    uint16_t fields;
} CamlAllocation;

typedef struct {
    CamlAllocation inline_allocations[8];
    CamlAllocation *allocations;
    size_t count;
    size_t capacity;
    jmp_buf *raise_to;
} CamlFrame;

static _Thread_local CamlFrame *caml_frame;
static _Atomic value caml_lookup;
extern const void *ocamlcc_global_Division_by_zero;

static value track_caml_allocation(value v, uint16_t fields)
{
    CamlFrame *frame = caml_frame;
    if (frame == NULL)
        pal_abort();
    if (frame->count == frame->capacity) {
        if (frame->capacity > SIZE_MAX / 2 / sizeof(CamlAllocation))
            pal_abort();
        size_t cap = frame->capacity * 2;
        CamlAllocation *items = malloc(cap * sizeof *items);
        if (items == NULL)
            pal_abort();
        pal_memcpy(items, frame->allocations, frame->count * sizeof *items);
        if (frame->allocations != frame->inline_allocations)
            free(frame->allocations);
        frame->capacity = cap;
        frame->allocations = items;
    }
    frame->allocations[frame->count++] = (CamlAllocation){v, fields};
    return v;
}

static value invoke_caml_primitive(CamlFrame *frame,
                                   value (*primitive)(const value *),
                                   const value *args)
{
    jmp_buf raise_to;
    frame->raise_to = &raise_to;
    if (setjmp(raise_to) != 0)
        return Val_unit;
    return primitive(args);
}

value ocamlcc_caml_call(value (*primitive)(const value *), const value *args)
{
    CamlFrame frame = {0};
    frame.allocations = frame.inline_allocations;
    frame.capacity = sizeof frame.inline_allocations / sizeof *frame.inline_allocations;
    CamlFrame *previous = caml_frame;
    caml_frame = &frame;
    value result = invoke_caml_primitive(&frame, primitive, args);
    caml_frame = previous;

    /* Stock Field assignments initialize fresh blocks with borrowed values. */
    for (size_t i = 0; i < frame.count; i++) {
        const CamlAllocation *item = &frame.allocations[i];
        for (uint16_t slot = 0; slot < item->fields; slot++)
            arc_retain_val(Field(item->value, slot));
    }
    arc_retain_val(result);
    for (size_t i = frame.count; i > 0; i--)
        arc_release_val(frame.allocations[i - 1].value);
    if (frame.allocations != frame.inline_allocations)
        free(frame.allocations);
    return result;
}

value caml_alloc_small(uintnat fields, unsigned tag)
{
    if (tag > 244 || fields == 0 || fields > UINT16_MAX)
        caml_invalid_argument("caml_alloc_small");
    value *data = arc_alloc(tag, (uint16_t)fields, (uint32_t)(fields * sizeof *data));
    for (uintnat i = 0; i < fields; i++)
        data[i] = Val_unit;
    return track_caml_allocation((value)(uintptr_t)data, (uint16_t)fields);
}

value caml_alloc_string(uintnat length)
{
    if (length > UINT32_MAX - 1 - sizeof(ArcHeader))
        caml_invalid_argument("caml_alloc_string");
    return track_caml_allocation((value)(uintptr_t)arc_alloc_bytes(length), 0);
}

value caml_copy_string(const char *str)
{
    size_t len = strlen(str);
    value v = caml_alloc_string(len);
    pal_memcpy((void *)(uintptr_t)v, str, len);
    return v;
}

value caml_copy_int32(int32_t n)
{
    return track_caml_allocation(ocamlcc_alloc_custom(ARC_CUSTOM_INT32, (uint64_t)(int64_t)n), 0);
}

value caml_copy_int64(int64_t n)
{
    return track_caml_allocation(ocamlcc_alloc_custom(ARC_CUSTOM_INT64, (uint64_t)n), 0);
}

value caml_copy_nativeint(intnat n)
{
    return track_caml_allocation(ocamlcc_alloc_custom(ARC_CUSTOM_NATIVEINT, (uint64_t)n), 0);
}

static bool valid_caml_custom_ops(const struct custom_operations *ops)
{
    return ops != NULL && ops->identifier != NULL &&
           ops->identifier[0] != '\0' && ops->finalize == NULL;
}

void caml_register_custom_operations(const struct custom_operations *ops)
{
    if (!valid_caml_custom_ops(ops))
        caml_invalid_argument("caml_register_custom_operations");
}

value caml_alloc_custom(const struct custom_operations *ops, uintnat size,
                        uintnat mem, uintnat max)
{
    (void)mem;
    (void)max;
    if (!valid_caml_custom_ops(ops) ||
        size > UINT32_MAX - sizeof(ArcHeader) - sizeof ops)
        caml_invalid_argument("caml_alloc_custom");
    const struct custom_operations **data =
        arc_alloc(ARC_TAG_CUSTOM, 0, (uint32_t)(sizeof ops + size));
    ((ArcHeader *)data - 1)->reserved = ARC_CUSTOM_FOREIGN;
    *data = ops;
    return track_caml_allocation((value)(uintptr_t)data, 0);
}

static _Noreturn void unwind_caml_primitive(void)
{
    if (caml_frame == NULL)
        pal_abort();
    longjmp(*caml_frame->raise_to, 1);
}

_Noreturn void caml_raise_constant(value exception)
{
    arc_retain_val(exception);
    ocamlcc_set_exn(exception);
    unwind_caml_primitive();
}

_Noreturn void caml_raise_zero_divide(void)
{
    caml_raise_constant((value)(uintptr_t)ocamlcc_global_Division_by_zero);
}

_Noreturn void caml_invalid_argument(const char *message)
{
    value text = caml_copy_string(message);
    value *block = arc_alloc(0, 2, 2 * sizeof *block);
    block[0] = (value)(uintptr_t)ocamlcc_global_Invalid_argument;
    arc_retain_val(text);
    block[1] = text;
    ocamlcc_set_exn((value)(uintptr_t)block);
    unwind_caml_primitive();
}

_Noreturn void caml_failwith(const char *message)
{
    raise_failure_cstr(message, strlen(message));
    unwind_caml_primitive();
}

value ocamlcc_caml_install_lookup(value fn)
{
    arc_retain_val(fn);
    value unregistered = 0;
    if (!atomic_compare_exchange_strong(&caml_lookup, &unregistered, fn))
        arc_release_val(fn);
    return Val_unit;
}

const value *caml_named_value(const char *name)
{
    value lookup = atomic_load_explicit(&caml_lookup, memory_order_acquire);
    if (lookup == 0)
        return NULL;
    value key = caml_copy_string(name);
    arc_retain_val(key);
    value option = ocamlcc_apply1_raw(lookup, key);
    if (ocamlcc_get_exn() != 0)
        unwind_caml_primitive();
    if (option == Val_unit)
        return NULL;
    track_caml_allocation(option, 0);
    return (const value *)(uintptr_t)option;
}

uint32_t caml_hash_mix_uint32(uint32_t hash, uint32_t data)
{
    return hash_mix32(hash, data);
}

/* Marshal currently admits only the built-in custom kinds. */
_Noreturn void caml_deserialize_error(const char *message)
{
    caml_failwith(message);
}

void caml_serialize_int_1(int n)
{
    (void)n;
    caml_failwith("custom C serialization is unavailable");
}

void caml_serialize_int_4(int32_t n)
{
    caml_serialize_int_1(n);
}

int caml_deserialize_uint_1(void)
{
    caml_deserialize_error("custom C deserialization is unavailable");
}

uint32_t caml_deserialize_uint_4(void)
{
    return (uint32_t)caml_deserialize_uint_1();
}
