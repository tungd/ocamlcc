/* builtins.c — C entry points the code generator emits calls to. */
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

/* Format a double according to a single Printf conversion specifier (e.g.
   "%+.2f", "%.12g"). Rejects embedded NULs / multiple specifiers. Returns the
   written length, or -1 if malformed/overflowed. */
int ocamlcc_snprintf_double(char *out, size_t cap, const char *fmt, size_t fmt_len,
                            double d)
{
    if (fmt_len == 0 || fmt_len >= 64u)
        return -1;
    char safe_fmt[64];
    for (size_t i = 0; i < fmt_len; i++) {
        if (fmt[i] == '\0')
            return -1;
        safe_fmt[i] = fmt[i];
    }
    safe_fmt[fmt_len] = '\0';
    int n = snprintf(out, cap, safe_fmt, d);
    if (n < 0 || (size_t)n >= cap)
        return -1;
    return n;
}

/* Format a signed or unsigned 64-bit integer with a Printf conversion string
   whose final character is one of d/i/u/x/X/o (normalizing any l/ll/L/n
   prefix to %ll...). */
int ocamlcc_snprintf_i64(char *out, size_t cap, const char *fmt, size_t fmt_len,
                         int64_t v, int is_i32)
{
    if (fmt_len < 2 || fmt_len >= 64u || fmt[0] != '%')
        return -1;
    char spec = fmt[fmt_len - 1u];
    char safe_fmt[68];
    size_t k = 0;
    for (size_t i = 0; i + 1u < fmt_len; i++) {
        char c = fmt[i];
        if (c == '\0')
            return -1;
        if (c == 'l' || c == 'L' || c == 'n')
            continue;
        safe_fmt[k++] = c;
        if (k >= 60u)
            return -1;
    }
    if (is_i32) {
        safe_fmt[k++] = spec;
        safe_fmt[k] = '\0';
        int n = snprintf(out, cap, safe_fmt, (int32_t)v);
        return (n < 0 || (size_t)n >= cap) ? -1 : n;
    } else {
        safe_fmt[k++] = 'l';
        safe_fmt[k++] = 'l';
        safe_fmt[k++] = spec;
        safe_fmt[k] = '\0';
        int n = snprintf(out, cap, safe_fmt, (long long)v);
        return (n < 0 || (size_t)n >= cap) ? -1 : n;
    }
}

int ocamlcc_parse_double(const char *s, size_t len, double *out)
{
    if (len == 0 || len > 512u)
        return 0;
    size_t start = 0;
    while (start < len && isspace((unsigned char)s[start]))
        start++;
    size_t end = len;
    while (end > start && isspace((unsigned char)s[end - 1u]))
        end--;
    if (start >= end)
        return 0;
    char buf[520];
    size_t k = 0;
    for (size_t i = start; i < end; i++) {
        char c = s[i];
        if (c == '\0')
            return 0;
        if (c == '_') {
            if (k == 0)
                return 0;
            continue;
        }
        buf[k++] = c;
    }
    buf[k] = '\0';
    errno = 0;
    char *ep = NULL;
    double d = strtod(buf, &ep);
    if (ep != buf + k)
        return 0;
    *out = d;
    return 1;
}

int ocamlcc_parse_i64(const char *s, size_t len, int is_i32, int64_t *out)
{
    if (len == 0 || len > 128u)
        return 0;
    char buf[132];
    size_t i = 0;
    int neg = 0;
    if (s[i] == '-') {
        neg = 1;
        i++;
    } else if (s[i] == '+') {
        i++;
    }
    if (i >= len)
        return 0;
    int base = 10;
    int unsigned_mode = 0;
    if (s[i] == '0' && i + 1u < len) {
        char p = s[i + 1u];
        if (p == 'x' || p == 'X') {
            base = 16;
            unsigned_mode = 1;
            i += 2u;
        } else if (p == 'o' || p == 'O') {
            base = 8;
            unsigned_mode = 1;
            i += 2u;
        } else if (p == 'b' || p == 'B') {
            base = 2;
            unsigned_mode = 1;
            i += 2u;
        } else if (p == 'u' || p == 'U') {
            base = 10;
            unsigned_mode = 1;
            i += 2u;
        }
    }
    size_t k = 0;
    int seen = 0;
    for (; i < len; i++) {
        char c = s[i];
        if (c == '\0')
            return 0;
        if (c == '_') {
            if (!seen)
                return 0;
            continue;
        }
        seen = 1;
        buf[k++] = c;
    }
    if (!seen)
        return 0;
    buf[k] = '\0';
    errno = 0;
    char *ep = NULL;
    unsigned long long uv = strtoull(buf, &ep, base);
    if (ep != buf + k || errno == ERANGE)
        return 0;
    if (is_i32) {
        if (unsigned_mode) {
            if (uv > (unsigned long long)UINT32_MAX)
                return 0;
            int32_t sv = (int32_t)(uint32_t)uv;
            if (neg)
                sv = (int32_t)(-(uint32_t)sv);
            *out = (int64_t)sv;
        } else {
            uint64_t limit = neg ? ((uint64_t)INT32_MAX + 1ULL) : (uint64_t)INT32_MAX;
            if (uv > limit)
                return 0;
            int32_t sv = neg ? (int32_t)(-(int64_t)uv) : (int32_t)uv;
            *out = (int64_t)sv;
        }
    } else {
        if (!unsigned_mode) {
            uint64_t limit = neg ? ((uint64_t)INT64_MAX + 1ULL) : (uint64_t)INT64_MAX;
            if (uv > limit)
                return 0;
            *out = neg ? (int64_t)(0ULL - uv) : (int64_t)uv;
        } else {
            *out = neg ? (int64_t)(0ULL - uv) : (int64_t)uv;
        }
    }
    return 1;
}

double ocamlcc_c_sqrt(double d) { return sqrt(d); }
double ocamlcc_c_floor(double d) { return floor(d); }
double ocamlcc_c_ceil(double d) { return ceil(d); }
double ocamlcc_c_fmod(double a, double b) { return fmod(a, b); }
double ocamlcc_c_copysign(double a, double b) { return copysign(a, b); }
int    ocamlcc_c_fpclassify(double d)
{
    switch (fpclassify(d)) {
    case FP_NORMAL:    return 0;
    case FP_SUBNORMAL: return 1;
    case FP_ZERO:      return 2;
    case FP_INFINITE:  return 3;
    default:           return 4; /* FP_NAN */
    }
}
