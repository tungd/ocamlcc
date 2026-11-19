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
/* Remove a single waiter previously registered with pal_poller_watch on
 * (pfd, fd, events); other waiters on the same fd keep their registration.
 * Returns 0 if the waiter was found and removed, -1 otherwise. Removing the
 * last waiter unregisters the fd from the poller. */
int  pal_poller_unwatch_waiter(int pfd, int fd, uint32_t events, void *udata);
int  pal_poller_wait(int pfd, PalPollEvent *out, int max_events, int timeout_ms);

/* 5. Fiber context switching and non-blocking fd helpers. */

/* Callee-saved register frame saved by pal_ctx_swap (runtime/pal_ctx.S).
   The layout is ABI-specific: PAL_CTX_REGS sizes the frame to exactly what
   the assembly stores, and PAL_CTX_SP / PAL_CTX_PC index the stack-pointer
   and resume-address slots that pal_ctx_make initializes. The static asserts
   below pin the byte size against the assembly frame. */
#if defined(__riscv) && (__riscv_xlen == 64)
#define PAL_CTX_REGS 26 /* s0-s11, ra, sp, fs0-fs11 */
#define PAL_CTX_SP 13   /* sp at offset 104 */
#define PAL_CTX_PC 12   /* ra at offset 96 */
#elif defined(__aarch64__)
#define PAL_CTX_REGS 21 /* x19-x30, sp, d8-d15 */
#define PAL_CTX_SP 12   /* sp at offset 96 */
#define PAL_CTX_PC 11   /* lr (x30) at offset 88 */
#elif defined(__x86_64__) && defined(_WIN32)
#define PAL_CTX_REGS 30 /* rbx,rbp,rdi,rsi,r12-r15, rsp, rip, xmm6-xmm15 */
#define PAL_CTX_SP 8    /* rsp at offset 64 */
#define PAL_CTX_PC 9    /* rip at offset 72 */
#elif defined(__x86_64__)
#define PAL_CTX_REGS 8 /* rbx,rbp,r12-r15, rsp, rip */
#define PAL_CTX_SP 6   /* rsp at offset 48 */
#define PAL_CTX_PC 7   /* rip at offset 56 */
#else
#define PAL_CTX_REGS 1
#define PAL_CTX_SP 0
#define PAL_CTX_PC 0
#endif

typedef struct PalContext {
    uint64_t regs[PAL_CTX_REGS];
} PalContext;

#if defined(__riscv) && (__riscv_xlen == 64)
_Static_assert(sizeof(PalContext) == 208, "PalContext must match pal_ctx.S (riscv64)");
#elif defined(__aarch64__)
_Static_assert(sizeof(PalContext) == 168, "PalContext must match pal_ctx.S (aarch64)");
#elif defined(__x86_64__) && defined(_WIN32)
_Static_assert(sizeof(PalContext) == 240, "PalContext must match pal_ctx.S (win64)");
#elif defined(__x86_64__)
_Static_assert(sizeof(PalContext) == 64, "PalContext must match pal_ctx.S (x86_64 SysV)");
#endif

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
