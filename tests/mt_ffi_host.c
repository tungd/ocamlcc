/* Multi-threaded FFI stress test: 8 concurrent pthreads calling exported
 * OCaml functions sharing a closure, allocating/dropping ARC objects,
 * using Weak.t, raising/catching exceptions, and running fibers. */
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>

extern void ocamlcc_init_Stdlib(void);
extern void ocamlcc_init_Mt_ffi_lib(void);
extern int64_t ocamlcc_global_Mt_ffi_lib;
extern int64_t ocamlcc_apply1(int64_t clos, int64_t a0);
extern int64_t ocamlcc_apply2(int64_t clos, int64_t a0, int64_t a1);
extern int64_t ocamlcc_arc_collect(int64_t unit);
extern int64_t arc_live_objects(void);
extern void arc_retain_val(int64_t v);
extern void arc_release_val(int64_t v);

#define NUM_THREADS 8
#define NUM_ITERS   200

typedef struct ThreadArg {
    int tid;
    int64_t work_iter_clos;
    int64_t shared_fn_clos;
    int64_t call_shared_clos;
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
    }
    arg->ok = ok;
    return NULL;
}

int main(void)
{
    ocamlcc_init_Stdlib();
    ocamlcc_init_Mt_ffi_lib();
    int64_t *mod = (int64_t *)(uintptr_t)ocamlcc_global_Mt_ffi_lib;
    /* mod[0] = work_iter, mod[1] = shared_fn, mod[2] = call_shared */
    int64_t work_iter_clos = mod[0];
    int64_t shared_fn_clos = mod[1];
    int64_t call_shared_clos = mod[2];

    ocamlcc_arc_collect(1);
    int64_t base_live = arc_live_objects();

    pthread_t threads[NUM_THREADS];
    ThreadArg args[NUM_THREADS];
    for (int t = 0; t < NUM_THREADS; t++) {
        args[t].tid = t;
        args[t].work_iter_clos = work_iter_clos;
        args[t].shared_fn_clos = shared_fn_clos;
        args[t].call_shared_clos = call_shared_clos;
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

    ocamlcc_arc_collect(1);
    int64_t end_live = arc_live_objects();
    printf("all_ok=%d delta=%lld\n", all_ok, (long long)(end_live - base_live));
    return (all_ok && end_live == base_live) ? 0 : 1;
}
