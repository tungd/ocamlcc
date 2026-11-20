#include "../runtime/arc.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>

static void *enter_from_foreign_thread(void *arg)
{
    (void)arg;
    int entered = arc_mutator_enter();
    arc_mutator_leave(entered);
    return NULL;
}

static void check_reference_counts(void)
{
    int64_t live_before = arc_live_objects();
    void *value = arc_alloc(0, 0, sizeof(int64_t));
    *(int64_t *)value = 1;
    ArcHeader *header = (ArcHeader *)value - 1;
    int64_t val = (int64_t)(uintptr_t)value;

    arc_retain(value);
    int64_t *items = arc_alloc_array(3, val);
    assert(atomic_load_explicit(&header->refcount, memory_order_relaxed) == 4);
    arc_release(items);
    assert(atomic_load_explicit(&header->refcount, memory_order_relaxed) == 1);

    int64_t weak = ocamlcc_weak_create(3);
    int64_t *some = arc_alloc(0, 1, sizeof(int64_t));
    arc_retain(value);
    *some = val;
    ocamlcc_weak_set(weak, 1, (int64_t)(uintptr_t)some);
    arc_release(some);
    int64_t item = ocamlcc_weak_get(weak, 1);
    assert(item != 1 && *(int64_t *)(uintptr_t)item == val);
    arc_release_val(item);
    assert(atomic_load_explicit(&header->refcount, memory_order_relaxed) == 1);

    void *token = arc_drop_reuse(val);
    assert(token == header);
    assert(ocamlcc_weak_check(weak, 1) == 1);
    assert(ocamlcc_weak_get(weak, 1) == 1);
    void *reused = arc_alloc_reuse(token, 0, 0, sizeof(int64_t));
    assert(reused == value);
    arc_release(reused);
    arc_release_val(weak);
    assert(arc_live_objects() == live_before);
}

int main(int argc, char **argv)
{
    (void)argv;
    int entered = arc_mutator_enter();
    if (argc > 1) {
        pthread_t thread;
        assert(pthread_create(&thread, NULL, enter_from_foreign_thread, NULL) == 0);
        assert(pthread_join(thread, NULL) == 0);
    } else {
        check_reference_counts();
    }
    arc_mutator_leave(entered);
    return 0;
}
