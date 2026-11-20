/* TDD contract test for bootstrap/stubs/compiler_stubs.c (zstd + compiler-libs). */
#include "../runtime/arc.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int64_t caml_zstd_initialize(int64_t);
extern int64_t ocamlcc_zstd_compress_bytes(int64_t, int64_t);
extern int64_t ocamlcc_zstd_decompress_bytes(int64_t, int64_t, int64_t, int64_t);
extern int64_t caml_sys_get_stdlib_dirs(int64_t);
extern int64_t caml_sys_time_include_children(int64_t);
extern int64_t caml_terminfo_rows(int64_t);

static int64_t tagged(int64_t n) { return (int64_t)(((uint64_t)n << 1) | 1); }

static void test_zstd_roundtrip(void)
{
    int64_t before = arc_live_objects();

    assert(caml_zstd_initialize(1) == tagged(1)); /* true */
    assert(!ocamlcc_get_exn());

    char *src = arc_alloc_bytes(512);
    for (int i = 0; i < 512; i++) src[i] = (char)('A' + (i % 4));
    char *dst = arc_alloc_bytes(1024);
    int64_t comp_len = ocamlcc_zstd_compress_bytes(
        (int64_t)(uintptr_t)src, (int64_t)(uintptr_t)dst);
    assert(!ocamlcc_get_exn());
    assert((comp_len & 1) == 1);
    int64_t clen = comp_len >> 1;
    assert(clen > 4 && clen < 200);
    /* ZSTD frame magic: 0x28 0xB5 0x2F 0xFD */
    assert((uint8_t)dst[0] == 0x28u && (uint8_t)dst[1] == 0xb5u &&
           (uint8_t)dst[2] == 0x2fu && (uint8_t)dst[3] == 0xfdu);

    char *rec = arc_alloc_bytes(512);
    int64_t rc = ocamlcc_zstd_decompress_bytes(
        (int64_t)(uintptr_t)dst, tagged(0), comp_len, (int64_t)(uintptr_t)rec);
    assert(rc == tagged(0));
    assert(memcmp(src, rec, 512) == 0);

    arc_release(rec);
    arc_release(dst);
    arc_release(src);
    ocamlcc_arc_collect(1);
    assert(arc_live_objects() == before);
}

static void test_compiler_os_stubs(void)
{
    int64_t before = arc_live_objects();

    /* 1. caml_sys_get_stdlib_dirs: default fallback when OCAMLLIB/CAMLLIB unset. */
    unsetenv("OCAMLLIB");
    unsetenv("CAMLLIB");
    char *def = arc_alloc_bytes(8);
    memcpy(def, "/def/lib", 8);
    int64_t dirs = caml_sys_get_stdlib_dirs((int64_t)(uintptr_t)def);
    assert(!ocamlcc_get_exn());
    assert((dirs & 1) == 0);
    int64_t *cons = (int64_t *)(uintptr_t)dirs;
    assert(cons[1] == 1); /* [] */
    const ArcHeader *sh = (const ArcHeader *)(uintptr_t)cons[0] - 1;
    assert(sh->tag == ARC_TAG_STRING && sh->reserved == 8u);
    assert(memcmp((const void *)(uintptr_t)cons[0], "/def/lib", 8) == 0);
    arc_release_val(dirs);

    /* With OCAMLLIB set, OCAMLLIB takes precedence. */
    setenv("OCAMLLIB", "/env/lib", 1);
    int64_t dirs2 = caml_sys_get_stdlib_dirs((int64_t)(uintptr_t)def);
    assert(!ocamlcc_get_exn());
    int64_t *cons2 = (int64_t *)(uintptr_t)dirs2;
    assert(cons2[1] == 1);
    assert(memcmp((const void *)(uintptr_t)cons2[0], "/env/lib", 8) == 0);
    arc_release_val(dirs2);
    unsetenv("OCAMLLIB");
    arc_release(def);

    /* 2. caml_sys_time_include_children returns a non-negative boxed float. */
    int64_t t = caml_sys_time_include_children(1);
    assert(!ocamlcc_get_exn());
    const ArcHeader *th = (const ArcHeader *)(uintptr_t)t - 1;
    assert(th->tag == ARC_TAG_FLOAT);
    double tv = *(const double *)(uintptr_t)t;
    assert(tv >= 0.0);
    arc_release_val(t);

    /* 3. caml_terminfo_rows returns a tagged non-negative int. */
    int64_t rows = caml_terminfo_rows(1);
    assert(!ocamlcc_get_exn());
    assert((rows & 1) == 1 && (rows >> 1) >= 0);

    ocamlcc_arc_collect(1);
    assert(arc_live_objects() == before);
}

int main(void)
{
    test_zstd_roundtrip();
    test_compiler_os_stubs();
    puts("compiler_stubs_test: PASS");
    return 0;
}
