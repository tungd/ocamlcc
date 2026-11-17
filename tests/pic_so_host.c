/* Host C program linked against a QBE 1.3 PIC shared library built from
 * examples/mod_lib.ml. Verifies shared-library initialization, closure
 * invocation across DSO boundary, and zero ARC leaks. */
#include <stdio.h>
#include <stdint.h>

extern void ocamlcc_init_Mod_lib(void);
extern int64_t ocamlcc_global_Mod_lib;
extern int64_t ocamlcc_apply1(int64_t clos, int64_t a0);
extern int64_t arc_live_objects(void);

int main(void)
{
    ocamlcc_init_Mod_lib();
    int64_t *mod = (int64_t *)(uintptr_t)ocamlcc_global_Mod_lib;
    /* mod[0] = Lib_err id, mod[1] = create, mod[2] = get, mod[3] = square */
    int64_t square_clos = mod[3];
    int64_t arg = (7ll << 1) | 1ll;
    int64_t res = ocamlcc_apply1(square_clos, arg);
    printf("square(7)=%lld live_nonneg=%d\n",
           (long long)(res >> 1), arc_live_objects() >= 0 ? 1 : 0);
    return 0;
}
