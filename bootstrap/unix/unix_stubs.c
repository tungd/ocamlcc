/* POSIX C11 stubs for bootstrap/unix/unix.ml (used only by self-hosted ocamlcc). */
#define _POSIX_C_SOURCE 200809L
#include "arc.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int64_t tag_int(int64_t n) { return (int64_t)(((uint64_t)n << 1) | 1u); }

static int64_t mk_result(uint16_t tag, int64_t val)
{
    int64_t *b = (int64_t *)arc_alloc(tag, 1u, sizeof(int64_t));
    b[0] = val;
    return (int64_t)(uintptr_t)b;
}

static int64_t mk_ok(int64_t val) { return mk_result(0u, val); }
static int64_t mk_err(int err) { return mk_result(1u, tag_int((int64_t)err)); }

static int64_t mk_pair(int64_t a, int64_t b)
{
    int64_t *p = (int64_t *)arc_alloc(0u, 2u, 16u);
    p[0] = a;
    p[1] = b;
    return (int64_t)(uintptr_t)p;
}

static int cstr_valid(int64_t str_val)
{
    const char *s = (const char *)(uintptr_t)str_val;
    const ArcHeader *h = (const ArcHeader *)s - 1;
    return memchr(s, '\0', h->reserved) == NULL;
}

int64_t ocamlcc_unix_enoent(int64_t ignored)
{
    (void)ignored;
    return tag_int((int64_t)ENOENT);
}

int64_t ocamlcc_unix_error_message(int64_t err_val)
{
    const char *msg = strerror((int)(err_val >> 1));
    if (msg == NULL) msg = "Unknown error";
    size_t len = strlen(msg);
    char *out = (char *)arc_alloc_bytes(len);
    memcpy(out, msg, len);
    return (int64_t)(uintptr_t)out;
}

int64_t ocamlcc_unix_lstat(int64_t path_val)
{
    if (!cstr_valid(path_val)) return mk_err(EINVAL);
    struct stat st;
    if (lstat((const char *)(uintptr_t)path_val, &st) != 0)
        return mk_err(errno);
    int kind = 0;
    if (S_ISREG(st.st_mode)) kind = 0;
    else if (S_ISDIR(st.st_mode)) kind = 1;
    else if (S_ISCHR(st.st_mode)) kind = 2;
    else if (S_ISBLK(st.st_mode)) kind = 3;
    else if (S_ISLNK(st.st_mode)) kind = 4;
    else if (S_ISFIFO(st.st_mode)) kind = 5;
    else kind = 6;
    return mk_ok(tag_int(kind));
}

int64_t ocamlcc_unix_rmdir(int64_t path_val)
{
    if (!cstr_valid(path_val)) return mk_err(EINVAL);
    if (rmdir((const char *)(uintptr_t)path_val) != 0)
        return mk_err(errno);
    return mk_ok(1);
}

int64_t ocamlcc_unix_unlink(int64_t path_val)
{
    if (!cstr_valid(path_val)) return mk_err(EINVAL);
    if (unlink((const char *)(uintptr_t)path_val) != 0)
        return mk_err(errno);
    return mk_ok(1);
}

int64_t ocamlcc_unix_openfile(int64_t path_val, int64_t mask_val, int64_t perm_val)
{
    if (!cstr_valid(path_val)) return mk_err(EINVAL);
    int64_t m = mask_val >> 1;
    int flags = 0;
    if (m & 2) flags |= O_WRONLY;
    else if (m & 4) flags |= O_RDWR;
    else flags |= O_RDONLY;
    if (m & 8) flags |= O_CREAT;
    if (m & 16) flags |= O_TRUNC;
    if (m & 32) flags |= O_APPEND;
    if (m & 64) flags |= O_CLOEXEC;
    int fd = open((const char *)(uintptr_t)path_val, flags, (mode_t)(perm_val >> 1));
    if (fd < 0) return mk_err(errno);
    return mk_ok(tag_int((int64_t)fd));
}

int64_t ocamlcc_unix_close(int64_t fd_val)
{
    if (close((int)(fd_val >> 1)) != 0)
        return mk_err(errno);
    return mk_ok(1);
}

