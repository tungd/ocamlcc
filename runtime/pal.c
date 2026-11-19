/* pal.c — POSIX/kqueue/epoll implementation of the PAL hooks. */
#if defined(__linux__) && !defined(_DEFAULT_SOURCE)
#define _DEFAULT_SOURCE 1
#endif

#include "pal.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
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

#if defined(PAL_USE_KQUEUE) || defined(PAL_USE_EPOLL)
/* Per-fd watch registry:
 * - On epoll, a single kernel registration is keyed by fd alone, so READ and
 *   WRITE watchers on the same fd share one registration.
 * - On both kqueue and epoll, multiple fibers can wait on the same (fd, dir),
 *   so each direction holds a FIFO list of waiter udatas instead of overwriting
 *   the previous fiber's udata.
 * - Slots in g_watches[] never move; kernel tokens encode (gen << 32) | idx
 *   so freeing one watch never invalidates or aliases another registration or
 *   a pending event in the same wait batch. */
typedef struct PalWaiter {
    void *udata;
    int next;
    int in_use;
} PalWaiter;

typedef struct PalWatch {
    int in_use;
    uint32_t gen;
    int pfd; /* owning poller */
    int fd;
    int read_head;
    int read_tail;
    int write_head;
    int write_tail;
} PalWatch;

#define PAL_WATCH_MAX  1024
#define PAL_WAITER_MAX 2048
static PalWatch g_watches[PAL_WATCH_MAX];
static PalWaiter g_waiters[PAL_WAITER_MAX];
static _Atomic uint32_t g_watch_lock = 0u;

static inline void watch_lock(void)
{
    while (atomic_exchange_explicit(&g_watch_lock, 1u, memory_order_acquire) != 0u)
        ;
}

static inline void watch_unlock(void)
{
    atomic_store_explicit(&g_watch_lock, 0u, memory_order_release);
}

static inline uint64_t watch_encode(const PalWatch *w)
{
    uint32_t idx = (uint32_t)(w - g_watches);
    return ((uint64_t)w->gen << 32) | (uint64_t)idx;
}

static inline PalWatch *watch_decode(int pfd, uint64_t token)
{
    uint32_t idx = (uint32_t)(token & 0xffffffffu);
    uint32_t gen = (uint32_t)(token >> 32);
    if (idx >= PAL_WATCH_MAX)
        return NULL;
    PalWatch *w = &g_watches[idx];
    if (!w->in_use || w->gen != gen || w->pfd != pfd)
        return NULL;
    return w;
}

static int waiter_push(int *head, int *tail, void *udata)
{
    for (int i = 0; i < PAL_WAITER_MAX; i++) {
        if (!g_waiters[i].in_use) {
            g_waiters[i].in_use = 1;
            g_waiters[i].udata = udata;
            g_waiters[i].next = -1;
            if (*tail >= 0)
                g_waiters[*tail].next = i;
            else
                *head = i;
            *tail = i;
            return i;
        }
    }
    return -1;
}

static int waiter_pop(int *head, int *tail, void **out_udata)
{
    int i = *head;
    if (i < 0)
        return 0;
    *out_udata = g_waiters[i].udata;
    *head = g_waiters[i].next;
    if (*head < 0)
        *tail = -1;
    g_waiters[i].in_use = 0;
    g_waiters[i].next = -1;
    return 1;
}

static void waiter_clear(int *head, int *tail)
{
    void *unused;
    while (waiter_pop(head, tail, &unused))
        ;
}

static void waiter_remove_idx(int *head, int *tail, int target_idx)
{
    if (target_idx < 0)
        return;
    int prev = -1;
    int cur = *head;
    while (cur >= 0) {
        if (cur == target_idx) {
            if (prev >= 0)
                g_waiters[prev].next = g_waiters[cur].next;
            else
                *head = g_waiters[cur].next;
            if (*tail == cur)
                *tail = prev;
            g_waiters[cur].in_use = 0;
            g_waiters[cur].next = -1;
            return;
        }
        prev = cur;
        cur = g_waiters[cur].next;
    }
}

static PalWatch *watch_find(int pfd, int fd)
{
    for (int i = 0; i < PAL_WATCH_MAX; i++) {
        if (g_watches[i].in_use && g_watches[i].pfd == pfd && g_watches[i].fd == fd)
            return &g_watches[i];
    }
    return NULL;
}

static PalWatch *watch_alloc(int pfd, int fd)
{
    for (int i = 0; i < PAL_WATCH_MAX; i++) {
        if (!g_watches[i].in_use) {
            PalWatch *w = &g_watches[i];
            w->in_use = 1;
            w->gen++;
            if (w->gen == 0u)
                w->gen = 1u;
            w->pfd = pfd;
            w->fd = fd;
            w->read_head = -1;
            w->read_tail = -1;
            w->write_head = -1;
            w->write_tail = -1;
            return w;
        }
    }
    return NULL;
}

static void watch_free(PalWatch *w)
{
    waiter_clear(&w->read_head, &w->read_tail);
    waiter_clear(&w->write_head, &w->write_tail);
    w->gen++;
    w->in_use = 0;
}

