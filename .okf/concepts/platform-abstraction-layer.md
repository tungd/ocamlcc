---
type: Concept
title: Platform abstraction layer
description: The 6 freestanding hooks (pal.h) the entire C runtime depends on.
tags: [runtime, c, freestanding, pal]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-15
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: rt-pal
    resource: ../runtime/pal.h
    title: pal.h — platform abstraction layer
  - id: rt-pal-c
    resource: ../runtime/pal.c
    title: pal.c — POSIX/kqueue/epoll PAL implementation
  - id: rt-pal-ctx
    resource: ../runtime/pal_ctx.S
    title: pal_ctx.S — arm64 and x86_64 context switching
---

# Schema

`runtime/pal.h` declares exactly 6 hooks; everything else in the runtime
(ARC, fibers, scheduler) is freestanding C on top of them[^design-doc]:

1. `pal_page_alloc` / `pal_page_free` — mmap/munmap on Linux; libSystem /
   Bionic on mobile.
2. `pal_abort` — `exit_group` syscall / `__builtin_trap()`.
3. `pal_monotonic_ns` — `clock_gettime`.
4. `pal_poll_wait` — epoll / kqueue / libdispatch.
5. `pal_memcpy` / `pal_memset` — freestanding fallback or platform libc.
6. Minimal libm subset for floating-point intrinsics (resolved at link
   time).

# Status

`runtime/pal.c` implements POSIX `mmap`/`munmap` (`pal_page_alloc`/`pal_page_free`),
`clock_gettime` (`pal_monotonic_ns`), `abort` (`pal_abort`), `memcpy`/`memset`,
non-blocking pipe/fd helpers, `pal_stderr_write`, and real `kqueue` (Darwin/BSD) / `epoll` (Linux)
event polling behind `pal_poll_wait`. `runtime/pal_ctx.S` implements callee-saved
register switching (`pal_ctx_init` / `pal_ctx_swap`) for `arm64` and `x86_64`.
