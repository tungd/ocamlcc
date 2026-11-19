---
type: Concept
title: Self-hosting bootstrap
description: Stage 0 -> Stage 1 -> Stage 2 self-hosted compiler bootstrap, compiler-only stubs, and minimal-C / OCaml-first runtime boundary.
tags: [bootstrap, self-hosting, compiler-libs, runtime]
status: draft
generated:
  by: antigravity/1
  at: 2026-11-19
sources:
  - id: compiler-stubs
    resource: ../bootstrap/stubs/compiler_stubs.c
    title: Compiler-only libzstd and compiler-libs C stubs
  - id: bootstrap-unix
    resource: ../bootstrap/unix/unix.ml
    title: Minimal Unix compatibility shim for self-hosted driver
  - id: fetch-compiler-libs
    resource: ../tools/fetch-ocaml-compiler-libs.py
    title: On-demand SHA-256-pinned OCaml 5.5.0 compiler-libs.common fetcher
  - id: bootstrap-runner
    resource: ../tools/bootstrap.py
    title: Multi-stage self-hosting bootstrap orchestrator (Stage 1, Stage 2, fixed-point diff)
---

# Architecture

Self-hosting compiles `ocamlcc` and its entire closure into a standalone native
binary running on `ocamlcc`'s Perceus ARC runtime (zero host OCaml runtime or
tracing GC):

1. **Stage 0** — host Dune/OCaml 5.5.0 builds `build/bin/ocamlcc`.
2. **Stage 1** — `stage0` compiles `stdlib_compat` (72 modules), the 104-module
   transitive subset of OCaml 5.5.0 `compiler-libs.common` (+ 4 `.mli`-only
   interfaces, fetched on demand from a SHA-256-pinned OCaml 5.5.0 release
   tarball), `bootstrap/unix/`, and `ocamlcc` (16 modules), linking against
   `libocamlrt.a` and compiler-only C stubs (`bootstrap/stubs/compiler_stubs.c`
   + `-lzstd`).
3. **Stage 2** — `stage1` compiles the exact same ~193 modules and verifies
   bit-for-bit `.ssa` and `.s` fixed-point equality against Stage 1.

# Compiler-only stubs & zstd isolation

Matching upstream OCaml, `libzstd` is never compiled into or linked with
`libocamlrt.a` or user programs:

- `runtime/marshal.inc` only implements generic `0x8495a6bd` VLQ framing and
  nullable codec hook pointers (`ocamlcc_marshal_register_codec`, default
  `NULL`).
- `bootstrap/stubs/compiler_stubs.c` implements `caml_zstd_initialize` (which
  registers `ZSTD_decompress`/`ZSTD_compress` at `Compression` init time) plus
  the three other `compiler-libs.common` C primitives
  (`caml_sys_get_stdlib_dirs`, `caml_sys_time_include_children`,
  `caml_terminfo_rows`).
- `bootstrap/unix/` provides the 11 `Unix` functions used by `lib/driver.ml`
  (`lstat`, `rmdir`, `unlink`, `openfile`, `close`, `pipe ~cloexec`,
  `in_channel_of_descr`, `create_process`, `waitpid`, `error_message`, and
  `stdin`/`stdout`/`stderr`), leaving `lib/driver.ml` and host Dune builds
  unchanged.

# Runtime boundary principle

Because `ocamlcc` has deterministic Perceus ARC without a tracing GC or
stop-the-world safepoints, non-kernel runtime subsystems (Digest, integer
parse/format, bulk Bytes/String/Array ops, buffered Channels, Marshal, Fiber
scheduler, `Sys`/`Callback`) can live in OCaml, keeping `runtime/` focused on
the irreducible C/asm kernel (`pal_ctx.S`, `pal.c`, ARC allocator/cycle
collector/weak/finalizers, `closure.c`, fiber stack/shadow-stack core, and thin
POSIX/libm/Bigarray primitives).
