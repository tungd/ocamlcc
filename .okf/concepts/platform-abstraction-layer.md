---
type: Concept
title: Platform abstraction layer
description: The 6 freestanding hooks (pal.h) the entire C runtime depends on.
tags: [runtime, c, freestanding, pal]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-13
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: rt-pal
    resource: ../runtime/pal.h
    title: pal.h — platform abstraction layer
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

`runtime/pal.c` is a bootstrap POSIX implementation (mmap, clock_gettime,
abort, memcpy/memset). `pal_poll_wait` is a stub until the Phase 3 event
loop. Freestanding syscall implementations on Linux land with the Phase 2
slab allocator work.
