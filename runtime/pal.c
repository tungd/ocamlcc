/* pal.c — POSIX/kqueue/epoll implementation of the PAL hooks. */
#include "pal.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#define PAL_USE_KQUEUE 1
#include <sys/event.h>
#elif defined(__linux__)
#define PAL_USE_EPOLL 1
#include <sys/epoll.h>
#endif

#if defined(PAL_USE_EPOLL)
/* Per-fd watch registry: epoll keys a registration by fd alone, so two
   fibers watching the same fd (one READ, one WRITE) must share one
   registration with both interest bits; a plain EPOLL_CTL_MOD would
   overwrite ev.data.ptr and silently lose the first fiber's wakeup. The
   registry keeps one udata per direction; kernel events carry the entry
   pointer and pal_poller_wait dispatches to the right watcher(s). */
typedef struct PalWatch {
    int pfd; /* owning poller */
    int fd;
    void *read_udata;
    void *write_udata;
} PalWatch;

#define PAL_WATCH_MAX 1024
static PalWatch g_watches[PAL_WATCH_MAX];
static int g_watch_count = 0;

static PalWatch *watch_find(int pfd, int fd)
{
    for (int i = 0; i < g_watch_count; i++) {
        if (g_watches[i].pfd == pfd && g_watches[i].fd == fd)
            return &g_watches[i];
    }
    return NULL;
}

static PalWatch *watch_alloc(int pfd, int fd)
{
    if (g_watch_count >= PAL_WATCH_MAX)
        return NULL;
    PalWatch *w = &g_watches[g_watch_count++];
    w->pfd = pfd;
    w->fd = fd;
    w->read_udata = NULL;
    w->write_udata = NULL;
    return w;
}

static void watch_free(PalWatch *w)
{
    int idx = (int)(w - g_watches);
    g_watches[idx] = g_watches[g_watch_count - 1];
    g_watch_count--;
}

static uint32_t watch_events_of(const PalWatch *w)
{
    uint32_t ev = EPOLLONESHOT;
    if (w->read_udata != NULL)
        ev |= EPOLLIN;
    if (w->write_udata != NULL)
        ev |= EPOLLOUT;
    return ev;
}
#endif /* PAL_USE_EPOLL */

void *pal_page_alloc(size_t size)
{
    void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return ptr == MAP_FAILED ? NULL : ptr;
}

void pal_page_free(void *ptr, size_t size) { munmap(ptr, size); }

void pal_abort(void) { abort(); }

uint64_t pal_monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

void pal_ctx_make(PalContext *ctx, void *stack_top, void (*entry)(void))
{
    memset(ctx, 0, sizeof(*ctx));
#if defined(__aarch64__)
    uintptr_t sp = ((uintptr_t)stack_top) & ~(uintptr_t)15u;
    ctx->regs[11] = (uint64_t)(uintptr_t)entry; /* lr (x30) */
    ctx->regs[12] = (uint64_t)sp;               /* sp */
#elif defined(__x86_64__)
    uintptr_t sp = (((uintptr_t)stack_top) & ~(uintptr_t)15u) - 8u;
    ctx->regs[6] = (uint64_t)sp;                /* rsp */
    ctx->regs[7] = (uint64_t)(uintptr_t)entry;  /* rip */
#else
    (void)stack_top;
    (void)entry;
    pal_abort();
#endif
}

int pal_poller_create(void)
{
#if defined(PAL_USE_KQUEUE)
    return kqueue();
#elif defined(PAL_USE_EPOLL)
    return epoll_create1(EPOLL_CLOEXEC);
#else
    return -1;
#endif
}

void pal_poller_close(int pfd)
{
    if (pfd >= 0)
        close(pfd);
#if defined(PAL_USE_EPOLL)
    /* Drop this poller's watch-registry entries. */
    int i = 0;
    while (i < g_watch_count) {
        if (g_watches[i].pfd == pfd) {
            g_watches[i] = g_watches[g_watch_count - 1];
            g_watch_count--;
        } else {
            i++;
        }
    }
#endif
}

