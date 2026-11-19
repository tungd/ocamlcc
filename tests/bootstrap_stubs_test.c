/* TDD contract test for bootstrap/stubs/compiler_stubs.c (zstd + compiler-libs). */
#include "../runtime/arc.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int64_t caml_zstd_initialize(int64_t);
extern int64_t caml_sys_get_stdlib_dirs(int64_t);
extern int64_t caml_sys_time_include_children(int64_t);
extern int64_t caml_terminfo_rows(int64_t);
extern int64_t caml_output_value_to_bytes(int64_t, int64_t);
extern int64_t caml_input_value_from_bytes(int64_t, int64_t);
extern int64_t caml_input_value(int64_t);
extern int64_t caml_ml_open_descriptor_in(int64_t);
extern int64_t caml_ml_close_channel(int64_t);
extern int64_t caml_ml_input_char(int64_t);

static int64_t tagged(int64_t n) { return (int64_t)(((uint64_t)n << 1) | 1); }

static void test_zstd_roundtrip_and_host_cmi(const char *cmi_path)
{
    int64_t before = arc_live_objects();

    assert(caml_zstd_initialize(1) == tagged(1)); /* true */
    assert(!ocamlcc_get_exn());

    /* 1. Compress & decompress via real libzstd. */
    int64_t *pair = arc_alloc(0u, 2u, 16u);
    pair[0] = tagged(12345);
    char *s = arc_alloc_bytes(512);
    for (int i = 0; i < 512; i++) s[i] = (char)('A' + (i % 4));
    pair[1] = (int64_t)(uintptr_t)s;

    int64_t *flags = arc_alloc(0u, 2u, 16u);
    flags[0] = tagged(3); /* Compression */
    flags[1] = 1;

    int64_t comp = caml_output_value_to_bytes((int64_t)(uintptr_t)pair,
                                              (int64_t)(uintptr_t)flags);
    assert(!ocamlcc_get_exn());
    const uint8_t *cb = (const uint8_t *)(uintptr_t)comp;
    size_t clen = ((const ArcHeader *)(uintptr_t)comp - 1)->reserved;
    assert(clen < 200u);
    assert(cb[0] == 0x84u && cb[1] == 0x95u && cb[2] == 0xa6u && cb[3] == 0xbdu);
    size_t hlen = (size_t)(cb[4] & 0x3fu);
    /* ZSTD frame magic: 0x28 0xB5 0x2F 0xFD */
    assert(hlen + 4u <= clen);
    assert(cb[hlen] == 0x28u && cb[hlen + 1u] == 0xb5u &&
           cb[hlen + 2u] == 0x2fu && cb[hlen + 3u] == 0xfdu);

    int64_t dec = caml_input_value_from_bytes(comp, tagged(0));
    assert(!ocamlcc_get_exn());
    assert(caml_compare(dec, (int64_t)(uintptr_t)pair) == tagged(0));

    arc_release_val(dec);
    arc_release_val(comp);
    arc_release_val((int64_t)(uintptr_t)flags);
    arc_release_val((int64_t)(uintptr_t)pair);

    /* 2. Decode a real host OCaml 5.5 zstd-compressed .cmi file! */
    if (cmi_path != NULL && cmi_path[0] != '\0') {
        int fd = open(cmi_path, O_RDONLY);
        assert(fd >= 0);
        int64_t ch = caml_ml_open_descriptor_in(tagged(fd));
        /* Skip 12-byte CMI magic ("Caml1999I037"). */
        char magic[13];
        for (int i = 0; i < 12; i++) {
            int64_t c = caml_ml_input_char(ch);
            assert(!ocamlcc_get_exn());
            magic[i] = (char)(c >> 1);
        }
        magic[12] = '\0';
        assert(strncmp(magic, "Caml1999I", 9) == 0);

        /* First marshaled value in a .cmi is (cmi_name, cmi_sign). */
        int64_t name_sign = caml_input_value(ch);
        assert(!ocamlcc_get_exn());
        assert((name_sign & 1) == 0);
        int64_t *ns = (int64_t *)(uintptr_t)name_sign;
        const char *modname = (const char *)(uintptr_t)ns[0];
        const ArcHeader *mh = (const ArcHeader *)modname - 1;
        assert(mh->tag == ARC_TAG_STRING && mh->reserved > 0u);
        /* Second marshaled value is cmi_crcs, third is cmi_flags. */
        int64_t crcs = caml_input_value(ch);
        assert(!ocamlcc_get_exn());
        int64_t cflags = caml_input_value(ch);
        assert(!ocamlcc_get_exn());

        arc_release_val(cflags);
        arc_release_val(crcs);
        arc_release_val(name_sign);
        caml_ml_close_channel(ch);
        arc_release_val(ch);
    }

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

int main(int argc, char **argv)
{
    const char *cmi = (argc > 1) ? argv[1] : NULL;
    test_zstd_roundtrip_and_host_cmi(cmi);
    test_compiler_os_stubs();
    puts("compiler_stubs_test: PASS");
    return 0;
}
