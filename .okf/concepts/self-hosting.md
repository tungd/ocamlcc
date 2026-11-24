---
type: Concept
title: Self-hosting bootstrap
description: Stage 0 -> Stage 1 -> Stage 2 self-hosted compiler bootstrap, compiler-only stubs, and minimal-C / OCaml-first runtime boundary.
tags: [bootstrap, self-hosting, compiler-libs, runtime]
status: draft
generated:
  by: codex/1
  at: 2026-11-22
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

1. **Stage 0** — Ninja and host OCaml 5.5.0 build `build/bin/occ` (uses OCaml
   `ocamlopt` right-to-left evaluation order on tuple/cons arguments such as
   `Translprim.make_params`).
2. **Stage 1** — `stage0` compiles the canonical stdlib (78 modules with the ARC
   overlay), the 104-module transitive subset of OCaml
   5.5.0 `compiler-libs.common` (+ 4 `.mli`-only interfaces, fetched on demand
   from a SHA-256-pinned OCaml 5.5.0 release tarball), `bootstrap/unix/`, and
   the compiler modules listed in `tools/bootstrap.py`, linking against
   `libocamlrt.a` and compiler-only C
   stubs (`bootstrap/stubs/compiler_stubs.c` + `-lzstd`). Because `ocamlcc`
   emits left-to-right argument evaluation, the Stage 1 binary runs with
   `ocamlcc`'s own left-to-right semantics.
3. **Stage 2** — `stage1` compiles the same sources into `stage2/`.
4. **Stage 3 & fixed point (`ninja -j1 bootstrap`)** — `stage2` compiles the
   same modules into `stage3/`, verifies **428/428 bit-for-bit `.ssa` and
   `.s` equality** between `stage2` and `stage3`, and validates the Stage 2
   compiler across `hello`, `fib`, `closures`, `exn`, `mod_main`, `fiber_test`,
   `fiber_io`, `primitives_test`, `bindgen`, and ASan checks.

# Native compiler stack use

The ARC and QBE expression walkers keep allocation-heavy branches in their
own functions. The self-hosted ARM64 compiler exhausted the main native
stack while compiling the generated compiler-libs parser when those branches
shared the recursive dispatch frames. Replaying the same parser command
succeeded after the split at the default macOS stack size.

The native bootstrap compiler reserves a 64 MiB main stack on macOS.
Its Linux compiler-only startup code raises the soft stack limit up to
64 MiB within the existing hard limit. Compiling the compiler's C-call
registry can exceed the default stack during ANF conversion. Executables
that use the standalone ARC runtime keep their platform stack settings.

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
- `bootstrap/unix/` supplies the Unix operations used by the compiler and
  driver. It includes `lstat` with file modes and `chmod` so `Sys_util` can
  preserve permissions when atomically replacing an artifact. The native and
  sanitizer bootstrap stub tests compile and exercise the writer with this
  shim.

# Runtime boundary principle

Because `ocamlcc` has deterministic Perceus ARC without a tracing GC or
stop-the-world safepoints, non-kernel runtime subsystems (Digest, integer
parse/format, bulk Bytes/String/Array ops, buffered Channels, Marshal, Fiber
scheduler, `Sys`/`Callback`) can live in OCaml, keeping `runtime/` focused on
the irreducible C/asm kernel (`pal_ctx.S`, `pal.c`, ARC allocator/cycle
collector/weak/finalizers, `closure.c`, fiber stack/shadow-stack core, and thin
POSIX/libm/Bigarray primitives).

The bootstrap source order includes `Sys_util` and builds `Bounds`,
`Anf_ir`, `Anf_scalar`, and `Lambda_opt` ahead of the ANF converter.
`Arc_analysis` and `Arc_views` then build before the ownership transformer.
