/* main_entry.c — standalone executable entry point invoking the compiled
 * module initializer. Kept in its own translation unit so shared libraries
 * linking libocamlrt.a do not pull an undefined reference to
 * ocamlcc_module_init. */
#include <stdio.h>

extern void ocamlcc_module_init(void);

int main(void)
{
    ocamlcc_module_init();
    fflush(stdout);
    return 0;
}
