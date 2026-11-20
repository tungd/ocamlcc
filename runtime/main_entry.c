/* main_entry.c — standalone executable entry point invoking the compiled
 * module initializer. Kept in its own translation unit so shared libraries
 * linking libocamlrt.a do not pull an undefined reference to
 * ocamlcc_module_init. */
#include <stdio.h>
#include "arc.h"

extern void ocamlcc_module_init(void);
extern void ocamlcc_run_at_exit(void);
extern void ocamlcc_set_argv(int argc, char **argv);

int main(int argc, char **argv)
{
    ocamlcc_set_argv(argc, argv);
    int entered = arc_mutator_enter();
    ocamlcc_module_init();
    ocamlcc_run_at_exit();
    arc_mutator_leave(entered);
    fflush(stdout);
    return 0;
}
