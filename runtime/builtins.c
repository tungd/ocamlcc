/* builtins.c — C entry points the code generator emits calls to. */
#if defined(__linux__) && !defined(_DEFAULT_SOURCE)
#define _DEFAULT_SOURCE 1
#endif

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#elif defined(__linux__)
#include <sys/random.h>
#endif

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

enum { NUMERIC_FORMAT_CAP = 64 };

/* Parse the common prefix: percent, flags, width, and optional precision.
   The caller must validate the remaining length modifier and conversion. */
static size_t numeric_format_prefix(const char *fmt, size_t len)
{
    if (len < 2 || len >= NUMERIC_FORMAT_CAP || fmt[0] != '%')
        return 0;
    size_t end = len - 1;
    size_t i = 1;
    while (i < end && fmt[i] != '\0' && strchr("-+#0 ", fmt[i]) != NULL)
        i++;
    while (i < end && fmt[i] >= '0' && fmt[i] <= '9')
        i++;
    if (i < end && fmt[i] == '.') {
        i++;
        while (i < end && fmt[i] >= '0' && fmt[i] <= '9')
            i++;
    }
    return i;
}

/* Format a double with one floating-point conversion. Return the written
   length, or -1 for an invalid format or insufficient output space. */
int ocamlcc_snprintf_double(char *out, size_t cap, const char *fmt, size_t fmt_len,
                            double d)
{
    size_t i = numeric_format_prefix(fmt, fmt_len);
    if (i == 0 || i != fmt_len - 1 || fmt[i] == '\0' ||
        strchr("fFeEgGaA", fmt[i]) == NULL)
        return -1;
    char safe_fmt[NUMERIC_FORMAT_CAP];
    memcpy(safe_fmt, fmt, fmt_len);
    safe_fmt[fmt_len] = '\0';
    int n = snprintf(out, cap, safe_fmt, d);
    if (n < 0 || (size_t)n >= cap)
        return -1;
    return n;
}

/* Format an integer with one numeric conversion. Normalize the optional
   OCaml length modifier (l, ll, L, n) to the argument's C width. */