#if defined(PAL_USE_EPOLL)
static uint32_t watch_events_of(const PalWatch *w)
{
    uint32_t ev = EPOLLONESHOT;
    if (w->read_head >= 0)
        ev |= EPOLLIN;
    if (w->write_head >= 0)
        ev |= EPOLLOUT;
    return ev;
}
#endif /* PAL_USE_EPOLL */
#endif /* PAL_USE_KQUEUE || PAL_USE_EPOLL */

void *pal_page_alloc(size_t size)
{
    void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    return ptr == MAP_FAILED ? NULL : ptr;
}

void pal_page_free(void *ptr, size_t size) { munmap(ptr, size); }

int pal_page_protect_none(void *ptr, size_t size)
{
    return mprotect(ptr, size, PROT_NONE);
}

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
    ctx->regs[PAL_CTX_PC] = (uint64_t)(uintptr_t)entry; /* lr (x30) */
    ctx->regs[PAL_CTX_SP] = (uint64_t)sp;               /* sp */
#elif defined(__x86_64__) && defined(_WIN32)
    uintptr_t sp = (((uintptr_t)stack_top) & ~(uintptr_t)15u) - 8u;
    ctx->regs[PAL_CTX_SP] = (uint64_t)sp;               /* rsp (swap loads 64) */
    ctx->regs[PAL_CTX_PC] = (uint64_t)(uintptr_t)entry; /* rip (swap loads 72) */
#elif defined(__x86_64__)
    uintptr_t sp = (((uintptr_t)stack_top) & ~(uintptr_t)15u) - 8u;
    ctx->regs[PAL_CTX_SP] = (uint64_t)sp;               /* rsp */
    ctx->regs[PAL_CTX_PC] = (uint64_t)(uintptr_t)entry; /* rip */
#elif defined(__riscv) && (__riscv_xlen == 64)
    uintptr_t sp = ((uintptr_t)stack_top) & ~(uintptr_t)15u;
    ctx->regs[PAL_CTX_PC] = (uint64_t)(uintptr_t)entry; /* ra (swap loads 96) */
    ctx->regs[PAL_CTX_SP] = (uint64_t)sp;               /* sp (swap loads 104) */
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
#if defined(PAL_USE_KQUEUE) || defined(PAL_USE_EPOLL)
    watch_lock();
    /* Drop this poller's watch-registry entries. */
    for (int i = 0; i < PAL_WATCH_MAX; i++) {
        if (g_watches[i].in_use && g_watches[i].pfd == pfd)
            watch_free(&g_watches[i]);
    }
    watch_unlock();
#endif
}

