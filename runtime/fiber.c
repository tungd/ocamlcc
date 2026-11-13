/* fiber.c — shadow-stack lifecycle skeleton (control-flow transfer in
 * Phase 3: context switching lives behind pal-level assembly or ucontext). */
#include "fiber.h"

#include "arc.h"

void fiber_init(Fiber *fiber, size_t stack_words)
{
    fiber->stack_base = NULL; /* allocated in Phase 3 via pal_page_alloc */
    fiber->stack_sp = NULL;
    fiber->stack_words = stack_words;
    fiber->caller = NULL;
    fiber->state = FIBER_SUSPENDED;
}

void fiber_free(Fiber *fiber)
{
    /* Deterministic ARC cleanup: drop every live reference on the shadow
       stack, then release the stack buffer. */
    for (uint64_t *slot = fiber->stack_base; slot && slot < fiber->stack_sp;
         slot++) {
        void *obj = (void *)*slot;
        if (obj != NULL && ((uintptr_t)obj & 1u) == 0)
            arc_release(obj);
    }
    fiber->stack_base = NULL;
    fiber->stack_sp = NULL;
    fiber->state = FIBER_DONE;
}

Fiber *fiber_yield(Fiber *current)
{
    /* Phase 3: swap context to fiber->caller and mark this fiber
       suspended. */
    (void)current;
    return NULL;
}