int ocamlcc_snprintf_i64(char *out, size_t cap, const char *fmt, size_t fmt_len,
                         int64_t v, int is_i32)
{
    size_t prefix_len = numeric_format_prefix(fmt, fmt_len);
    if (prefix_len == 0)
        return -1;
    size_t end = fmt_len - 1;
    size_t i = prefix_len;
    if (i < end) {
        char modifier = fmt[i++];
        if (modifier != 'l' && modifier != 'L' && modifier != 'n')
            return -1;
        if (modifier == 'l' && i < end && fmt[i] == 'l')
            i++;
    }
    char spec = fmt[end];
    if (i != end || spec == '\0' || strchr("diuxXo", spec) == NULL)
        return -1;

    char safe_fmt[NUMERIC_FORMAT_CAP + 2];
    memcpy(safe_fmt, fmt, prefix_len);
    size_t k = prefix_len;
    if (!is_i32) {
        safe_fmt[k++] = 'l';
        safe_fmt[k++] = 'l';
    }
    safe_fmt[k++] = spec;
    safe_fmt[k] = '\0';

    int is_signed = spec == 'd' || spec == 'i';
    int n;
    if (is_i32) {
        n = is_signed ? snprintf(out, cap, safe_fmt, (int)(int32_t)v)
                      : snprintf(out, cap, safe_fmt, (unsigned int)(uint32_t)v);
    } else {
        n = is_signed ? snprintf(out, cap, safe_fmt, (long long)v)
                      : snprintf(out, cap, safe_fmt, (unsigned long long)v);
    }
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
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

int ocamlcc_c_int_of_string(const char *s, size_t len, int64_t *out)
{
    int64_t v = 0;
    if (!ocamlcc_parse_i64(s, len, 0, &v))
        return 0;
    size_t i = 0;
    if (i < len && (s[i] == '-' || s[i] == '+'))
        i++;
    int unsigned_mode = 0;
    if (i + 1u < len && s[i] == '0') {
        char p = s[i + 1u];
        if (p == 'x' || p == 'X' || p == 'o' || p == 'O' ||
            p == 'b' || p == 'B' || p == 'u' || p == 'U')
            unsigned_mode = 1;
    }
    const int64_t i63_min = -(1LL << 62);
    const int64_t i63_max = (1LL << 62) - 1LL;
    if (!unsigned_mode) {
        if (v < i63_min || v > i63_max)
            return 0;
        *out = v;
        return 1;
    }
    /* Unsigned literals up to 2^63 - 1 are accepted in 63-bit OCaml and
       truncated to 63 bits with sign extension from bit 62. */
    if (v < 0)
        return 0;
    *out = (int64_t)((uint64_t)v << 1) >> 1;
    return 1;
}

/* open_flag bitmasks passed from runtime/arc.c:
 * 0x01=RD, 0x02=WR, 0x04=APPEND, 0x08=CREAT, 0x10=TRUNC, 0x20=EXCL, 0x40=NONBLOCK */
int ocamlcc_c_sys_open(const char *path, int flags_mask, int perm, int *err_out)
{
    int oflags = 0;
    if ((flags_mask & 0x03) == 0x03)
        oflags |= O_RDWR;
    else if (flags_mask & 0x02)
        oflags |= O_WRONLY;
    else
        oflags |= O_RDONLY;
    if (flags_mask & 0x04) oflags |= O_APPEND;
    if (flags_mask & 0x08) oflags |= O_CREAT;
    if (flags_mask & 0x10) oflags |= O_TRUNC;
    if (flags_mask & 0x20) oflags |= O_EXCL;
    if (flags_mask & 0x40) oflags |= O_NONBLOCK;
    int fd;
    do {
        fd = open(path, oflags, (mode_t)perm);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        *err_out = errno;
        return -1;
    }
    *err_out = 0;
    return fd;
}

int64_t ocamlcc_c_fd_read_raw(int fd, void *buf, size_t len, int *err_out)
{
    if (len == 0) {
        *err_out = 0;
        return 0;
    }
    ssize_t r;
    do {
        r = read(fd, buf, len);
    } while (r < 0 && errno == EINTR);
    if (r < 0) {
        *err_out = errno;
        return -1;
    }
    *err_out = 0;
    return (int64_t)r;
}

int ocamlcc_c_fd_write_all(int fd, const void *buf, size_t len, int *err_out)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t rem = len;
    while (rem > 0) {
        ssize_t w = write(fd, p, rem);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            *err_out = errno;
            return -1;
        }
        p += (size_t)w;
        rem -= (size_t)w;
    }
    *err_out = 0;
    return 0;
}

int ocamlcc_c_fd_lseek(int fd, int64_t off, int whence, int64_t *pos_out, int *err_out)
{
    int w = (whence == 1) ? SEEK_CUR : (whence == 2 ? SEEK_END : SEEK_SET);
    off_t p = lseek(fd, (off_t)off, w);
    if (p == (off_t)-1) {
        *err_out = errno;
        return -1;
    }
    *pos_out = (int64_t)p;
    *err_out = 0;
    return 0;
}

int ocamlcc_c_fd_size(int fd, int64_t *size_out, int *err_out)
{
    struct stat st;
    if (fstat(fd, &st) != 0) {
        *err_out = errno;
        return -1;
    }
    *size_out = (int64_t)st.st_size;
    *err_out = 0;
    return 0;
}

int ocamlcc_c_fd_close_raw(int fd, int *err_out)
{
    if (close(fd) != 0) {
        *err_out = errno;
        return -1;
    }
    *err_out = 0;
    return 0;
}

void ocamlcc_c_fflush_stdio(int fd)
{
    if (fd == 1)
        fflush(stdout);
    else if (fd == 2)
        fflush(stderr);
}

const char *ocamlcc_c_strerror(int err)
{
    return strerror(err);
}

int ocamlcc_c_hexstring_of_float(char *out, size_t cap, double d, int64_t prec, char sign)
{
    int n;
    if (prec < 0) {
        const char *fmt = (sign == '+') ? "%+a" : (sign == ' ' ? "% a" : "%a");
        n = snprintf(out, cap, fmt, d);
    } else {
        const char *fmt = (sign == '+') ? "%+.*a" : (sign == ' ' ? "% .*a" : "%.*a");
        n = snprintf(out, cap, fmt, (int)prec, d);
    }
    if (n < 0 || (size_t)n >= cap)
        return -1;
    return n;
}

