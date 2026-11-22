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

#ifdef __linux__
/* The ARC compiler uses the native stack for deeply nested IR traversals. */
__attribute__((constructor)) static void reserve_compiler_stack(void)
{
    const rlim_t requested = 64u * 1024u * 1024u;
    struct rlimit limit;
    if (getrlimit(RLIMIT_STACK, &limit) != 0 || limit.rlim_cur >= requested)
        return;
    limit.rlim_cur = limit.rlim_max < requested ? limit.rlim_max : requested;
    (void)setrlimit(RLIMIT_STACK, &limit);
}
#endif

static int64_t tag_int(int64_t n) { return (int64_t)(((uint64_t)n << 1) | 1u); }

int64_t caml_zstd_initialize(int64_t ignored)
{
    (void)ignored;
    return tag_int(1); /* true */
}

int64_t ocamlcc_zstd_compress_bytes(int64_t src_val, int64_t dst_val)
{
    const ArcHeader *sh = (const ArcHeader *)(uintptr_t)src_val - 1;
    const ArcHeader *dh = (const ArcHeader *)(uintptr_t)dst_val - 1;
    size_t r = ZSTD_compress((void *)(uintptr_t)dst_val, (size_t)dh->reserved,
                             (const void *)(uintptr_t)src_val, (size_t)sh->reserved,
                             ZSTD_CLEVEL_DEFAULT);
    if (ZSTD_isError(r))
        return tag_int(-1);
    return tag_int((int64_t)r);
}

int64_t ocamlcc_zstd_decompress_bytes(int64_t src_val, int64_t src_ofs_val,
                                      int64_t src_len_val, int64_t dst_val)
{
    const ArcHeader *sh = (const ArcHeader *)(uintptr_t)src_val - 1;
    const ArcHeader *dh = (const ArcHeader *)(uintptr_t)dst_val - 1;
    int64_t ofs = src_ofs_val >> 1;
    int64_t slen = src_len_val >> 1;
    if (ofs < 0 || slen < 0 || (uint64_t)ofs > sh->reserved ||
        (uint64_t)slen > sh->reserved - (uint64_t)ofs)
        return tag_int(-1);
    size_t r = ZSTD_decompress((void *)(uintptr_t)dst_val, (size_t)dh->reserved,
                               (const uint8_t *)(uintptr_t)src_val + ofs,
                               (size_t)slen);
    if (ZSTD_isError(r) || r != (size_t)dh->reserved)
        return tag_int(-1);
    return tag_int(0);
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
