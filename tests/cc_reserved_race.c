/* ThreadSanitizer-targeted stress for the lock-free ArcHeader.reserved read
 * in release_subtree racing cc_roots_remove_locked's swap-move writes.
 *
 * Workers repeatedly buffer cycle candidates in g_cc_roots (rc 2 -> 1 calls
 * cc_roots_add under g_cc_lock) and then drop them, so release_subtree reads
 * (cur->reserved & CC_BUFFERED) without the lock while other workers'
 * cc_roots_remove_locked swap-moves g_cc_roots.data[last] into their own
 * slot and rewrites moved->reserved. A collector thread keeps the trial
 * deletion machinery active. Under TSan the C11 data race on reserved is
 * reported deterministically within a few seconds of churn. */
#include "../runtime/arc.h"
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>

#define NUM_WORKERS 4

static _Atomic int g_stop = 0;

static void *race_worker(void *p)
{
    _Atomic int *stop = (_Atomic int *)p;
    int entered = arc_mutator_enter();
    while (atomic_load_explicit(stop, memory_order_acquire) == 0) {
        int64_t *arr = arc_alloc_array(1, 1);
        arc_retain(arr); /* rc 2 */
        arc_release(arr); /* rc 1: buffered as a cycle candidate */
        arc_release(arr); /* rc 0: release_subtree reads reserved lock-free */
    }
    arc_mutator_leave(entered);
    return NULL;
}

static void *collector_worker(void *p)
{
    _Atomic int *stop = (_Atomic int *)p;
    int entered = arc_mutator_enter();
    while (atomic_load_explicit(stop, memory_order_acquire) == 0) {
        ocamlcc_arc_collect(1);
        sched_yield();
    }
    arc_mutator_leave(entered);
    return NULL;
}

int main(void)
{
    pthread_t workers[NUM_WORKERS];
    pthread_t collector;
    if (pthread_create(&collector, NULL, collector_worker, &g_stop) != 0)
        return 1;
    for (int i = 0; i < NUM_WORKERS; i++) {
        if (pthread_create(&workers[i], NULL, race_worker, &g_stop) != 0)
            return 1;
    }
    for (int i = 0; i < 20000; i++)
        sched_yield();
    atomic_store_explicit(&g_stop, 1, memory_order_release);
    for (int i = 0; i < NUM_WORKERS; i++)
        pthread_join(workers[i], NULL);
    pthread_join(collector, NULL);
    if (ocamlcc_arc_collect(1) != 1) {
        fputs("final collect failed\n", stderr);
        return 1;
    }
    puts("cc reserved race stress: done");
    return 0;
}
