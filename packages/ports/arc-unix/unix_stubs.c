#define _GNU_SOURCE
#include "arc.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
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

static value pair(unsigned tag, value first, value second)
{
    value *fields = arc_alloc(tag, 2, 2 * sizeof *fields);
    fields[0] = first;
    fields[1] = second;
    return (value)(uintptr_t)fields;
}

static value tuple(value first, value second)
{
    return pair(0, first, second);
}

static value copy_string(const void *source, size_t length)
{
    char *buffer = arc_alloc_bytes(length);
    memcpy(buffer, source, length);
    return (value)(uintptr_t)buffer;
}

static value text(const char *str) { return copy_string(str, strlen(str)); }

value arc_unix_errno(value name)
{
    const char *symbol = (const char *)(uintptr_t)name;
#define CHECK(code) if (!strcmp(symbol, #code)) return integer(code)
    CHECK(EACCES); CHECK(EAGAIN); CHECK(EBADF); CHECK(EBUSY); CHECK(ECHILD); CHECK(EINTR);
    CHECK(EEXIST); CHECK(EINVAL); CHECK(EIO); CHECK(EMFILE); CHECK(ENFILE); CHECK(ENOENT);
    CHECK(ENOMEM); CHECK(ENOSYS); CHECK(EPERM); CHECK(EPIPE); CHECK(ESRCH);
    CHECK(ETIMEDOUT); CHECK(EWOULDBLOCK);
    CHECK(EADDRINUSE); CHECK(EADDRNOTAVAIL); CHECK(EAFNOSUPPORT); CHECK(EALREADY);
    CHECK(ECONNREFUSED); CHECK(ECONNRESET); CHECK(EINPROGRESS); CHECK(EISCONN);
    CHECK(ENAMETOOLONG); CHECK(ENOTCONN); CHECK(ENOTSOCK); CHECK(EPROTONOSUPPORT);
    CHECK(EDEADLK); CHECK(EISDIR); CHECK(ELOOP); CHECK(ENOLCK); CHECK(ENOSPC);
    CHECK(ENOTDIR); CHECK(ENOTEMPTY);
    CHECK(EOVERFLOW); CHECK(EROFS); CHECK(EXDEV);
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

static int stat_kind(mode_t mode)
{
    /* Match the constructors in Unix.File_kind. */
    switch (mode & S_IFMT) {
    case S_IFREG: return 0;
    case S_IFDIR: return 1;
    case S_IFCHR: return 2;
    case S_IFBLK: return 3;
    case S_IFLNK: return 4;
    case S_IFIFO: return 5;
    case S_IFSOCK: return 6;
    default: return -1;
    }
}

static int ocaml_int_fits(int64_t n)
{
    return n >= -(INT64_C(1) << 62) && n <= (INT64_MAX >> 1);
}

static value timestamp(struct timespec time)
{
    return ocamlcc_alloc_float((double)time.tv_sec + (double)time.tv_nsec / 1e9);
}

static value stat_result(const struct stat *info)
{
    int kind = stat_kind(info->st_mode);
    if (kind < 0)
        return boxed(1, integer(EINVAL));
    if (!ocaml_int_fits(info->st_size))
        return boxed(1, integer(EOVERFLOW));

#ifdef __APPLE__
    value access_time = timestamp(info->st_atimespec);
    value modify_time = timestamp(info->st_mtimespec);
    value change_time = timestamp(info->st_ctimespec);
#else
    value access_time = timestamp(info->st_atim);
    value modify_time = timestamp(info->st_mtim);
    value change_time = timestamp(info->st_ctim);
#endif
    /* Record layout of Unix.Stats.t. */
    value fields[] = {
        integer((int64_t)info->st_dev), integer((int64_t)info->st_ino), integer(kind),
        integer(info->st_mode & 07777), integer(info->st_nlink),
        integer(info->st_uid), integer(info->st_gid), integer((int64_t)info->st_rdev),
        integer(info->st_size), access_time, modify_time, change_time
    };
    value *record = arc_alloc(0, sizeof fields / sizeof *fields, sizeof fields);
    memcpy(record, fields, sizeof fields);
    return boxed(0, (value)(uintptr_t)record);
}

value arc_unix_stat(value path, value follow)
{
    struct stat info;
    const char *name = (const char *)(uintptr_t)path;
    int result = number(follow) ? stat(name, &info) : lstat(name, &info);
    return result < 0 ? boxed(1, integer(errno)) : stat_result(&info);
}

value arc_unix_fstat(value fd)
{
    struct stat info;
    return fstat(number(fd), &info) < 0 ? boxed(1, integer(errno)) : stat_result(&info);
}

value arc_unix_chmod(value path, value permissions)
{
    int result = chmod((const char *)(uintptr_t)path, (mode_t)number(permissions));
    return integer(result < 0 ? -errno : 0);
}

value arc_unix_fchmod(value fd, value permissions)
{
    return integer(fchmod(number(fd), (mode_t)number(permissions)) < 0 ? -errno : 0);
}

value arc_unix_mkdir(value path, value permissions)
{
    int result = mkdir((const char *)(uintptr_t)path, (mode_t)number(permissions));
    return integer(result < 0 ? -errno : 0);
}

value arc_unix_rmdir(value path)
{
    return integer(rmdir((const char *)(uintptr_t)path) < 0 ? -errno : 0);
}

value arc_unix_unlink(value path)
{
    return integer(unlink((const char *)(uintptr_t)path) < 0 ? -errno : 0);
}

value arc_unix_rename(value source, value destination)
{
    int result = rename((const char *)(uintptr_t)source, (const char *)(uintptr_t)destination);
    return integer(result < 0 ? -errno : 0);
}

value arc_unix_access(value path, value permission)
{
    /* Bits are defined by Unix.Access_permission.encode. */
    unsigned mask = (unsigned)number(permission);
    int mode = ((mask & 1u) ? R_OK : 0) | ((mask & 2u) ? W_OK : 0) | ((mask & 4u) ? X_OK : 0);
    return integer(access((const char *)(uintptr_t)path, mode) < 0 ? -errno : 0);
}

value arc_unix_realpath(value path)
{
    char *resolved = realpath((const char *)(uintptr_t)path, NULL);
    if (resolved == NULL)
        return boxed(1, integer(errno));
    value result = text(resolved);
    free(resolved);
    return boxed(0, result);
}

value arc_unix_getuid(value unit)
{
    (void)unit;
    return integer(getuid());
}

value arc_unix_lseek(value descriptor, value offset, value origin)
{
    const int origins[] = {SEEK_SET, SEEK_CUR, SEEK_END};
    off_t position = lseek(number(descriptor), (off_t)(offset >> 1), origins[number(origin)]);
    if (position == (off_t)-1)
        return boxed(1, integer(errno));
    if (!ocaml_int_fits(position))
        return boxed(1, integer(EOVERFLOW));
    return boxed(0, integer(position));
}

value arc_unix_ftruncate(value descriptor, value length)
{
    return integer(ftruncate(number(descriptor), (off_t)(length >> 1)) < 0 ? -errno : 0);
}

value arc_unix_fsync(value descriptor)
{
    return integer(fsync(number(descriptor)) < 0 ? -errno : 0);
}

value arc_unix_lockf(value descriptor, value command, value length)
{
    /* Match the constructors in Unix.Lock_command. */
    const struct {
        short type;
        int action;
    } modes[] = {
        {F_UNLCK, F_SETLK}, {F_WRLCK, F_SETLKW}, {F_WRLCK, F_SETLK},
        {F_WRLCK, F_GETLK}, {F_RDLCK, F_SETLKW}, {F_RDLCK, F_SETLK}
    };
    int option = number(command);
    int action = modes[option].action;
    struct flock region = {
        .l_type = modes[option].type,
        .l_whence = SEEK_CUR,
        .l_len = (off_t)(length >> 1)
    };
    if (fcntl(number(descriptor), action, &region) < 0)
        return integer(-errno);
    if (action == F_GETLK && region.l_type != F_UNLCK)
        return integer(-EACCES);
    return integer(0);
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

value arc_unix_inet_parse(value input)
{
    struct in_addr ip;
    if (inet_pton(AF_INET, (const char *)(uintptr_t)input, &ip) != 1)
        return integer(0);
    return boxed(0, copy_string(&ip, sizeof ip));
}

/* Match the constructors in Unix.Socket_domain and Unix.Socket_type. */
static int socket_domain(value domain) { return number(domain) == 0 ? AF_UNIX : AF_INET; }
static int socket_type(value kind) { return number(kind) == 0 ? SOCK_STREAM : SOCK_DGRAM; }

static int socket_with_cloexec(int fd, int cloexec)
{
#ifndef __linux__
    if (fd >= 0 && cloexec && set_cloexec(fd, 1) < 0) {
        int error = errno;
        close(fd);
        errno = error;
        return -1;
    }
#else
    (void)cloexec;
#endif
    return fd;
}

value arc_unix_socket(value domain, value kind, value protocol, value cloexec)
{
    if ((int64_t)number(protocol) != (protocol >> 1))
        return integer(-EINVAL);
    int flags = socket_type(kind);
#ifdef __linux__
    if (number(cloexec))
        flags |= SOCK_CLOEXEC;
#endif
    int fd = socket(socket_domain(domain), flags, number(protocol));
    fd = socket_with_cloexec(fd, number(cloexec));
    return integer(fd < 0 ? -errno : fd);
}

value arc_unix_socketpair(value domain, value kind, value protocol, value cloexec)
{
    if ((int64_t)number(protocol) != (protocol >> 1))
        return boxed(1, integer(EINVAL));
    int flags = socket_type(kind);
    int fds[2];
#ifdef __linux__
    if (number(cloexec))
        flags |= SOCK_CLOEXEC;
#endif
    if (socketpair(socket_domain(domain), flags, number(protocol), fds) < 0)
        return boxed(1, integer(errno));
#ifndef __linux__
    if (number(cloexec) && (set_cloexec(fds[0], 1) < 0 || set_cloexec(fds[1], 1) < 0)) {
        int error = errno;
        close(fds[0]);
        close(fds[1]);
        return boxed(1, integer(error));
    }
#endif
    return boxed(0, tuple(integer(fds[0]), integer(fds[1])));
}

union socket_address {
    struct sockaddr_storage storage;
    struct sockaddr generic;
    struct sockaddr_un local;
    struct sockaddr_in ipv4;
};

static int encode_address(union socket_address *address, socklen_t *length,
                          const char *bytes, size_t count, int port)
{
    if (port >= 0) {
        address->ipv4.sin_family = AF_INET;
        address->ipv4.sin_port = htons((uint16_t)port);
        memcpy(&address->ipv4.sin_addr, bytes, sizeof address->ipv4.sin_addr);
        *length = sizeof address->ipv4;
#ifdef __APPLE__
        address->ipv4.sin_len = *length;
#endif
        return 0;
    }

    int abstract = 0;
#ifdef __linux__
    abstract = count > 0 && bytes[0] == '\0';
#endif
    size_t used = count + (abstract ? 0 : 1);
    if (used > sizeof address->local.sun_path)
        return ENAMETOOLONG;
    if (!abstract && memchr(bytes, '\0', count) != NULL)
        return EINVAL;
    address->local.sun_family = AF_UNIX;
    memcpy(address->local.sun_path, bytes, count);
    *length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + used);
#ifdef __APPLE__
    address->local.sun_len = *length;
#endif
    return 0;
}

static value decode_address(const union socket_address *address, socklen_t length)
{
    /* A peer without a local address may have an empty sockaddr. */
    if (length == 0)
        return boxed(0, text(""));
    if (address->generic.sa_family == AF_INET && length >= sizeof address->ipv4) {
        value ip = copy_string(&address->ipv4.sin_addr, sizeof address->ipv4.sin_addr);
        return pair(1, ip, integer(ntohs(address->ipv4.sin_port)));
    }
    if (address->generic.sa_family == AF_UNIX) {
        size_t head = offsetof(struct sockaddr_un, sun_path);
        size_t count = length > head ? length - head : 0;
        if (count > sizeof address->local.sun_path)
            count = sizeof address->local.sun_path;
        const char *path = address->local.sun_path;
#ifdef __linux__
        if (count > 0 && path[0] == '\0')
            return boxed(0, copy_string(path, count));
#endif
        const char *end = memchr(path, '\0', count);
        return boxed(0, copy_string(path, end ? (size_t)(end - path) : count));
    }
    return 0;
}

static value use_address(int connecting, value fd, value bytes, value size, value port)
{
    union socket_address address = {0};
    socklen_t length;
    int error = encode_address(&address, &length, (const char *)(uintptr_t)bytes,
                               (size_t)(size >> 1), number(port));
    if (error != 0)
        return integer(-error);
    int descriptor = number(fd);
    int status = connecting ? connect(descriptor, &address.generic, length) :
                              bind(descriptor, &address.generic, length);
    return integer(status < 0 ? -errno : 0);
}

value arc_unix_bind(value fd, value bytes, value size, value port)
{
    return use_address(0, fd, bytes, size, port);
}

value arc_unix_connect(value fd, value bytes, value size, value port)
{
    return use_address(1, fd, bytes, size, port);
}

value arc_unix_listen(value fd, value backlog)
{
    if ((int64_t)number(backlog) != (backlog >> 1))
        return integer(-EINVAL);
    return integer(listen(number(fd), number(backlog)) < 0 ? -errno : 0);
}

value arc_unix_accept(value descriptor, value cloexec)
{
    union socket_address address = {0};
    socklen_t length = sizeof address.storage;
#ifdef __linux__
    int client = accept4(number(descriptor), &address.generic, &length,
                         number(cloexec) ? SOCK_CLOEXEC : 0);
#else
    int client = accept(number(descriptor), &address.generic, &length);
    client = socket_with_cloexec(client, number(cloexec));
#endif
    if (client < 0)
        return boxed(1, integer(errno));
    value peer = decode_address(&address, length);
    if (peer == 0) {
        close(client);
        return boxed(1, integer(EAFNOSUPPORT));
    }
    return boxed(0, tuple(integer(client), peer));
}

value arc_unix_socket_name(value descriptor, value peer)
{
    union socket_address address = {0};
    socklen_t length = sizeof address.storage;
    int fd = number(descriptor);
    int result = number(peer) ? getpeername(fd, &address.generic, &length) :
                                getsockname(fd, &address.generic, &length);
    if (result < 0)
        return boxed(1, integer(errno));
    value name = decode_address(&address, length);
    return name == 0 ? boxed(1, integer(EAFNOSUPPORT)) : boxed(0, name);
}

value arc_unix_shutdown(value descriptor, value command)
{
    const int modes[] = {SHUT_RD, SHUT_WR, SHUT_RDWR};
    return integer(shutdown(number(descriptor), modes[number(command)]) < 0 ? -errno : 0);
}

static value set_socket_option(value fd, int option, const void *setting, socklen_t size)
{
    return integer(setsockopt(number(fd), SOL_SOCKET, option, setting, size) < 0 ? -errno : 0);
}

value arc_unix_setsockopt_reuseaddr(value fd, value enabled)
{
    int setting = number(enabled);
    return set_socket_option(fd, SO_REUSEADDR, &setting, sizeof setting);
}

value arc_unix_setsockopt_int(value fd, value option, value amount)
{
    int size = number(amount);
    if ((int64_t)size != (amount >> 1))
        return integer(-EINVAL);
    int name = number(option) == 0 ? SO_SNDBUF : SO_RCVBUF;
    return set_socket_option(fd, name, &size, sizeof size);
}

value arc_unix_setsockopt_timeout(value fd, value option, value seconds, value micros)
{
    struct timeval timeout = {.tv_sec = (time_t)(seconds >> 1), .tv_usec = number(micros)};
    int name = number(option) == 0 ? SO_RCVTIMEO : SO_SNDTIMEO;
    return set_socket_option(fd, name, &timeout, sizeof timeout);
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
