/*
 * pal.h — Platform Abstraction Layer (design doc §4.5).
 *
 * The entire C runtime depends on only these hooks. The POSIX
 * implementation in pal.c is a bootstrap; Phase 2 replaces it with
 * freestanding syscall shims on Linux and libSystem/Bionic glue on
 * iOS/Android.
 */
#ifndef OCAMLCC_PAL_H
#define OCAMLCC_PAL_H

#include <stddef.h>
#include <stdint.h>

/* 1. Page allocation (mmap/munmap on Linux; libSystem/Bionic on mobile). */
void *pal_page_alloc(size_t size);
void  pal_page_free(void *ptr, size_t size);
int   pal_page_protect_none(void *ptr, size_t size);

/* 2. Abnormal termination (exit_group syscall / __builtin_trap). */
void pal_abort(void) __attribute__((noreturn));

/* 3. Monotonic clock in nanoseconds (clock_gettime). */
uint64_t pal_monotonic_ns(void);

/* 4. Event poller (epoll / kqueue). */
#define PAL_POLL_READ  1u
#define PAL_POLL_WRITE 2u

typedef struct PalPollEvent {
    int      fd;
    uint32_t events;
    void    *udata;
} PalPollEvent;

int  pal_poll_wait(int *fds, int nfds, int timeout_ms);
int  pal_poller_create(void);
void pal_poller_close(int pfd);
int  pal_poller_watch(int pfd, int fd, uint32_t events, void *udata);
int  pal_poller_unwatch(int pfd, int fd, uint32_t events);
int  pal_poller_wait(int pfd, PalPollEvent *out, int max_events, int timeout_ms);

/* 5. Fiber context switching and non-blocking fd helpers. */
typedef struct PalContext {
    uint64_t regs[22];
} PalContext;

void pal_ctx_make(PalContext *ctx, void *stack_top, void (*entry)(void));
void pal_ctx_swap(PalContext *from, PalContext *to);

int     pal_pipe(int fds[2]);
int     pal_fd_set_nonblock(int fd);
int64_t pal_fd_read(int fd, void *buf, size_t len);
int64_t pal_fd_write(int fd, const void *buf, size_t len);
void    pal_fd_close(int fd);
void    pal_stderr_write(const void *buf, size_t len);

/* 6. Memory primitives (freestanding fallback or platform libc). */
void *pal_memcpy(void *dst, const void *src, size_t n);
void *pal_memset(void *dst, int c, size_t n);

/* 7. Minimal libm subset is resolved at link time; no PAL wrapper yet. */

#endif /* OCAMLCC_PAL_H */