int pal_poller_watch(int pfd, int fd, uint32_t events, void *udata)
{
#if defined(PAL_USE_KQUEUE)
    struct kevent kevs[2];
    int n = 0;
    if (events & PAL_POLL_READ) {
        EV_SET(&kevs[n], (uintptr_t)fd, EVFILT_READ,
               EV_ADD | EV_ENABLE | EV_ONESHOT, 0, 0, udata);
        n++;
    }
    if (events & PAL_POLL_WRITE) {
        EV_SET(&kevs[n], (uintptr_t)fd, EVFILT_WRITE,
               EV_ADD | EV_ENABLE | EV_ONESHOT, 0, 0, udata);
        n++;
    }
    if (n == 0)
        return 0;
    return kevent(pfd, kevs, n, NULL, 0, NULL);
#elif defined(PAL_USE_EPOLL)
    PalWatch *w = watch_find(pfd, fd);
    if (w == NULL) {
        w = watch_alloc(pfd, fd);
        if (w == NULL)
            return -1;
        if (events & PAL_POLL_READ)
            w->read_udata = udata;
        if (events & PAL_POLL_WRITE)
            w->write_udata = udata;
        struct epoll_event ev;
        ev.events = watch_events_of(w);
        ev.data.ptr = w;
        if (epoll_ctl(pfd, EPOLL_CTL_ADD, fd, &ev) < 0) {
            watch_free(w);
            return -1;
        }
        return 0;
    }
    /* Existing registration: merge the new interest and re-arm both. */
    if (events & PAL_POLL_READ)
        w->read_udata = udata;
    if (events & PAL_POLL_WRITE)
        w->write_udata = udata;
    struct epoll_event ev;
    ev.events = watch_events_of(w);
    ev.data.ptr = w;
    return epoll_ctl(pfd, EPOLL_CTL_MOD, fd, &ev);
#else
    (void)pfd;
    (void)fd;
    (void)events;
    (void)udata;
    return -1;
#endif
}

