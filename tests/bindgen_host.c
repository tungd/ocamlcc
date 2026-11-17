#include "bindgen_lib.h"
#include <stdio.h>
#include <string.h>

extern int64_t arc_live_objects(void);

int main(void)
{
    bindgen_lib_init();
    int64_t base_live = arc_live_objects();
    ocamlcc_error_t err = {0};

    bindgen_lib_t_t h = bindgen_lib_create(42, &err);
    int64_t hv1 = bindgen_lib_get(h, &err);
    int64_t hv2 = bindgen_lib_get(h, &err);
    bindgen_lib_t_t_release(h);

    bindgen_lib_point_t p1 = { 1.5, 2.25 };
    bindgen_lib_point_t p2 = { 3.0, 4.75 };
    bindgen_lib_point_t p3 = bindgen_lib_add_pt(p1, p2, &err);

    bindgen_lib_user_t u = { "Alice", 25 };
    char *g = bindgen_lib_greet(u, &err);

    ocamlcc_opt_int64_t o1 = bindgen_lib_opt_inc((ocamlcc_opt_int64_t){ true, 9 }, &err);
    ocamlcc_opt_int64_t o2 = bindgen_lib_opt_inc((ocamlcc_opt_int64_t){ false, 0 }, &err);

    bool b1 = bindgen_lib_flip(false, &err);
    int64_t s64 = bindgen_lib_sum_i32_i64(100, 20000000000LL, &err);
    int64_t psum = bindgen_lib_pair_sum((ocamlcc_tuple_int64_t_int64_t){ 7, 8 }, &err);

    int64_t ok_v = bindgen_lib_check_pos(5, &err);
    int err0 = err.code;
    int64_t bad_v = bindgen_lib_check_pos(-13, &err);
    int err1 = err.code;
    int err_msg_ok = (strstr(err.message, "Bad_arg(13)") != NULL) ? 1 : 0;

    int64_t end_live = arc_live_objects();
    printf("h=%lld,%lld pt=%.1f,%.1f greet=%s opt=%d:%lld,%d b=%d i64=%lld pair=%lld exn=%d:%lld,%d:%lld:%d delta=%lld\n",
           (long long)hv1, (long long)hv2, p3.x, p3.y, g,
           o1.is_some ? 1 : 0, (long long)o1.value, o2.is_some ? 1 : 0,
           b1 ? 1 : 0, (long long)s64, (long long)psum,
           err0, (long long)ok_v, err1, (long long)bad_v, err_msg_ok,
           (long long)(end_live - base_live));
    ocamlcc_free_string(g);
    return (end_live == base_live) ? 0 : 1;
}
