/* builtins.c — C entry points the code generator emits calls to. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

void ocamlcc_print_int(int64_t n) { printf("%lld", (long long)n); }

void ocamlcc_print_string(const char *s, size_t len)
{
    (void)fwrite(s, 1, len, stdout);
}

void ocamlcc_print_endline(const char *s, size_t len)
{
    ocamlcc_print_string(s, len);
    (void)fputc('\n', stdout);
}

void ocamlcc_exit(int64_t code)
{
    fflush(stdout);
    exit((int)code);
}