/* ---- Sys / POSIX helpers ---- */

int ocamlcc_c_file_exists(const char *path)
{
    return access(path, F_OK) == 0 ? 1 : 0;
}

int ocamlcc_c_stat_kind(const char *path, int *is_dir, int *is_reg, int *err_out)
{
    struct stat st;
    if (stat(path, &st) != 0) {
        *err_out = errno;
        return -1;
    }
    *is_dir = S_ISDIR(st.st_mode) ? 1 : 0;
    *is_reg = S_ISREG(st.st_mode) ? 1 : 0;
    *err_out = 0;
    return 0;
}

int ocamlcc_c_unlink(const char *path, int *err_out)
{
    if (unlink(path) != 0) { *err_out = errno; return -1; }
    *err_out = 0;
    return 0;
}

int ocamlcc_c_rename(const char *oldp, const char *newp, int *err_out)
{
    if (rename(oldp, newp) != 0) { *err_out = errno; return -1; }
    *err_out = 0;
    return 0;
}

int ocamlcc_c_chdir(const char *path, int *err_out)
{
    if (chdir(path) != 0) { *err_out = errno; return -1; }
    *err_out = 0;
    return 0;
}

int ocamlcc_c_mkdir(const char *path, int mode, int *err_out)
{
    if (mkdir(path, (mode_t)mode) != 0) { *err_out = errno; return -1; }
    *err_out = 0;
    return 0;
}

int ocamlcc_c_rmdir(const char *path, int *err_out)
{
    if (rmdir(path) != 0) { *err_out = errno; return -1; }
    *err_out = 0;
    return 0;
}

char *ocamlcc_c_getcwd(int *err_out)
{
    char *p = getcwd(NULL, 0);
    if (p == NULL) {
        *err_out = errno;
        return NULL;
    }
    *err_out = 0;
    return p;
}

const char *ocamlcc_c_getenv(const char *name) { return getenv(name); }

int ocamlcc_c_system(const char *cmd, int *err_out)
{
#if defined(__APPLE__) && defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
    (void)cmd;
    *err_out = ENOSYS;
    return -1;
#else
    int rc = system(cmd);
    if (rc == -1) {
        *err_out = errno;
        return -1;
    }
    *err_out = 0;
#ifdef WIFEXITED
    if (WIFEXITED(rc))
        return WEXITSTATUS(rc);
    if (WIFSIGNALED(rc))
        return 128 + WTERMSIG(rc);
#endif
    return rc;
#endif
}

double ocamlcc_c_sys_time(void)
{
    return (double)clock() / (double)CLOCKS_PER_SEC;
}

int ocamlcc_c_isatty(int fd) { return isatty(fd) ? 1 : 0; }

int ocamlcc_c_readdir_alloc(const char *path, char ***out_names, size_t *out_cnt, int *err_out)
{
    DIR *d = opendir(path);
    if (d == NULL) {
        *err_out = errno;
        return -1;
    }
    size_t cap = 16u, n = 0u;
    char **names = (char **)malloc(cap * sizeof(char *));
    if (names == NULL) {
        closedir(d);
        *err_out = ENOMEM;
        return -1;
    }
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0)
            continue;
        if (n == cap) {
            cap *= 2u;
            char **nn = (char **)realloc(names, cap * sizeof(char *));
            if (nn == NULL) {
                for (size_t i = 0; i < n; i++) free(names[i]);
                free(names);
                closedir(d);
                *err_out = ENOMEM;
                return -1;
            }
            names = nn;
        }
        size_t l = strlen(ent->d_name);
        char *copy = (char *)malloc(l + 1u);
        if (copy == NULL) {
            for (size_t i = 0; i < n; i++) free(names[i]);
            free(names);
            closedir(d);
            *err_out = ENOMEM;
            return -1;
        }
        memcpy(copy, ent->d_name, l + 1u);
        names[n++] = copy;
    }
    closedir(d);
    *out_names = names;
    *out_cnt = n;
    *err_out = 0;
    return 0;
}

