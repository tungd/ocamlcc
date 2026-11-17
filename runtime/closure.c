/* closure.c — generic closure and partial-application (PAP) dispatch.
 *
 * Closures carry their compiled entry point and total arity; exact-arity
 * indirect calls invoke code(clos, args...) directly, partial applications
 * build an ArcPap, and over-applications saturate the closure then apply
 * the remaining arguments to the returned closure. */
#include "arc.h"
#include "pal.h"

#define MAX_CLOSURE_ARITY 16

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
    default: pal_abort();
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
            if (p->total_arity > MAX_CLOSURE_ARITY)
                pal_abort();
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
            int64_t res = invoke_closure(c, c->arity, argv);
            if (ocamlcc_get_exn() != 0) {
                for (uint64_t i = c->arity; i < n; i++)
                    arc_release_val(argv[i]);
                return 1;
            }
            int64_t final = ocamlcc_apply_n_raw(
                res, argc - (int64_t)c->arity, argv + c->arity);
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
            if (p->total_arity > MAX_CLOSURE_ARITY)
                pal_abort();
            int64_t buf[MAX_CLOSURE_ARITY];
            for (uint64_t i = 0; i < p->n_applied; i++) {
                arc_retain_val(p->args[i]);
                buf[i] = p->args[i];
            }
            for (uint64_t i = 0; i < rem; i++)
                buf[p->n_applied + i] = argv[i];
            int64_t res = invoke_closure(p->orig, p->total_arity, buf);
            if (n == rem)
                return res;
            if (ocamlcc_get_exn() != 0) {
                for (uint64_t i = rem; i < n; i++)
                    arc_release_val(argv[i]);
                return 1;
            }
            int64_t final = ocamlcc_apply_n_raw(res, argc - (int64_t)rem, argv + rem);
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

int64_t ocamlcc_apply2(int64_t clos, int64_t a0, int64_t a1)
{
    int64_t argv[2] = { a0, a1 };
    return ocamlcc_apply_n(clos, 2, argv);
}

int64_t ocamlcc_apply3(int64_t clos, int64_t a0, int64_t a1, int64_t a2)
{
    int64_t argv[3] = { a0, a1, a2 };
    return ocamlcc_apply_n(clos, 3, argv);
}

int64_t ocamlcc_apply4(int64_t clos, int64_t a0, int64_t a1, int64_t a2, int64_t a3)
{
    int64_t argv[4] = { a0, a1, a2, a3 };
    return ocamlcc_apply_n(clos, 4, argv);
}
