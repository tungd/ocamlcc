---
type: Concept
title: Platform abstraction layer
description: The 6 freestanding hooks (pal.h) the entire C runtime depends on.
tags: [runtime, c, freestanding, pal]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-19
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

`runtime/pal.h` groups platform support under six areas. ARC, fibers,
and the scheduler build on these services.[^design-doc]

1. `pal_page_alloc`, `pal_page_alloc_aligned`, and `pal_page_free` map
   and unmap pages through the platform's POSIX APIs.
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
event polling behind `pal_poller_*` and `pal_poll_wait`. Both `kqueue` and `epoll` share a
fixed-slot `PalWatch`/`PalWaiter` registry keyed by `(gen << 32) | idx` tokens so slots never move
or alias across `watch_free`, multiple waiters on the same `(fd, direction)` queue cleanly in FIFO
order without overwriting `udata`, and `pal_poller_wait` enforces `out_n < max_events` per emitted
event while re-arming any remaining one-shot waiters. `runtime/pal_ctx.S` implements callee-saved
register switching (`pal_ctx_make` / `pal_ctx_swap`) for `arm64`, x86-64 SysV, Win64, and RISC-V 64.
The `PalContext` frame is sized per ABI by the `PAL_CTX_REGS` / `PAL_CTX_SP` / `PAL_CTX_PC` ladder in
`runtime/pal.h` (with `_Static_assert`s pinning the byte sizes) so it exactly covers what
`pal_ctx_swap` stores — aarch64 168 B (`x19-x30`, `sp`, `d8-d15`), x86-64 SysV 64 B
(`rbx`, `rbp`, `r12-r15`, `rsp`, `rip`), Win64 240 B (the SysV GP set plus `rdi`/`rsi` and
callee-saved `xmm6`-`xmm15`, restored across switches per the Windows x64 ABI), and RISC-V 64
208 B (`s0-s11`, `ra`, `sp`, `fs0-fs11`). `pal_ctx_make` initializes the `PAL_CTX_SP`/`PAL_CTX_PC`
slots for every implemented ABI (16-byte-aligned top of stack, SysV/Win64 also reserving the
8-byte return-slot slop). `test/pal_ctx_abi_test.ml` pins the contract from both sides: it parses
each `pal_ctx_swap` section (store extent, sp/pc slots, callee-saved FP registers) and cross-checks
it against the `pal.h` ladder plus forced-branch compile probes of all four ABIs, so the assembly
frame, the struct size, and `pal_ctx_make` cannot drift apart per architecture.

`pal_page_alloc_aligned` provides aligned slab mappings. When the requested
alignment exceeds the system page size, PAL maps extra whole pages and trims
the prefix and suffix. `pal_page_free` releases the retained range using
the requested slab size.