void ocamlcc_c_readdir_free(char **names, size_t cnt)
{
    for (size_t i = 0; i < cnt; i++)
        free(names[i]);
    free(names);
}

void ocamlcc_c_free(void *p) { free(p); }

/* ---- libm wrappers ---- */

double ocamlcc_c_exp(double d) { return exp(d); }
double ocamlcc_c_exp2(double d) { return exp2(d); }
double ocamlcc_c_expm1(double d) { return expm1(d); }
double ocamlcc_c_log(double d) { return log(d); }
double ocamlcc_c_log10(double d) { return log10(d); }
double ocamlcc_c_log2(double d) { return log2(d); }
double ocamlcc_c_log1p(double d) { return log1p(d); }
double ocamlcc_c_pow(double a, double b) { return pow(a, b); }
double ocamlcc_c_sin(double d) { return sin(d); }
double ocamlcc_c_cos(double d) { return cos(d); }
double ocamlcc_c_tan(double d) { return tan(d); }
double ocamlcc_c_asin(double d) { return asin(d); }
double ocamlcc_c_acos(double d) { return acos(d); }
double ocamlcc_c_atan(double d) { return atan(d); }
double ocamlcc_c_atan2(double a, double b) { return atan2(a, b); }
double ocamlcc_c_sinh(double d) { return sinh(d); }
double ocamlcc_c_cosh(double d) { return cosh(d); }
double ocamlcc_c_tanh(double d) { return tanh(d); }
double ocamlcc_c_asinh(double d) { return asinh(d); }
double ocamlcc_c_acosh(double d) { return acosh(d); }
double ocamlcc_c_atanh(double d) { return atanh(d); }
double ocamlcc_c_cbrt(double d) { return cbrt(d); }
double ocamlcc_c_hypot(double a, double b) { return hypot(a, b); }
double ocamlcc_c_fma(double a, double b, double c) { return fma(a, b, c); }
double ocamlcc_c_erf(double d) { return erf(d); }
double ocamlcc_c_erfc(double d) { return erfc(d); }
double ocamlcc_c_trunc(double d) { return trunc(d); }
double ocamlcc_c_round(double d) { return round(d); }
int    ocamlcc_c_signbit(double d) { return signbit(d) ? 1 : 0; }
double ocamlcc_c_nextafter(double a, double b) { return nextafter(a, b); }
double ocamlcc_c_frexp(double d, int *exp_out) { return frexp(d, exp_out); }
double ocamlcc_c_ldexp(double d, int exp_v) { return ldexp(d, exp_v); }
double ocamlcc_c_modf(double d, double *iptr_out) { return modf(d, iptr_out); }

/* ---- POSIX mutex / condition ---- */

void *ocamlcc_c_mutex_new(void)
{
    pthread_mutex_t *m = (pthread_mutex_t *)malloc(sizeof(pthread_mutex_t));
    if (m == NULL) return NULL;
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_ERRORCHECK);
    if (pthread_mutex_init(m, &attr) != 0) {
        pthread_mutexattr_destroy(&attr);
        free(m);
        return NULL;
    }
    pthread_mutexattr_destroy(&attr);
    return m;
}

int ocamlcc_c_mutex_lock(void *p) { return pthread_mutex_lock((pthread_mutex_t *)p); }
int ocamlcc_c_mutex_trylock(void *p) { return pthread_mutex_trylock((pthread_mutex_t *)p); }
int ocamlcc_c_mutex_unlock(void *p) { return pthread_mutex_unlock((pthread_mutex_t *)p); }
void ocamlcc_c_mutex_free(void *p)
{
    if (p != NULL) {
        pthread_mutex_destroy((pthread_mutex_t *)p);
        free(p);
    }
}

void *ocamlcc_c_cond_new(void)
{
    pthread_cond_t *c = (pthread_cond_t *)malloc(sizeof(pthread_cond_t));
    if (c == NULL) return NULL;
    if (pthread_cond_init(c, NULL) != 0) {
        free(c);
        return NULL;
    }
    return c;
}

