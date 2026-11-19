/* Compiler-only C stubs for self-hosted ocamlcc.
 *
 * Linked ONLY into the self-hosted ocamlcc compiler executable (never into
 * libocamlrt.a or user programs), matching upstream OCaml's separation of
 * libzstd and compiler-libs primitives from the core runtime. */
#define _POSIX_C_SOURCE 200809L
#include "arc.h"
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <zstd.h>

static int64_t tag_int(int64_t n) { return (int64_t)(((uint64_t)n << 1) | 1u); }

static int ocamlcc_zstd_decompress(const uint8_t *src, size_t src_len,
                                   uint8_t *dst, size_t dst_len)
{
    size_t r = ZSTD_decompress(dst, dst_len, src, src_len);
    if (ZSTD_isError(r) || r != dst_len)
        return -1;
    return 0;
}

static int ocamlcc_zstd_compress(const uint8_t *src, size_t src_len,
                                 uint8_t *dst, size_t dst_cap, size_t *out_len)
{
    size_t r = ZSTD_compress(dst, dst_cap, src, src_len, ZSTD_CLEVEL_DEFAULT);
    if (ZSTD_isError(r))
        return -1;
    *out_len = r;
    return 0;
}

int64_t caml_zstd_initialize(int64_t ignored)
{
    (void)ignored;
    ocamlcc_marshal_register_codec(ocamlcc_zstd_decompress, ocamlcc_zstd_compress);
    return tag_int(1); /* true */
}

int64_t caml_sys_get_stdlib_dirs(int64_t default_dir)
{
    const char *env = getenv("OCAMLLIB");
    if (env == NULL || env[0] == '\0')
        env = getenv("CAMLLIB");
    int64_t dir_val;
    if (env != NULL && env[0] != '\0') {
        size_t len = strlen(env);
        char *s = (char *)arc_alloc_bytes(len);
        memcpy(s, env, len);
        dir_val = (int64_t)(uintptr_t)s;
    } else {
        arc_retain_val(default_dir);
        dir_val = default_dir;
    }
    int64_t *cons = (int64_t *)arc_alloc(0u, 2u, 16u);
    cons[0] = dir_val;
    cons[1] = 1; /* [] */
    return (int64_t)(uintptr_t)cons;
}

int64_t caml_sys_time_include_children(int64_t ignored)
{
    (void)ignored;
    struct rusage self_ru, child_ru;
    double total = 0.0;
    if (getrusage(RUSAGE_SELF, &self_ru) == 0) {
        total += (double)self_ru.ru_utime.tv_sec + (double)self_ru.ru_utime.tv_usec * 1e-6;
        total += (double)self_ru.ru_stime.tv_sec + (double)self_ru.ru_stime.tv_usec * 1e-6;
    }
    if (getrusage(RUSAGE_CHILDREN, &child_ru) == 0) {
        total += (double)child_ru.ru_utime.tv_sec + (double)child_ru.ru_utime.tv_usec * 1e-6;
        total += (double)child_ru.ru_stime.tv_sec + (double)child_ru.ru_stime.tv_usec * 1e-6;
    }
    return ocamlcc_alloc_float(total);
}

int64_t caml_terminfo_rows(int64_t chan_val)
{
    (void)chan_val;
    /* Returning 0 signals no terminfo cursor control (plain text diagnostics). */
    return tag_int(0);
}
