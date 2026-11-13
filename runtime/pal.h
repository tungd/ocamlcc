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

/* 2. Abnormal termination (exit_group syscall / __builtin_trap). */
void pal_abort(void) __attribute__((noreturn));

/* 3. Monotonic clock in nanoseconds (clock_gettime). */
uint64_t pal_monotonic_ns(void);

/* 4. Event poller (epoll / kqueue / libdispatch). Stub until Phase 3. */
int pal_poll_wait(int *fds, int nfds, int timeout_ms);

/* 5. Memory primitives (freestanding fallback or platform libc). */
void *pal_memcpy(void *dst, const void *src, size_t n);
void *pal_memset(void *dst, int c, size_t n);

/* 6. Minimal libm subset is resolved at link time; no PAL wrapper yet. */

#endif /* OCAMLCC_PAL_H */