int ocamlcc_c_cond_wait(void *c, void *m)
{
    return pthread_cond_wait((pthread_cond_t *)c, (pthread_mutex_t *)m);
}
int ocamlcc_c_cond_signal(void *c) { return pthread_cond_signal((pthread_cond_t *)c); }
int ocamlcc_c_cond_broadcast(void *c) { return pthread_cond_broadcast((pthread_cond_t *)c); }
void ocamlcc_c_cond_free(void *c)
{
    if (c != NULL) {
        pthread_cond_destroy((pthread_cond_t *)c);
        free(c);
    }
}

/* ---- Digest: MD5 (RFC 1321) & BLAKE2b (RFC 7693) ---- */

typedef struct {
    uint32_t state[4];
    uint64_t count;
    uint8_t  buf[64];
} OcamlccMD5;

static inline uint32_t md5_rotl(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }

static void md5_transform(uint32_t s[4], const uint8_t blk[64])
{
    static const uint32_t K[64] = {
        0xd76aa478u,0xe8c7b756u,0x242070dbu,0xc1bdceeeu,0xf57c0fafu,0x4787c62au,0xa8304613u,0xfd469501u,
        0x698098d8u,0x8b44f7afu,0xffff5bb1u,0x895cd7beu,0x6b901122u,0xfd987193u,0xa679438eu,0x49b40821u,
        0xf61e2562u,0xc040b340u,0x265e5a51u,0xe9b6c7aau,0xd62f105du,0x02441453u,0xd8a1e681u,0xe7d3fbc8u,
        0x21e1cde6u,0xc33707d6u,0xf4d50d87u,0x455a14edu,0xa9e3e905u,0xfcefa3f8u,0x676f02d9u,0x8d2a4c8au,
        0xfffa3942u,0x8771f681u,0x6d9d6122u,0xfde5380cu,0xa4beea44u,0x4bdecfa9u,0xf6bb4b60u,0xbebfbc70u,
        0x289b7ec6u,0xeaa127fau,0xd4ef3085u,0x04881d05u,0xd9d4d039u,0xe6db99e5u,0x1fa27cf8u,0xc4ac5665u,
        0xf4292244u,0x432aff97u,0xab9423a7u,0xfc93a039u,0x655b59c3u,0x8f0ccc92u,0xffeff47du,0x85845dd1u,
        0x6fa87e4fu,0xfe2ce6e0u,0xa3014314u,0x4e0811a1u,0xf7537e82u,0xbd3af235u,0x2ad7d2bbu,0xeb86d391u
    };
    static const int R[64] = {
        7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22,
        5, 9,14,20,5, 9,14,20,5, 9,14,20,5, 9,14,20,
        4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23,
        6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21
    };
    uint32_t m[16];
    for (int i = 0; i < 16; i++)
        memcpy(&m[i], blk + i * 4, 4u);
    uint32_t a = s[0], b = s[1], c = s[2], d = s[3];
    for (int i = 0; i < 64; i++) {
        uint32_t f, g;
        if (i < 16) { f = (b & c) | ((~b) & d); g = (uint32_t)i; }
        else if (i < 32) { f = (d & b) | ((~d) & c); g = (uint32_t)((5 * i + 1) % 16); }
        else if (i < 48) { f = b ^ c ^ d; g = (uint32_t)((3 * i + 5) % 16); }
        else { f = c ^ (b | (~d)); g = (uint32_t)((7 * i) % 16); }
        uint32_t tmp = d;
        d = c;
        c = b;
        b = b + md5_rotl(a + f + K[i] + m[g], R[i]);
        a = tmp;
    }
    s[0] += a; s[1] += b; s[2] += c; s[3] += d;
}

static void md5_init(OcamlccMD5 *ctx)
{
    ctx->state[0] = 0x67452301u;
    ctx->state[1] = 0xefcdab89u;
    ctx->state[2] = 0x98badcfeu;
    ctx->state[3] = 0x10325476u;
    ctx->count = 0u;
}

