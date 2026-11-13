/* builtins.c — C entry points the code generator emits calls to, plus the
 * process main that invokes the compiled module initializer. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

void ocamlcc_print_int(int64_t n) { printf("%lld", (long long)n); }

void ocamlcc_exit(int64_t code)
{
    fflush(stdout);
    exit((int)code);
}

extern void ocamlcc_module_init(void);

int main(void)
{
    ocamlcc_module_init();
    fflush(stdout);
    return 0;
}
