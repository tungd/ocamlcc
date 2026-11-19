/* ARC ABI adapter for the small Unix surface used by ocaml-crunch. */
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#include "arc.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

static int64_t text(const char *s)
{
    size_t len = strlen(s);
    char *out = arc_alloc_bytes(len);
    memcpy(out, s, len);
    return (int64_t)(uintptr_t)out;
}

static int64_t result(unsigned tag, int64_t value)
{
    int64_t *out = arc_alloc((uint16_t)tag, 1, sizeof(int64_t));
    out[0] = value;
    return (int64_t)(uintptr_t)out;
}

static int path_valid(int64_t path)
{
    const char *s = (const char *)(uintptr_t)path;
    const ArcHeader *header = (const ArcHeader *)s - 1;
    return memchr(s, '\0', header->reserved) == NULL;
}

int64_t ocpkg_realpath(int64_t path)
{
    if (!path_valid(path)) return result(1, text("realpath: NUL in path"));
    char *resolved = realpath((const char *)(uintptr_t)path, NULL);
    if (!resolved) return result(1, text(strerror(errno)));
    int64_t value = text(resolved);
    free(resolved);
    return result(0, value);
}

int64_t ocpkg_file_size(int64_t path)
{
    if (!path_valid(path)) return result(1, text("stat: NUL in path"));
    struct stat s;
    if (stat((const char *)(uintptr_t)path, &s)) return result(1, text(strerror(errno)));
    if (s.st_size < 0 || (uint64_t)s.st_size > (UINT64_C(1) << 62) - 1)
        return result(1, text("stat: size outside OCaml int range"));
    return result(0, (int64_t)(((uint64_t)s.st_size << 1) | 1));
}

int64_t ocpkg_time(int64_t unit)
{
    (void)unit;
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts)) return result(1, text(strerror(errno)));
    return result(0, ocamlcc_alloc_float((double)ts.tv_sec + (double)ts.tv_nsec / 1e9));
}
