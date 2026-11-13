/*
 * fiber.h — Wren-style stackful coroutines (design doc §4.4).
 *
 * Each fiber is an ARC-managed heap object owning a contiguous shadow
 * value stack. Suspension pushes live ARC references onto the shadow
 * stack; dropping a suspended fiber with refcount zero walks the shadow
 * stack from sp to base and arc_releases every live reference before
 * freeing the stack buffer. Skeleton until Phase 3.
 */
#ifndef OCAMLCC_FIBER_H
#define OCAMLCC_FIBER_H

#include <stddef.h>
#include <stdint.h>

typedef enum FiberState {
    FIBER_SUSPENDED,
    FIBER_RUNNING,
    FIBER_DONE
} FiberState;

typedef struct Fiber {
    uint64_t *stack_base;
    uint64_t *stack_sp;    /* live slots: [stack_base, stack_sp) */
    size_t    stack_words;
    struct Fiber *caller;  /* asymmetric yield / symmetric transfer link */
    FiberState state;
} Fiber;

void  fiber_init(Fiber *fiber, size_t stack_words);
void  fiber_free(Fiber *fiber);   /* drops shadow-stack references */
Fiber *fiber_yield(Fiber *current);

#endif /* OCAMLCC_FIBER_H */