static void md5_update(OcamlccMD5 *ctx, const uint8_t *data, size_t len)
{
    size_t idx = (size_t)(ctx->count & 63u);
    ctx->count += (uint64_t)len;
    size_t i = 0u;
    if (idx > 0u && idx + len >= 64u) {
        size_t take = 64u - idx;
        memcpy(ctx->buf + idx, data, take);
        md5_transform(ctx->state, ctx->buf);
        i = take;
        idx = 0u;
    }
    while (i + 64u <= len) {
        md5_transform(ctx->state, data + i);
        i += 64u;
    }
    if (i < len)
        memcpy(ctx->buf + idx, data + i, len - i);
}

static void md5_final(OcamlccMD5 *ctx, uint8_t out[16])
{
    uint64_t bits = ctx->count * 8u;
    uint8_t pad = 0x80u;
    md5_update(ctx, &pad, 1u);
    uint8_t zero = 0u;
    while ((ctx->count & 63u) != 56u)
        md5_update(ctx, &zero, 1u);
    uint8_t len_le[8];
    memcpy(len_le, &bits, 8u);
    md5_update(ctx, len_le, 8u);
    for (int i = 0; i < 4; i++)
        memcpy(out + i * 4, &ctx->state[i], 4u);
}

void ocamlcc_c_md5_init(void *opaque_ctx)
{
    _Static_assert(sizeof(OcamlccMD5) <= 128u, "OcamlccMD5 exceeds 128 bytes");
    md5_init((OcamlccMD5 *)opaque_ctx);
}

void ocamlcc_c_md5_update(void *opaque_ctx, const uint8_t *data, size_t len)
{
    md5_update((OcamlccMD5 *)opaque_ctx, data, len);
}

void ocamlcc_c_md5_final(void *opaque_ctx, uint8_t out[16])
{
    md5_final((OcamlccMD5 *)opaque_ctx, out);
}

void ocamlcc_c_md5(const uint8_t *data, size_t len, uint8_t out[16])
{
    OcamlccMD5 ctx;
    md5_init(&ctx);
    md5_update(&ctx, data, len);
    md5_final(&ctx, out);
}

int ocamlcc_c_random_bytes(uint8_t *buf, size_t len)
{
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    arc4random_buf(buf, len);
    return 0;
#elif defined(__linux__)
    size_t off = 0;
    while (off < len) {
        ssize_t r = getrandom(buf + off, len - off, 0);
        if (r > 0) {
            off += (size_t)r;
            continue;
        }
        if (r < 0 && errno == EINTR)
            continue;
        break;
    }
    if (off == len)
        return 0;
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0) {
        while (off < len) {
            ssize_t r = read(fd, buf + off, len - off);
            if (r > 0)
                off += (size_t)r;
            else if (r < 0 && errno == EINTR)
                continue;
            else
                break;
        }
        close(fd);
    }
    return (off == len) ? 0 : -1;
#else
    (void)buf;
    (void)len;
    return -1;
#endif
}

typedef struct {
    uint64_t h[8];
    uint64_t t[2];
    uint8_t  buf[128];
    size_t   buflen;
    size_t   outlen;
} OcamlccBlake2b;

static inline uint64_t b2_rotr(uint64_t x, int n) { return (x >> n) | (x << (64 - n)); }