int pal_poller_watch(int pfd, int fd, uint32_t events, void *udata)
{
#if defined(PAL_USE_KQUEUE) || defined(PAL_USE_EPOLL)
    if ((events & (PAL_POLL_READ | PAL_POLL_WRITE)) == 0u)
        return 0;
    watch_lock();
    PalWatch *w = watch_find(pfd, fd);
    int is_new = (w == NULL);
    if (is_new) {
        w = watch_alloc(pfd, fd);
        if (w == NULL) {
            watch_unlock();
            return -1;
        }
    }
    int had_read = (w->read_head >= 0);
    int had_write = (w->write_head >= 0);
    int added_r = -1;
    int added_w = -1;
    if (events & PAL_POLL_READ) {
        added_r = waiter_push(&w->read_head, &w->read_tail, udata);
        if (added_r < 0) {
            if (is_new)
                watch_free(w);
            watch_unlock();
            return -1;
        }
    }
    if (events & PAL_POLL_WRITE) {
        added_w = waiter_push(&w->write_head, &w->write_tail, udata);
        if (added_w < 0) {
            waiter_remove_idx(&w->read_head, &w->read_tail, added_r);
            if (is_new)
                watch_free(w);
            watch_unlock();
            return -1;
        }
    }
    int rc = 0;
#if defined(PAL_USE_KQUEUE)
    struct kevent kevs[2];
    int n = 0;
    void *tok = (void *)(uintptr_t)watch_encode(w);
    if ((events & PAL_POLL_READ) && !had_read) {
        EV_SET(&kevs[n], (uintptr_t)fd, EVFILT_READ,
               EV_ADD | EV_ENABLE | EV_ONESHOT, 0, 0, tok);
        n++;
    }
    if ((events & PAL_POLL_WRITE) && !had_write) {
        EV_SET(&kevs[n], (uintptr_t)fd, EVFILT_WRITE,
               EV_ADD | EV_ENABLE | EV_ONESHOT, 0, 0, tok);
        n++;
    }
    if (n > 0)
        rc = kevent(pfd, kevs, n, NULL, 0, NULL);
#elif defined(PAL_USE_EPOLL)
    (void)had_read;
    (void)had_write;
    struct epoll_event ev;
    ev.events = watch_events_of(w);
    ev.data.u64 = watch_encode(w);
    rc = epoll_ctl(pfd, is_new ? EPOLL_CTL_ADD : EPOLL_CTL_MOD, fd, &ev);
#endif
    if (rc < 0) {
        waiter_remove_idx(&w->read_head, &w->read_tail, added_r);
        waiter_remove_idx(&w->write_head, &w->write_tail, added_w);
        if (w->read_head < 0 && w->write_head < 0)
            watch_free(w);
        watch_unlock();
        return -1;
    }
    watch_unlock();
    return 0;
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
#if defined(PAL_USE_KQUEUE) || defined(PAL_USE_EPOLL)
    watch_lock();
    PalWatch *w = watch_find(pfd, fd);
    if (w == NULL) {
        watch_unlock();
        return -1;
    }
    int had_read = (w->read_head >= 0);
    int had_write = (w->write_head >= 0);
    if (events & PAL_POLL_READ)
        waiter_clear(&w->read_head, &w->read_tail);
    if (events & PAL_POLL_WRITE)
        waiter_clear(&w->write_head, &w->write_tail);
    int rc = 0;
#if defined(PAL_USE_KQUEUE)
    struct kevent kevs[2];
    int n = 0;
    if ((events & PAL_POLL_READ) && had_read) {
        EV_SET(&kevs[n], (uintptr_t)fd, EVFILT_READ, EV_DELETE, 0, 0, NULL);
        n++;
    }
    if ((events & PAL_POLL_WRITE) && had_write) {
        EV_SET(&kevs[n], (uintptr_t)fd, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
        n++;
    }
    if (n > 0)
        rc = kevent(pfd, kevs, n, NULL, 0, NULL);
    if (w->read_head < 0 && w->write_head < 0)
        watch_free(w);
#elif defined(PAL_USE_EPOLL)
    (void)had_read;
    (void)had_write;
    if (w->read_head < 0 && w->write_head < 0) {
        rc = epoll_ctl(pfd, EPOLL_CTL_DEL, fd, NULL);
        watch_free(w);
    } else {
        struct epoll_event ev;
        ev.events = watch_events_of(w);
        ev.data.u64 = watch_encode(w);
        rc = epoll_ctl(pfd, EPOLL_CTL_MOD, fd, &ev);
    }
#endif
    watch_unlock();
    return rc;
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
    int out_n = 0;
    watch_lock();
    for (int i = 0; i < n; i++) {
        PalWatch *w = watch_decode(pfd, (uint64_t)(uintptr_t)kevs[i].udata);
        if (w == NULL)
            continue;
        int is_write = (kevs[i].filter == EVFILT_WRITE);
        int *head = is_write ? &w->write_head : &w->read_head;
        int *tail = is_write ? &w->write_tail : &w->read_tail;
        uint32_t ev_bit = is_write ? PAL_POLL_WRITE : PAL_POLL_READ;
        void *u = NULL;
        while (out_n < max_events && waiter_pop(head, tail, &u)) {
            out[out_n].fd = w->fd;
            out[out_n].events = ev_bit;
            out[out_n].udata = u;
            out_n++;
        }
        /* EV_ONESHOT consumed this filter: re-arm if waiters remain. */
        if (*head >= 0) {
            struct kevent kev;
            EV_SET(&kev, (uintptr_t)w->fd, kevs[i].filter,
                   EV_ADD | EV_ENABLE | EV_ONESHOT, 0, 0, kevs[i].udata);
            (void)kevent(pfd, &kev, 1, NULL, 0, NULL);
        }
        if (w->read_head < 0 && w->write_head < 0)
            watch_free(w);
    }
    watch_unlock();
    return out_n;
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
    watch_lock();
    for (int i = 0; i < n; i++) {
        PalWatch *w = watch_decode(pfd, evs[i].data.u64);
        if (w == NULL)
            continue;
        uint32_t e = evs[i].events;
        void *u = NULL;
        if ((e & (EPOLLIN | EPOLLHUP | EPOLLERR)) != 0u) {
            while (out_n < max_events && waiter_pop(&w->read_head, &w->read_tail, &u)) {
                out[out_n].fd = w->fd;
                out[out_n].events = PAL_POLL_READ;
                out[out_n].udata = u;
                out_n++;
            }
        }
        if ((e & (EPOLLOUT | EPOLLERR)) != 0u) {
            while (out_n < max_events && waiter_pop(&w->write_head, &w->write_tail, &u)) {
                out[out_n].fd = w->fd;
                out[out_n].events = PAL_POLL_WRITE;
                out[out_n].udata = u;
                out_n++;
            }
        }
        /* EPOLLONESHOT consumed the registration: re-arm any surviving
           interest, or deregister the fd when both watchers are done. */
        if (w->read_head < 0 && w->write_head < 0) {
            epoll_ctl(pfd, EPOLL_CTL_DEL, w->fd, NULL);
            watch_free(w);
        } else {
            struct epoll_event rev;
            rev.events = watch_events_of(w);
            rev.data.u64 = watch_encode(w);
            epoll_ctl(pfd, EPOLL_CTL_MOD, w->fd, &rev);
        }
    }
    watch_unlock();
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
