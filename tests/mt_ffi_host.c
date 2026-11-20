/* Multi-threaded FFI stress test: 8 concurrent pthreads calling exported
 * OCaml functions sharing a closure, allocating/dropping ARC objects,
 * using Weak.t, raising/catching exceptions, and running fibers. */
#include "../runtime/arc.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>

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
extern int64_t caml_ba_create(int64_t, int64_t, int64_t);
extern int64_t caml_ml_mutex_new(int64_t);
extern int64_t caml_ml_mutex_lock(int64_t);
extern int64_t caml_ml_mutex_unlock(int64_t);
extern int64_t caml_ml_condition_new(int64_t);
extern int64_t caml_ml_condition_wait(int64_t, int64_t);
extern int64_t caml_ml_condition_signal(int64_t);

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

static void *custom_leaf_worker(void *p)
{
    _Atomic int *stop = (_Atomic int *)p;
    int entered = arc_mutator_enter();
    int64_t *dims = arc_alloc_array(1, (8ll << 1) | 1ll);
    arc_mutator_leave(entered);
    while (atomic_load_explicit(stop, memory_order_acquire) == 0) {
        int iter_entered = arc_mutator_enter();
        int64_t ba = caml_ba_create((12ll << 1) | 1ll, (0ll << 1) | 1ll,
                                    (int64_t)(uintptr_t)dims);
        /* Buffer a cycle candidate so g_cc_roots is non-empty during collect. */
        int64_t *arr = arc_alloc_array(1, 1);
        arc_retain(arr);
        arc_release(arr);
        arc_mutator_leave(iter_entered);
        /* Release the Bigarray outside the mutator gate so release_subtree can
         * race with an active cycle collection (g_cc_active != 0). */
        arc_release_val(ba);
        iter_entered = arc_mutator_enter();
        arc_release(arr);
        arc_mutator_leave(iter_entered);
    }
    entered = arc_mutator_enter();
    arc_release(dims);
    arc_mutator_leave(entered);
    return NULL;
}

static void test_custom_leaf_collect_race(void)
{
    _Atomic int stop = 0;
    pthread_t collector;
    pthread_t workers[4];
    if (pthread_create(&collector, NULL, collector_worker, &stop) != 0)
        return;
    for (int i = 0; i < 4; i++) {
        if (pthread_create(&workers[i], NULL, custom_leaf_worker, &stop) != 0) {
            atomic_store_explicit(&stop, 1, memory_order_release);
            pthread_join(collector, NULL);
            return;
        }
    }
    for (int i = 0; i < 500; i++)
        sched_yield();
    atomic_store_explicit(&stop, 1, memory_order_release);
    for (int i = 0; i < 4; i++)
        pthread_join(workers[i], NULL);
    pthread_join(collector, NULL);
}

typedef struct {
    int64_t mtx;
    int64_t cond;
    _Atomic int stop;
    int turn;
} SyncRaceArg;

static void *sync_race_worker(void *p)
{
    SyncRaceArg *arg = (SyncRaceArg *)p;
    int entered = arc_mutator_enter();
    for (int i = 0; i < 400; i++) {
        caml_ml_mutex_lock(arg->mtx);
        while (arg->turn == 1 && atomic_load_explicit(&arg->stop, memory_order_acquire) == 0)
            caml_ml_condition_wait(arg->cond, arg->mtx);
        arg->turn = 1;
        /* Allocate and drop a cycle candidate right after waking from wait/lock. */
        int64_t *arr = arc_alloc_array(1, 1);
        arc_retain(arr);
        arc_release(arr);
        arc_release(arr);
        caml_ml_condition_signal(arg->cond);
        caml_ml_mutex_unlock(arg->mtx);
    }
    arc_mutator_leave(entered);
    return NULL;
}

static void test_mutex_cond_collect_race(void)
{
    int entered = arc_mutator_enter();
    SyncRaceArg arg;
    arg.mtx = caml_ml_mutex_new(1);
    arg.cond = caml_ml_condition_new(1);
    atomic_init(&arg.stop, 0);
    arg.turn = 0;
    arc_mutator_leave(entered);

    _Atomic int stop_col = 0;
    pthread_t collector, waiter;
    if (pthread_create(&collector, NULL, collector_worker, &stop_col) != 0)
        goto cleanup;
    if (pthread_create(&waiter, NULL, sync_race_worker, &arg) != 0) {
        atomic_store_explicit(&stop_col, 1, memory_order_release);
        pthread_join(collector, NULL);
        goto cleanup;
    }

    entered = arc_mutator_enter();
    for (int i = 0; i < 400; i++) {
        caml_ml_mutex_lock(arg.mtx);
        arg.turn = 0;
        caml_ml_condition_signal(arg.cond);
        caml_ml_mutex_unlock(arg.mtx);
    }
    atomic_store_explicit(&arg.stop, 1, memory_order_release);
    caml_ml_mutex_lock(arg.mtx);
    arg.turn = 0;
    caml_ml_condition_signal(arg.cond);
    caml_ml_mutex_unlock(arg.mtx);
    arc_mutator_leave(entered);

    pthread_join(waiter, NULL);
    atomic_store_explicit(&stop_col, 1, memory_order_release);
    pthread_join(collector, NULL);

cleanup:
    entered = arc_mutator_enter();
    arc_release_val(arg.cond);
    arc_release_val(arg.mtx);
    arc_mutator_leave(entered);
}

extern void arc_fiber_push(int64_t);
extern void arc_fiber_pop(int64_t);
extern void arc_fiber_push_reuse(void *);
extern void arc_fiber_pop_reuse(int64_t);
extern int64_t ocamlcc_poller_wait(int64_t, int64_t);

static void *tls_exit_worker(void *p)
{
    (void)p;
    arc_fiber_push(1);
    arc_fiber_pop(1);
    arc_fiber_push_reuse(NULL);
    arc_fiber_pop_reuse(1);
    int64_t arr = (int64_t)(uintptr_t)arc_alloc(ARC_TAG_ARRAY, 0u, 8u);
    ((int64_t *)(uintptr_t)arr)[0] = 1;
    ocamlcc_poller_wait(arr, (1ll << 1) | 1ll);
    arc_release_val(arr);
    return NULL;
}

static int test_thread_exit_tls_cleanup(void)
{
    int base_fd = dup(0);
    if (base_fd < 0)
        return 0;
    close(base_fd);

    for (int i = 0; i < 32; i++) {
        pthread_t th;
        if (pthread_create(&th, NULL, tls_exit_worker, NULL) != 0)
            return 0;
        pthread_join(th, NULL);
    }

    int after_fd = dup(0);
    if (after_fd < 0)
        return 0;
    close(after_fd);
    if (after_fd >= base_fd + 8)
        fprintf(stderr, "base_fd=%d after_fd=%d\n", base_fd, after_fd);
    return after_fd < base_fd + 8;
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

    test_custom_leaf_collect_race();
    test_mutex_cond_collect_race();

    if (!test_thread_exit_tls_cleanup()) {
        fputs("worker thread exit leaked poller fd\n", stderr);
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
