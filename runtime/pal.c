/* pal.c — bootstrap POSIX implementation of the 6 PAL hooks. */
#include "pal.h"

#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

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

int pal_poll_wait(int *fds, int nfds, int timeout_ms)
{
    /* Phase 3 replaces this with kqueue/epoll; for now just report
       readiness so callers never block. */
    (void)timeout_ms;
    return nfds > 0 ? fds[0] : -1;
}

void *pal_memcpy(void *dst, const void *src, size_t n)
{
    return memcpy(dst, src, n);
}

void *pal_memset(void *dst, int c, size_t n) { return memset(dst, c, n); }
