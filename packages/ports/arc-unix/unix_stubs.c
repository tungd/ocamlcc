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

#ifdef __APPLE__
#include <sys/event.h>
#endif

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
    CHECK(EACCES); CHECK(EAGAIN); CHECK(EBADF); CHECK(EBUSY); CHECK(ECHILD); CHECK(EINTR);
    CHECK(EEXIST); CHECK(EINVAL); CHECK(EIO); CHECK(EMFILE); CHECK(ENFILE); CHECK(ENOENT);
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

static int set_cloexec(int fd, int enabled)
{
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0)
        return -1;
    return fcntl(fd, F_SETFD, enabled ? flags | FD_CLOEXEC : flags & ~FD_CLOEXEC);
}

value arc_unix_check_fd(value fd)
{
    int64_t raw = fd >> 1;
    if (raw < 0 || raw > INT_MAX)
        return integer(-EBADF);
    return integer(fcntl((int)raw, F_GETFD) < 0 ? -errno : raw);
}

value arc_unix_openfile(value path, value flags, value permissions)
{
    /* Order matches Unix.Open_flag.encode. */
    const int native_flags[] = {
        O_WRONLY, O_RDWR, O_NONBLOCK, O_APPEND, O_CREAT, O_TRUNC, O_EXCL,
        O_NOCTTY, O_CLOEXEC
    };
    unsigned mask = (unsigned)number(flags);
    if ((mask & 3u) == 3u)
        return integer(-EINVAL);
    if (mask & 512u)
        mask &= ~256u;
    int native = O_RDONLY;
    for (size_t i = 0; i < sizeof native_flags / sizeof *native_flags; i++)
        if (mask & (1u << i))
            native |= native_flags[i];
    int fd = open((const char *)(uintptr_t)path, native, (mode_t)number(permissions));
    return integer(fd < 0 ? -errno : fd);
}

value arc_unix_dup(value descriptor, value cloexec)
{
    int fd = number(descriptor);
    int copy = number(cloexec) ? fcntl(fd, F_DUPFD_CLOEXEC, 0) : dup(fd);
    return integer(copy < 0 ? -errno : copy);
}

value arc_unix_set_cloexec(value descriptor, value cloexec)
{
    return integer(set_cloexec(number(descriptor), number(cloexec)) < 0 ? -errno : 0);
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
    if (number(cloexec) && (set_cloexec(fds[0], 1) < 0 || set_cloexec(fds[1], 1) < 0)) {
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

#ifdef __APPLE__
enum { SIGNAL_COUNT = 3 };
/* Keep this order aligned with Unix.Signal_events.Event.t. */
static const int watched_signals[SIGNAL_COUNT] = {SIGINT, SIGTERM, SIGCHLD};
static struct {
    int fd;
    struct sigaction previous[SIGNAL_COUNT];
} signal_queue = {.fd = -1};

static void ignore_delivery(int signal)
{
    (void)signal;
}

static int block_watched_signals(sigset_t *previous)
{
    sigset_t watched;
    sigemptyset(&watched);
    for (size_t i = 0; i < SIGNAL_COUNT; i++)
        sigaddset(&watched, watched_signals[i]);
    return sigprocmask(SIG_BLOCK, &watched, previous);
}

static int restore_signal_actions(size_t installed)
{
    int error = 0;
    while (installed > 0) {
        installed--;
        if (sigaction(watched_signals[installed], &signal_queue.previous[installed],
                      NULL) < 0 && error == 0)
            error = errno;
    }
    return error;
}

static int open_signal_queue(void)
{
    if (signal_queue.fd != -1)
        return -EBUSY;
    int fd = kqueue();
    if (fd < 0)
        return -errno;
    int error;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        error = errno;
        close(fd);
        return -error;
    }

    sigset_t previous_mask;
    if (block_watched_signals(&previous_mask) < 0) {
        error = errno;
        close(fd);
        return -error;
    }
    size_t installed = 0;
    struct kevent events[SIGNAL_COUNT];
    for (size_t i = 0; i < SIGNAL_COUNT; i++)
        EV_SET(&events[i], (uintptr_t)watched_signals[i],
               EVFILT_SIGNAL, EV_ADD, 0, 0, NULL);
    if (kevent(fd, events, SIGNAL_COUNT, NULL, 0, NULL) < 0)
        goto rollback;

    struct sigaction action = {.sa_handler = ignore_delivery};
    sigemptyset(&action.sa_mask);
    for (; installed < SIGNAL_COUNT; installed++) {
        int signal = watched_signals[installed];
        action.sa_flags = SA_RESTART | (signal == SIGCHLD ? SA_NOCLDSTOP : 0);
        if (sigaction(signal, &action, &signal_queue.previous[installed]) < 0)
            goto rollback;
    }
    if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) < 0)
        goto rollback;
    signal_queue.fd = fd;
    return fd;

rollback:
    error = errno;
    restore_signal_actions(installed);
    close(fd);
    sigprocmask(SIG_SETMASK, &previous_mask, NULL);
    return -error;
}
#endif

value arc_unix_signal_queue_open(value unit)
{
    (void)unit;
#ifdef __APPLE__
    int fd = open_signal_queue();
    return fd < 0 ? boxed(1, integer(-fd)) : boxed(0, integer(fd));
#else
    return boxed(1, integer(ENOSYS));
#endif
}

value arc_unix_signal_queue_close(value descriptor)
{
#ifdef __APPLE__
    int fd = number(descriptor);
    if (fd != signal_queue.fd)
        return integer(-EBADF);
    sigset_t previous_mask;
    if (block_watched_signals(&previous_mask) < 0)
        return integer(-errno);
    int error = restore_signal_actions(SIGNAL_COUNT);
    if (close(fd) < 0 && error == 0)
        error = errno;
    signal_queue.fd = -1;
    if (sigprocmask(SIG_SETMASK, &previous_mask, NULL) < 0 && error == 0)
        error = errno;
    return integer(-error);
#else
    (void)descriptor;
    return integer(-ENOSYS);
#endif
}

value arc_unix_signal_queue_next(value descriptor)
{
#ifdef __APPLE__
    struct kevent event;
    const struct timespec zero = {0};
    int count;
    do {
        count = kevent(number(descriptor), NULL, 0, &event, 1, &zero);
    } while (count < 0 && errno == EINTR);
    if (count < 0)
        return boxed(1, integer(errno));
    if (count == 0)
        return boxed(0, integer(0));
    for (size_t i = 0; i < SIGNAL_COUNT; i++) {
        if (event.filter == EVFILT_SIGNAL && event.ident == (uintptr_t)watched_signals[i])
            return boxed(0, boxed(0, integer(i)));
    }
    return boxed(1, integer(EIO));
#else
    (void)descriptor;
    return boxed(1, integer(ENOSYS));
#endif
}
