/* Multi-threaded FFI stress test: 8 concurrent pthreads calling exported
 * OCaml functions sharing a closure, allocating/dropping ARC objects,
 * using Weak.t, raising/catching exceptions, and running fibers. */
#include "../runtime/arc.h"
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdint.h>

extern void ocamlcc_init_Stdlib(void);
extern void ocamlcc_init_Mt_ffi_lib(void);
extern int64_t ocamlcc_global_Mt_ffi_lib;

#define NUM_THREADS 8
#define NUM_ITERS   200

typedef struct ThreadArg {
    int tid;
    int64_t work_iter_clos;
    int64_t shared_fn_clos;
    int64_t call_shared_clos;
    int64_t cycle_iter_clos;
    int64_t atomic_iter_clos;
    int ok;
} ThreadArg;

static int64_t expected_work_iter(int seed)
{
    int64_t sum_list = 36 + 8 * seed;
    int64_t sum_arr = (seed + 1) + (seed + 5);
    int64_t wv = seed + 10;
    int64_t bv = seed + 10;
    int64_t exn_v = seed + 7;
    int64_t r2 = seed + 6;
    int64_t acc = 11;
    return sum_list + sum_arr + wv + bv + exn_v + r2 + acc;
}

static void *worker(void *p)
{
    ThreadArg *arg = (ThreadArg *)p;
    int ok = 1;
    for (int i = 0; i < NUM_ITERS; i++) {
        int seed = arg->tid * 1000 + i;
        int64_t tagged_seed = ((int64_t)seed << 1) | 1ll;
        int64_t res = ocamlcc_apply1(arg->work_iter_clos, tagged_seed);
        if ((res >> 1) != expected_work_iter(seed)) {
            ok = 0;
            break;
        }
        /* Concurrently retain/release and invoke the shared closure. */
        arc_retain_val(arg->shared_fn_clos);
        int64_t sres = ocamlcc_apply2(arg->call_shared_clos,
                                      arg->shared_fn_clos, tagged_seed);
        arc_release_val(arg->shared_fn_clos);
        if ((sres >> 1) != ((int64_t)seed * 3 + 1)) {
            ok = 0;
            break;
        }
        if (ocamlcc_apply1(arg->atomic_iter_clos, tagged_seed) != 3) {
            ok = 0;
            break;
        }
        int64_t cres = ocamlcc_apply1(arg->cycle_iter_clos, tagged_seed);
        if ((cres >> 1) != ((int64_t)seed * 2 + 1)) {
            ok = 0;
            break;
        }
    }
    arg->ok = ok;
    return NULL;
}

static void *collector_worker(void *p)
{
    _Atomic int *stop = (_Atomic int *)p;
    while (atomic_load_explicit(stop, memory_order_acquire) == 0) {
        ocamlcc_arc_collect(1);
    }
    return NULL;
}

/* Hold the mutator gate open until the main thread has attempted a major
 * collection. Each thread owns one reference when registration starts. */
typedef struct {
    void *target;
    _Atomic int phase;
} FinalizerHandoff;

extern int64_t caml_gc_full_major(int64_t);
extern int64_t caml_final_register_called_without_value(int64_t, int64_t);

static void wait_phase(FinalizerHandoff *h, int phase)
{
    while (atomic_load(&h->phase) != phase)
        sched_yield();
}

static void *drop_owner(void *arg)
{
    FinalizerHandoff *h = arg;
    int entered = arc_mutator_enter();
    atomic_store(&h->phase, 1);
    wait_phase(h, 2);
    arc_release(h->target);
    atomic_store(&h->phase, 3);
    wait_phase(h, 4);
    arc_mutator_leave(entered);
    return NULL;
}

static int last_calls;
static int64_t count_last(int64_t closure, int64_t unit)
{
    (void)closure;
    if (unit == 1)
        ++last_calls;
    return 1;
}

static int test_finalizer_handoff(void)
{
    int entered = arc_mutator_enter();
    int64_t *target = arc_alloc(0, 1, sizeof(*target));
    *target = 1;
    arc_retain(target);
    FinalizerHandoff handoff = { target, 0 };
    pthread_t worker_thread;
    if (pthread_create(&worker_thread, NULL, drop_owner, &handoff) != 0) {
        arc_release(target);
        arc_release(target);
        arc_mutator_leave(entered);
        return 0;
    }
    wait_phase(&handoff, 1);
    ArcClosure *callback = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(*callback));
    callback->code = (void *)count_last;
    callback->arity = 1;
    atomic_store(&handoff.phase, 2);
    caml_final_register_called_without_value((int64_t)(uintptr_t)callback,
                                            (int64_t)(uintptr_t)target);
    arc_release(callback);
    arc_release(target);
    wait_phase(&handoff, 3);
    caml_gc_full_major(1);
    int deferred = last_calls == 0;
    atomic_store(&handoff.phase, 4);
    pthread_join(worker_thread, NULL);
    caml_gc_full_major(1);
    caml_gc_full_major(1);
    arc_mutator_leave(entered);
    return deferred && last_calls == 1;
}

