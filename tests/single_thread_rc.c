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

static void *collect_from_foreign_thread(void *arg)
{
    (void)arg;
    ocamlcc_arc_collect(1);
    return NULL;
}

extern int64_t caml_gc_minor_words(int64_t);

static double allocated_words(void)
{
    void *value = (void *)(uintptr_t)caml_gc_minor_words(1);
    double words = *(double *)value;
    arc_release(value);
    return words;
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

static void check_allocation_accounting(void)
{
    enum { count = 128, bytes = 2048 - sizeof(ArcHeader) };
    void *slots[count];
    int64_t live = arc_live_objects();
    int64_t slabs = ocamlcc_arc_slab_count(1) >> 1;
    double words = allocated_words();
    for (int i = 0; i < count; i++)
        slots[i] = arc_alloc(0, 0, bytes);
    assert(arc_live_objects() == live + count);
    /* Reading the first counter allocated its own boxed float. */
    assert(allocated_words() == words + 3 + count * (bytes / 8 + 2));
    for (int i = count - 1; i >= 0; i--)
        arc_release(slots[i]);
    assert(arc_live_objects() == live);
    assert((ocamlcc_arc_slab_count(1) >> 1) == slabs + 1);
}

int main(int argc, char **argv)
{
    int entered = arc_mutator_enter();
    if (argc > 1) {
        pthread_t thread;
        if (argv[1][0] == 'c') {
            /* The collector also has an entry point outside the mutator gate. */
            arc_mutator_leave(entered);
            entered = 0;
            assert(pthread_create(&thread, NULL, collect_from_foreign_thread, NULL) == 0);
        } else {
            assert(pthread_create(&thread, NULL, enter_from_foreign_thread, NULL) == 0);
        }
        assert(pthread_join(thread, NULL) == 0);
    } else {
        check_reference_counts();
        check_allocation_accounting();
    }
    arc_mutator_leave(entered);
    return 0;
}
