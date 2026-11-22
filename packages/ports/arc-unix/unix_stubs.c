#define _GNU_SOURCE
#include "arc.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <string.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

typedef int64_t value;

static value integer(int64_t n) { return (value)(((uint64_t)n << 1) | 1); }
static int number(value v) { return (int)(v >> 1); }

static value boxed(unsigned tag, value field)
{
    value *box = arc_alloc(tag, 1, sizeof *box);
    *box = field;
    return (value)(uintptr_t)box;
}

static value tuple(value first, value second)
{
    value *pair = arc_alloc(0, 2, 2 * sizeof *pair);
    pair[0] = first;
    pair[1] = second;
    return (value)(uintptr_t)pair;
}

static value text(const char *str)
{
    size_t length = strlen(str);
    char *buffer = arc_alloc_bytes(length);
    memcpy(buffer, str, length);
    return (value)(uintptr_t)buffer;
}

value arc_unix_errno(value name)
{
    const char *symbol = (const char *)(uintptr_t)name;
#define CHECK(code) if (!strcmp(symbol, #code)) return integer(code)
    CHECK(EACCES); CHECK(EAGAIN); CHECK(EBADF); CHECK(ECHILD); CHECK(EINTR);
    CHECK(EINVAL); CHECK(EIO); CHECK(EMFILE); CHECK(ENFILE); CHECK(ENOENT);
    CHECK(ENOMEM); CHECK(ENOSYS); CHECK(EPERM); CHECK(EPIPE); CHECK(ESRCH);
    CHECK(ETIMEDOUT); CHECK(EWOULDBLOCK);
#undef CHECK
    return integer(-1);
}

value arc_unix_error_message(value error)
{
    char buffer[256];
#if defined(__GLIBC__)
    const char *message = strerror_r(number(error), buffer, sizeof buffer);
#else
    const char *message = strerror_r(number(error), buffer, sizeof buffer) == 0
        ? buffer : "Unknown system error";
#endif
    return text(message);
}

value arc_unix_pipe(value cloexec)
{
    int fds[2];
#ifdef __linux__
    if (pipe2(fds, number(cloexec) ? O_CLOEXEC : 0) < 0)
        return boxed(1, integer(errno));
#else
    if (pipe(fds) < 0)
        return boxed(1, integer(errno));
    if (number(cloexec) && (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 ||
                           fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0)) {
        int error = errno;
        close(fds[0]);
        close(fds[1]);
        return boxed(1, integer(error));
    }
#endif
    return boxed(0, tuple(integer(fds[0]), integer(fds[1])));
}

value arc_unix_close(value fd)
{
    return integer(close(number(fd)) < 0 ? -errno : 0);
}

value arc_unix_set_nonblock(value fd, value enable)
{
    int descriptor = number(fd);
    int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0)
        return integer(-errno);
    flags = number(enable) ? flags | O_NONBLOCK : flags & ~O_NONBLOCK;
    return integer(fcntl(descriptor, F_SETFL, flags) < 0 ? -errno : 0);
}

value arc_unix_read(value fd, value bytes, value pos, value len)
{
    char *buffer = (char *)(uintptr_t)bytes;
    ssize_t n = read(number(fd), buffer + (pos >> 1), (size_t)(len >> 1));
    return integer(n < 0 ? -errno : n);
}

value arc_unix_write(value fd, value bytes, value pos, value len)
{
    const char *buffer = (const char *)(uintptr_t)bytes;
    ssize_t n = write(number(fd), buffer + (pos >> 1), (size_t)(len >> 1));
    return integer(n < 0 ? -errno : n);
}

value arc_unix_gettimeofday(value unit)
{
    (void)unit;
    struct timeval now;
    if (gettimeofday(&now, NULL) < 0)
        return boxed(1, integer(errno));
    return boxed(0, ocamlcc_alloc_float((double)now.tv_sec + (double)now.tv_usec / 1e6));
}

/* Indices are the negated Sys.sig* constants. Zero means unavailable. */
static const int native_signals[] = {
    0, SIGABRT, SIGALRM, SIGFPE, SIGHUP, SIGILL, SIGINT, SIGKILL,
    SIGPIPE, SIGQUIT, SIGSEGV, SIGTERM, SIGUSR1, SIGUSR2, SIGCHLD,
    SIGCONT, SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU, SIGVTALRM, SIGPROF, SIGBUS,
#ifdef SIGPOLL
    SIGPOLL,
#else
    0,
#endif
    SIGSYS, SIGTRAP, SIGURG, SIGXCPU, SIGXFSZ, SIGIO, SIGWINCH
};

static int signal_to_native(int64_t signal)
{
    if (signal >= 0)
        return signal <= INT_MAX ? (int)signal : -1;
    if (-signal >= (int64_t)(sizeof native_signals / sizeof native_signals[0]))
        return -1;
    int native = native_signals[-signal];
    return native != 0 ? native : -1;
}

static int signal_from_native(int signal)
{
    for (size_t i = 1; i < sizeof native_signals / sizeof native_signals[0]; i++) {
        if (native_signals[i] == signal)
            return -(int)i;
    }
    return signal;
}

value arc_unix_getpid(value unit)
{
    (void)unit;
    return integer(getpid());
}

value arc_unix_kill(value pid, value signal)
{
    int64_t requested = pid >> 1;
    int native = signal_to_native(signal >> 1);
    if ((pid_t)requested != requested || native < 0)
        return integer(-EINVAL);
    return integer(kill((pid_t)requested, native) < 0 ? -errno : 0);
}

value arc_unix_waitpid(value pid, value nohang, value untraced)
{
    int64_t requested = pid >> 1;
    if ((pid_t)requested != requested)
        return boxed(1, integer(EINVAL));
    int options = (number(nohang) ? WNOHANG : 0) |
                  (number(untraced) ? WUNTRACED : 0);
    int status = 0;
    pid_t ready = waitpid((pid_t)requested, &status, options);
    if (ready < 0)
        return boxed(1, integer(errno));

    value outcome;
    if (ready == 0 || WIFEXITED(status))
        outcome = boxed(0, integer(WEXITSTATUS(status)));
    else if (WIFSTOPPED(status))
        outcome = boxed(2, integer(signal_from_native(WSTOPSIG(status))));
    else
        outcome = boxed(1, integer(signal_from_native(WTERMSIG(status))));
    return boxed(0, tuple(integer(ready), outcome));
}