/* The outer callback waits for a second mutator. Both explicit collection
 * and the generated poll path must be able to take released, ready work. */
extern int64_t caml_final_release(int64_t);
extern int64_t ocamlcc_finalizers_due(void);
extern int64_t ocamlcc_poll_finalizers(void);

static int use_poll, observed_handoff;
static void *try_dispatch(void *unused)
{
    (void)unused;
    int entered = arc_mutator_enter();
    caml_final_release(1); /* unrelated fiber, including before owner release */
    if (!use_poll)
        caml_gc_full_major(1);
    else if (ocamlcc_finalizers_due() != 1)
        ocamlcc_poll_finalizers();
    arc_mutator_leave(entered);
    return NULL;
}

static int run_other_mutator(void)
{
    pthread_t thread;
    return pthread_create(&thread, NULL, try_dispatch, NULL) == 0 &&
           pthread_join(thread, NULL) == 0;
}

static int64_t release_and_wait(int64_t closure, int64_t unit)
{
    (void)closure;
    (void)unit;
    if (!run_other_mutator() || last_calls != 0)
        return 1;
    caml_final_release(1);
    caml_final_release(1);
    observed_handoff = run_other_mutator() && last_calls == 1;
    return 1;
}

static int test_released_queue(int poll)
{
    last_calls = observed_handoff = 0;
    use_poll = poll;
    int64_t *target = arc_alloc(0, 1, sizeof(*target));
    *target = 1;
    ArcClosure *callback = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(*callback));
    callback->arity = 1;
    callback->code = (void *)count_last;
    caml_final_register_called_without_value((int64_t)(uintptr_t)callback,
                                             (int64_t)(uintptr_t)target);
    arc_release(callback);
    callback = arc_alloc(ARC_TAG_CLOSURE, 0, sizeof(*callback));
    callback->arity = 1;
    callback->code = (void *)release_and_wait;
    caml_final_register_called_without_value((int64_t)(uintptr_t)callback,
                                             (int64_t)(uintptr_t)target);
    arc_release(callback);
    arc_release(target);
    caml_gc_full_major(1);
    return observed_handoff && last_calls == 1;
}

int main(void)
{
    ocamlcc_init_Stdlib();
    ocamlcc_init_Mt_ffi_lib();
    int64_t *mod = (int64_t *)(uintptr_t)ocamlcc_global_Mt_ffi_lib;
    /* mod[0] = work_iter, mod[1] = shared_fn, mod[2] = call_shared, mod[3] = cycle_iter */
    int64_t work_iter_clos = mod[0];
    int64_t shared_fn_clos = mod[1];
    int64_t call_shared_clos = mod[2];
    int64_t cycle_iter_clos = mod[3];

    ocamlcc_arc_collect(1);
    int64_t base_live = arc_live_objects();

    if (!test_finalizer_handoff()) {
        fputs("finalizer delivery across skipped collection failed\n", stderr);
        return 1;
    }

    if (!test_released_queue(0) || !test_released_queue(1)) {
        fputs("released callback did not run on the waiting mutator before return\n", stderr);
        return 1;
    }

    _Atomic int stop_collector = 0;
    pthread_t collector;
    if (pthread_create(&collector, NULL, collector_worker, &stop_collector) != 0)
        return 2;

    pthread_t threads[NUM_THREADS];
    ThreadArg args[NUM_THREADS];
    for (int t = 0; t < NUM_THREADS; t++) {
        args[t].tid = t;
        args[t].work_iter_clos = work_iter_clos;
        args[t].shared_fn_clos = shared_fn_clos;
        args[t].call_shared_clos = call_shared_clos;
        args[t].cycle_iter_clos = cycle_iter_clos;
        args[t].atomic_iter_clos = mod[4];
        args[t].ok = 0;
        if (pthread_create(&threads[t], NULL, worker, &args[t]) != 0)
            return 2;
    }
    int all_ok = 1;
    for (int t = 0; t < NUM_THREADS; t++) {
        pthread_join(threads[t], NULL);
        if (!args[t].ok)
            all_ok = 0;
    }
    atomic_store_explicit(&stop_collector, 1, memory_order_release);
    pthread_join(collector, NULL);

    ocamlcc_arc_collect(1);
    int64_t end_live = arc_live_objects();
    printf("all_ok=%d delta=%lld\n", all_ok, (long long)(end_live - base_live));
    return (all_ok && end_live == base_live) ? 0 : 1;
}