int64_t ocamlcc_unix_pipe(int64_t cloexec_val)
{
    int fds[2];
    if (pipe(fds) != 0)
        return mk_err(errno);
    if ((cloexec_val >> 1) != 0) {
        if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) != 0 ||
            fcntl(fds[1], F_SETFD, FD_CLOEXEC) != 0) {
            int e = errno;
            close(fds[0]);
            close(fds[1]);
            return mk_err(e);
        }
    }
    return mk_ok(mk_pair(tag_int((int64_t)fds[0]), tag_int((int64_t)fds[1])));
}

static int dup_above_2(int fd)
{
    return fcntl(fd, F_DUPFD_CLOEXEC, 3);
}

int64_t ocamlcc_unix_create_process(int64_t prog_val, int64_t args_val,
                                    int64_t in_val, int64_t out_val, int64_t err_val)
{
    if (!cstr_valid(prog_val)) return mk_err(EINVAL);
    const char *prog = (const char *)(uintptr_t)prog_val;
    const ArcHeader *ah = (const ArcHeader *)(uintptr_t)args_val - 1;
    size_t argc = ah->byte_size / sizeof(int64_t);
    const int64_t *elems = (const int64_t *)(uintptr_t)args_val;

    char **c_argv = (char **)calloc(argc + 1u, sizeof(char *));
    if (c_argv == NULL) return mk_err(ENOMEM);
    for (size_t i = 0; i < argc; i++) {
        if (!cstr_valid(elems[i])) {
            free(c_argv);
            return mk_err(EINVAL);
        }
        c_argv[i] = (char *)(uintptr_t)elems[i];
    }
    c_argv[argc] = NULL;

    int err_pipe[2];
    if (pipe(err_pipe) != 0) {
        int e = errno;
        free(c_argv);
        return mk_err(e);
    }
    if (fcntl(err_pipe[0], F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(err_pipe[1], F_SETFD, FD_CLOEXEC) != 0) {
        int e = errno;
        close(err_pipe[0]);
        close(err_pipe[1]);
        free(c_argv);
        return mk_err(e);
    }

    int fd_in = (int)(in_val >> 1);
    int fd_out = (int)(out_val >> 1);
    int fd_err = (int)(err_val >> 1);

    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        close(err_pipe[0]);
        close(err_pipe[1]);
        free(c_argv);
        return mk_err(e);
    }
    if (pid == 0) {
        close(err_pipe[0]);
        int ep = err_pipe[1];
        if (ep <= 2) {
            int nep = dup_above_2(ep);
            if (nep < 0) _exit(127);
            close(ep);
            ep = nep;
        }
        int ti = dup_above_2(fd_in);
        int to = dup_above_2(fd_out);
        int te = dup_above_2(fd_err);
        if (ti < 0 || to < 0 || te < 0 ||
            dup2(ti, 0) < 0 || dup2(to, 1) < 0 || dup2(te, 2) < 0) {
            int e = errno;
            (void)write(ep, &e, sizeof(e));
            _exit(127);
        }
        close(ti);
        close(to);
        close(te);
        execvp(prog, c_argv);
        int e = errno;
        (void)write(ep, &e, sizeof(e));
        _exit(127);
    }

    free(c_argv);
    close(err_pipe[1]);
    int child_err = 0;
    ssize_t n;
    do {
        n = read(err_pipe[0], &child_err, sizeof(child_err));
    } while (n < 0 && errno == EINTR);
    close(err_pipe[0]);

    if (n == (ssize_t)sizeof(child_err)) {
        int st = 0;
        while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
        return mk_err(child_err);
    }
    return mk_ok(tag_int((int64_t)pid));
}

int64_t ocamlcc_unix_waitpid(int64_t pid_val)
{
    int status = 0;
    pid_t r;
    do {
        r = waitpid((pid_t)(pid_val >> 1), &status, 0);
    } while (r < 0 && errno == EINTR);
    if (r < 0)
        return mk_err(errno);
    int kind = 0, code = 0;
    if (WIFEXITED(status)) {
        kind = 0;
        code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        kind = 1;
        code = WTERMSIG(status);
    } else if (WIFSTOPPED(status)) {
        kind = 2;
        code = WSTOPSIG(status);
    }
    int64_t st_pair = mk_pair(tag_int(kind), tag_int(code));
    return mk_ok(mk_pair(tag_int((int64_t)r), st_pair));
}
