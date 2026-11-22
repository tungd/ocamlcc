#define _GNU_SOURCE
#include "arc.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/time.h>
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