int pal_poller_unwatch(int pfd, int fd, uint32_t events)
{
#if defined(PAL_USE_KQUEUE)
    struct kevent kevs[2];
    int n = 0;
    if (events & PAL_POLL_READ) {
        EV_SET(&kevs[n], (uintptr_t)fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
        n++;
    }
    if (events & PAL_POLL_WRITE) {
        EV_SET(&kevs[n], (uintptr_t)fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
        n++;
    }
    if (n == 0)
        return 0;
    return kevent(pfd, kevs, n, NULL, 0, NULL);
#elif defined(PAL_USE_EPOLL)
    PalWatch *w = watch_find(pfd, fd);
    if (w == NULL)
        return -1;
    if (events & PAL_POLL_READ)
        w->read_udata = NULL;
    if (events & PAL_POLL_WRITE)
        w->write_udata = NULL;
    if (w->read_udata == NULL && w->write_udata == NULL) {
        int rc = epoll_ctl(pfd, EPOLL_CTL_DEL, fd, NULL);
        watch_free(w);
        return rc;
    }
    struct epoll_event ev;
    ev.events = watch_events_of(w);
    ev.data.ptr = w;
    return epoll_ctl(pfd, EPOLL_CTL_MOD, fd, &ev);
#else
    (void)pfd;
    (void)fd;
    (void)events;
    return -1;
#endif
}

int pal_poller_wait(int pfd, PalPollEvent *out, int max_events, int timeout_ms)
{
#if defined(PAL_USE_KQUEUE)
    if (max_events <= 0)
        return 0;
    if (max_events > 64)
        max_events = 64;
    struct kevent kevs[64];
    struct timespec ts;
    struct timespec *pts = NULL;
    if (timeout_ms >= 0) {
        ts.tv_sec = timeout_ms / 1000;
        ts.tv_nsec = (long)(timeout_ms % 1000) * 1000000L;
        pts = &ts;
    }
    int n;
    do {
        n = kevent(pfd, NULL, 0, kevs, max_events, pts);
    } while (n < 0 && errno == EINTR);
    if (n <= 0)
        return n;
    for (int i = 0; i < n; i++) {
        out[i].fd = (int)kevs[i].ident;
        out[i].events = (kevs[i].filter == EVFILT_WRITE)
                            ? PAL_POLL_WRITE
                            : PAL_POLL_READ;
        out[i].udata = kevs[i].udata;
    }
    return n;
#elif defined(PAL_USE_EPOLL)
    if (max_events <= 0)
        return 0;
    if (max_events > 64)
        max_events = 64;
    struct epoll_event evs[64];
    int n;
    do {
        n = epoll_wait(pfd, evs, max_events, timeout_ms);
    } while (n < 0 && errno == EINTR);
    if (n <= 0)
        return n;
    int out_n = 0;
    for (int i = 0; i < n && out_n < max_events; i++) {
        PalWatch *w = (PalWatch *)evs[i].data.ptr;
        if (w == NULL)
            continue;
        uint32_t e = evs[i].events;
        int read_fired = (e & (EPOLLIN | EPOLLHUP | EPOLLERR)) != 0u &&
                         w->read_udata != NULL && out_n < max_events;
        int write_fired = (e & (EPOLLOUT | EPOLLERR)) != 0u &&
                          w->write_udata != NULL && out_n < max_events;
        if (read_fired) {
            out[out_n].fd = w->fd;
            out[out_n].events = PAL_POLL_READ;
            out[out_n].udata = w->read_udata;
            out_n++;
            w->read_udata = NULL;
        }
        if (write_fired) {
            out[out_n].fd = w->fd;
            out[out_n].events = PAL_POLL_WRITE;
            out[out_n].udata = w->write_udata;
            out_n++;
            w->write_udata = NULL;
        }
        /* EPOLLONESHOT consumed the registration: re-arm any surviving
           interest, or deregister the fd when both watchers are done. */
        if (w->read_udata == NULL && w->write_udata == NULL) {
            epoll_ctl(pfd, EPOLL_CTL_DEL, w->fd, NULL);
            watch_free(w);
        } else {
            struct epoll_event rev;
            rev.events = watch_events_of(w);
            rev.data.ptr = w;
            epoll_ctl(pfd, EPOLL_CTL_MOD, w->fd, &rev);
        }
    }
    return out_n;
#else
    (void)pfd;
    (void)out;
    (void)max_events;
    (void)timeout_ms;
    return -1;
#endif
}

int pal_poll_wait(int *fds, int nfds, int timeout_ms)
{
    int pfd = pal_poller_create();
    if (pfd < 0)
        return -1;
    for (int i = 0; i < nfds; i++)
        pal_poller_watch(pfd, fds[i], PAL_POLL_READ, (void *)(intptr_t)fds[i]);
    PalPollEvent ev;
    int n = pal_poller_wait(pfd, &ev, 1, timeout_ms);
    pal_poller_close(pfd);
    return (n > 0) ? ev.fd : -1;
}

int pal_pipe(int fds[2])
{
    if (pipe(fds) < 0)
        return -1;
    if (pal_fd_set_nonblock(fds[0]) < 0 || pal_fd_set_nonblock(fds[1]) < 0) {
        close(fds[0]);
        close(fds[1]);
        return -1;
    }
    return 0;
}

int pal_fd_set_nonblock(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0)
        return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

int64_t pal_fd_read(int fd, void *buf, size_t len)
{
    ssize_t n;
    do {
        n = read(fd, buf, len);
    } while (n < 0 && errno == EINTR);
    if (n >= 0)
        return (int64_t)n;
    if (errno == EAGAIN || errno == EWOULDBLOCK)
        return -2;
    return -1;
}

int64_t pal_fd_write(int fd, const void *buf, size_t len)
{
    ssize_t n;
    do {
        n = write(fd, buf, len);
    } while (n < 0 && errno == EINTR);
    if (n >= 0)
        return (int64_t)n;
    if (errno == EAGAIN || errno == EWOULDBLOCK)
        return -2;
    return -1;
}

void pal_fd_close(int fd)
{
    if (fd >= 0)
        close(fd);
}

void pal_stderr_write(const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(STDERR_FILENO, p + off, len - off);
        if (n > 0) {
            off += (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

void *pal_memcpy(void *dst, const void *src, size_t n)
{
    return memcpy(dst, src, n);
}

void *pal_memset(void *dst, int c, size_t n) { return memset(dst, c, n); }
