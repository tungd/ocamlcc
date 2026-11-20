/* closure.c — generic closure and partial-application (PAP) dispatch.
 *
 * Closures carry their compiled entry point and total arity; exact-arity
 * indirect calls invoke code(clos, args...) directly, partial applications
 * build an ArcPap, and over-applications saturate the closure then apply
 * the remaining arguments to the returned closure. */
#include "arc.h"
#include "pal.h"

extern void arc_fiber_push(int64_t val);
extern void arc_fiber_pop(int64_t count);

#define MAX_CLOSURE_ARITY 32

typedef int64_t (*fn1_t)(int64_t, int64_t);
typedef int64_t (*fn2_t)(int64_t, int64_t, int64_t);
typedef int64_t (*fn3_t)(int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn4_t)(int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn5_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn6_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn7_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn8_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn9_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn10_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn11_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn12_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn13_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn14_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn15_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn16_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn17_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn18_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn19_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn20_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn21_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn22_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn23_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn24_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn25_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn26_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn27_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn28_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn29_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn30_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn31_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
typedef int64_t (*fn32_t)(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);

static int64_t invoke_closure(ArcClosure *c, uint64_t arity, const int64_t *a)
{
    int64_t cv = (int64_t)(uintptr_t)c;
    switch (arity) {
    case 1:  return ((fn1_t)c->code)(cv, a[0]);
    case 2:  return ((fn2_t)c->code)(cv, a[0], a[1]);
    case 3:  return ((fn3_t)c->code)(cv, a[0], a[1], a[2]);
    case 4:  return ((fn4_t)c->code)(cv, a[0], a[1], a[2], a[3]);
    case 5:  return ((fn5_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4]);
    case 6:  return ((fn6_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5]);
    case 7:  return ((fn7_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
    case 8:  return ((fn8_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
    case 9:  return ((fn9_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]);
    case 10: return ((fn10_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9]);
    case 11: return ((fn11_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10]);
    case 12: return ((fn12_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11]);
    case 13: return ((fn13_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12]);
    case 14: return ((fn14_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13]);
    case 15: return ((fn15_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14]);
    case 16: return ((fn16_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15]);
    case 17: return ((fn17_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16]);
    case 18: return ((fn18_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17]);
    case 19: return ((fn19_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18]);
    case 20: return ((fn20_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19]);
    case 21: return ((fn21_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20]);
    case 22: return ((fn22_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21]);
    case 23: return ((fn23_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21], a[22]);
    case 24: return ((fn24_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21], a[22], a[23]);
    case 25: return ((fn25_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21], a[22], a[23], a[24]);
    case 26: return ((fn26_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21], a[22], a[23], a[24], a[25]);
    case 27: return ((fn27_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21], a[22], a[23], a[24], a[25], a[26]);
    case 28: return ((fn28_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21], a[22], a[23], a[24], a[25], a[26], a[27]);
    case 29: return ((fn29_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21], a[22], a[23], a[24], a[25], a[26], a[27], a[28]);
    case 30: return ((fn30_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21], a[22], a[23], a[24], a[25], a[26], a[27], a[28], a[29]);
    case 31: return ((fn31_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21], a[22], a[23], a[24], a[25], a[26], a[27], a[28], a[29], a[30]);
    case 32: return ((fn32_t)c->code)(cv, a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16], a[17], a[18], a[19], a[20], a[21], a[22], a[23], a[24], a[25], a[26], a[27], a[28], a[29], a[30], a[31]);
    default:
        for (uint64_t i = 0; i < arity; i++)
            arc_release_val(a[i]);
        ocamlcc_fiber_raise_invalid();
        return 1;
    }
}

static ArcPap *alloc_pap(ArcClosure *orig, uint64_t total_arity,
                         uint64_t prev_n, const int64_t *prev_args,
                         uint64_t add_n, const int64_t *add_args)
{
    uint64_t n = prev_n + add_n;
    ArcPap *pap = arc_alloc((uint16_t)ARC_TAG_PAP,
                            (uint16_t)(1u + n),
                            (uint32_t)(sizeof(ArcPap) + n * sizeof(int64_t)));
    arc_retain(orig);
    pap->orig = orig;
    pap->total_arity = total_arity;
    pap->n_applied = n;
    for (uint64_t i = 0; i < prev_n; i++) {
        arc_retain_val(prev_args[i]);
        pap->args[i] = prev_args[i];
    }
    for (uint64_t i = 0; i < add_n; i++)
        pap->args[prev_n + i] = add_args[i];
    return pap;
}

int64_t ocamlcc_apply1_raw(int64_t clos_val, int64_t a0)
{
    if (clos_val & 1)
        pal_abort();
    ArcHeader *hdr = (ArcHeader *)(uintptr_t)clos_val - 1;
    if (hdr->tag == ARC_TAG_CLOSURE) {
        ArcClosure *c = (ArcClosure *)(uintptr_t)clos_val;
        if (c->arity == 1)
            return ((fn1_t)c->code)(clos_val, a0);
        return (int64_t)(uintptr_t)alloc_pap(c, c->arity, 0, NULL, 1, &a0);
    }
    if (hdr->tag == ARC_TAG_PAP) {
        ArcPap *p = (ArcPap *)(uintptr_t)clos_val;
        if (p->n_applied + 1 == p->total_arity) {
            if (p->total_arity > MAX_CLOSURE_ARITY) {
                arc_release_val(a0);
                ocamlcc_fiber_raise_invalid();
                return 1;
            }
            int64_t buf[MAX_CLOSURE_ARITY];
            for (uint64_t i = 0; i < p->n_applied; i++) {
                arc_retain_val(p->args[i]);
                buf[i] = p->args[i];
            }
            buf[p->n_applied] = a0;
            return invoke_closure(p->orig, p->total_arity, buf);
        }
        return (int64_t)(uintptr_t)alloc_pap(
            p->orig, p->total_arity, p->n_applied, p->args, 1, &a0);
    }
    pal_abort();
}

int64_t ocamlcc_apply_n_raw(int64_t clos_val, int64_t argc, int64_t *argv)
{
    if (argc <= 0) {
        arc_retain_val(clos_val);
        return clos_val;
    }
    if (clos_val & 1)
        pal_abort();
    ArcHeader *hdr = (ArcHeader *)(uintptr_t)clos_val - 1;
    if (hdr->tag == ARC_TAG_CLOSURE) {
        ArcClosure *c = (ArcClosure *)(uintptr_t)clos_val;
        uint64_t n = (uint64_t)argc;
        if (c->arity == n)
            return invoke_closure(c, c->arity, argv);
        if (c->arity < n) {
            for (uint64_t i = c->arity; i < n; i++)
                arc_fiber_push(argv[i]);
            int64_t res = invoke_closure(c, c->arity, argv);
            arc_fiber_pop((int64_t)(n - c->arity));
            if (ocamlcc_get_exn() != 0) {
                for (uint64_t i = c->arity; i < n; i++)
                    arc_release_val(argv[i]);
                return 1;
            }
            arc_fiber_push(res);
            int64_t final = ocamlcc_apply_n_raw(
                res, argc - (int64_t)c->arity, argv + c->arity);
            arc_fiber_pop(1);
            arc_release_val(res);
            return final;
        }
        return (int64_t)(uintptr_t)alloc_pap(c, c->arity, 0, NULL, n, argv);
    }
    if (hdr->tag == ARC_TAG_PAP) {
        ArcPap *p = (ArcPap *)(uintptr_t)clos_val;
        uint64_t n = (uint64_t)argc;
        uint64_t rem = p->total_arity - p->n_applied;
        if (n >= rem) {
            if (p->total_arity > MAX_CLOSURE_ARITY) {
                for (uint64_t i = 0; i < n; i++)
                    arc_release_val(argv[i]);
                ocamlcc_fiber_raise_invalid();
                return 1;
            }
            int64_t buf[MAX_CLOSURE_ARITY];
            for (uint64_t i = 0; i < p->n_applied; i++) {
                arc_retain_val(p->args[i]);
                buf[i] = p->args[i];
            }
            for (uint64_t i = 0; i < rem; i++)
                buf[p->n_applied + i] = argv[i];
            if (n > rem) {
                for (uint64_t i = rem; i < n; i++)
                    arc_fiber_push(argv[i]);
            }
            int64_t res = invoke_closure(p->orig, p->total_arity, buf);
            if (n == rem)
                return res;
            arc_fiber_pop((int64_t)(n - rem));
            if (ocamlcc_get_exn() != 0) {
                for (uint64_t i = rem; i < n; i++)
                    arc_release_val(argv[i]);
                return 1;
            }
            arc_fiber_push(res);
            int64_t final = ocamlcc_apply_n_raw(res, argc - (int64_t)rem, argv + rem);
            arc_fiber_pop(1);
            arc_release_val(res);
            return final;
        }
        return (int64_t)(uintptr_t)alloc_pap(
            p->orig, p->total_arity, p->n_applied, p->args, n, argv);
    }
    pal_abort();
}

int64_t ocamlcc_apply1(int64_t clos_val, int64_t a0)
{
    int entered = arc_mutator_enter();
    int64_t res = ocamlcc_apply1_raw(clos_val, a0);
    arc_mutator_leave(entered);
    return res;
}

int64_t ocamlcc_apply_n(int64_t clos_val, int64_t argc, int64_t *argv)
{
    int entered = arc_mutator_enter();
    int64_t res = ocamlcc_apply_n_raw(clos_val, argc, argv);
    arc_mutator_leave(entered);
    return res;
}

static ArcClosure *exact_closure(int64_t clos, uint64_t arity)
{
    if (clos & 1)
        return NULL;
    ArcClosure *c = (ArcClosure *)(uintptr_t)clos;
    return (((ArcHeader *)c - 1)->tag == ARC_TAG_CLOSURE && c->arity == arity)
        ? c : NULL;
}

int64_t ocamlcc_apply2_raw(int64_t clos, int64_t a0, int64_t a1)
{
    ArcClosure *c = exact_closure(clos, 2);
    if (c != NULL)
        return ((fn2_t)c->code)(clos, a0, a1);
    int64_t argv[2] = { a0, a1 };
    return ocamlcc_apply_n_raw(clos, 2, argv);
}

int64_t ocamlcc_apply3_raw(int64_t clos, int64_t a0, int64_t a1, int64_t a2)
{
    ArcClosure *c = exact_closure(clos, 3);
    if (c != NULL)
        return ((fn3_t)c->code)(clos, a0, a1, a2);
    int64_t argv[3] = { a0, a1, a2 };
    return ocamlcc_apply_n_raw(clos, 3, argv);
}

int64_t ocamlcc_apply4_raw(int64_t clos, int64_t a0, int64_t a1, int64_t a2, int64_t a3)
{
    ArcClosure *c = exact_closure(clos, 4);
    if (c != NULL)
        return ((fn4_t)c->code)(clos, a0, a1, a2, a3);
    int64_t argv[4] = { a0, a1, a2, a3 };
    return ocamlcc_apply_n_raw(clos, 4, argv);
}

int64_t ocamlcc_apply2(int64_t clos, int64_t a0, int64_t a1)
{
    int entered = arc_mutator_enter();
    int64_t res = ocamlcc_apply2_raw(clos, a0, a1);
    arc_mutator_leave(entered);
    return res;
}

int64_t ocamlcc_apply3(int64_t clos, int64_t a0, int64_t a1, int64_t a2)
{
    int entered = arc_mutator_enter();
    int64_t res = ocamlcc_apply3_raw(clos, a0, a1, a2);
    arc_mutator_leave(entered);
    return res;
}

int64_t ocamlcc_apply4(int64_t clos, int64_t a0, int64_t a1, int64_t a2, int64_t a3)
{
    int entered = arc_mutator_enter();
    int64_t res = ocamlcc_apply4_raw(clos, a0, a1, a2, a3);
    arc_mutator_leave(entered);
    return res;
}