static void b2_compress(OcamlccBlake2b *S, int is_last)
{
    static const uint64_t IV[8] = {
        0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
        0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
        0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
        0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL
    };
    static const uint8_t SIGMA[12][16] = {
        {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
        {14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3},
        {11,8,12,0,5,2,15,13,10,14,3,6,7,1,9,4},
        {7,9,3,1,13,12,11,14,2,6,5,10,4,0,15,8},
        {9,0,5,7,2,4,10,15,14,1,11,12,6,8,3,13},
        {2,12,6,10,0,11,8,3,4,13,7,5,15,14,1,9},
        {12,5,1,15,14,13,4,10,0,7,6,3,9,2,8,11},
        {13,11,7,14,12,1,3,9,5,0,15,4,8,6,2,10},
        {6,15,14,9,11,3,0,8,12,2,13,7,1,4,10,5},
        {10,2,8,4,7,6,1,5,15,11,9,14,3,12,13,0},
        {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
        {14,10,4,8,9,15,13,6,1,12,0,2,11,7,5,3}
    };
    uint64_t m[16], v[16];
    for (int i = 0; i < 16; i++)
        memcpy(&m[i], S->buf + i * 8, 8u);
    for (int i = 0; i < 8; i++) {
        v[i] = S->h[i];
        v[i + 8] = IV[i];
    }
    v[12] ^= S->t[0];
    v[13] ^= S->t[1];
    if (is_last)
        v[14] = ~v[14];
#define B2_G(r, i, a, b, c, d)                                       \
    do {                                                             \
        a = a + b + m[SIGMA[r][2 * (i)]];                            \
        d = b2_rotr(d ^ a, 32);                                      \
        c = c + d;                                                   \
        b = b2_rotr(b ^ c, 24);                                      \
        a = a + b + m[SIGMA[r][2 * (i) + 1]];                        \
        d = b2_rotr(d ^ a, 16);                                      \
        c = c + d;                                                   \
        b = b2_rotr(b ^ c, 63);                                      \
    } while (0)
    for (int r = 0; r < 12; r++) {
        B2_G(r, 0, v[0], v[4], v[8],  v[12]);
        B2_G(r, 1, v[1], v[5], v[9],  v[13]);
        B2_G(r, 2, v[2], v[6], v[10], v[14]);
        B2_G(r, 3, v[3], v[7], v[11], v[15]);
        B2_G(r, 4, v[0], v[5], v[10], v[15]);
        B2_G(r, 5, v[1], v[6], v[11], v[12]);
        B2_G(r, 6, v[2], v[7], v[8],  v[13]);
        B2_G(r, 7, v[3], v[4], v[9],  v[14]);
    }
#undef B2_G
    for (int i = 0; i < 8; i++)
        S->h[i] ^= v[i] ^ v[i + 8];
}

void *ocamlcc_c_blake2_new(size_t outlen, const uint8_t *key, size_t keylen)
{
    static const uint64_t IV[8] = {
        0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL,
        0x3c6ef372fe94f82bULL, 0xa54ff53a5f1d36f1ULL,
        0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
        0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL
    };
    OcamlccBlake2b *S = (OcamlccBlake2b *)calloc(1u, sizeof(OcamlccBlake2b));
    if (S == NULL) return NULL;
    for (int i = 0; i < 8; i++) S->h[i] = IV[i];
    S->h[0] ^= 0x01010000ULL ^ ((uint64_t)keylen << 8) ^ (uint64_t)outlen;
    S->outlen = outlen;
    if (keylen > 0u) {
        memcpy(S->buf, key, keylen);
        S->buflen = 128u;
    }
    return S;
}

void ocamlcc_c_blake2_update(void *p, const uint8_t *in, size_t inlen)
{
    OcamlccBlake2b *S = (OcamlccBlake2b *)p;
    if (inlen == 0u) return;
    size_t left = S->buflen;
    size_t fill = 128u - left;
    if (inlen > fill) {
        memcpy(S->buf + left, in, fill);
        S->t[0] += 128u;
        if (S->t[0] < 128u) S->t[1]++;
        b2_compress(S, 0);
        in += fill;
        inlen -= fill;
        S->buflen = 0u;
        while (inlen > 128u) {
            memcpy(S->buf, in, 128u);
            S->t[0] += 128u;
            if (S->t[0] < 128u) S->t[1]++;
            b2_compress(S, 0);
            in += 128u;
            inlen -= 128u;
        }
        left = 0u;
    }
    memcpy(S->buf + left, in, inlen);
    S->buflen = left + inlen;
}

void ocamlcc_c_blake2_final(void *p, size_t outlen, uint8_t *out)
{
    OcamlccBlake2b *S = (OcamlccBlake2b *)p;
    S->t[0] += (uint64_t)S->buflen;
    if (S->t[0] < (uint64_t)S->buflen) S->t[1]++;
    if (S->buflen < 128u)
        memset(S->buf + S->buflen, 0, 128u - S->buflen);
    b2_compress(S, 1);
    uint8_t tmp[64];
    for (int i = 0; i < 8; i++)
        memcpy(tmp + i * 8, &S->h[i], 8u);
    memcpy(out, tmp, outlen);
}

void ocamlcc_c_blake2_free(void *p) { free(p); }
