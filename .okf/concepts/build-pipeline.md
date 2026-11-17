---
type: Concept
title: Ninja build pipeline
description: How the top-level build.ninja orchestrates vendored QBE, the C runtime, dune, and end-to-end example compilation.
tags: [build, ninja, dune, qbe]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-13
sources:
  - id: build-ninja
    resource: ../build.ninja
    title: Top-level ninja build pipeline
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
stale_after: 2027-02-13
---

# Design

One checked-in `build.ninja` drives everything[^build-ninja]:

| Artifact | Rule chain |
|----------|------------|
| `build/qbe/qbe` | `cc -c` each `vendor/qbe/*.c` (all three targets: amd64, arm64, rv64) → link. `config.h` is generated out-of-tree by `tools/gen-config.sh` (host default target). |
| `build/rt/libocamlrt.a` | `cc -c` `runtime/*.c` + `runtime/pal_ctx.S` → `ar rcs`. |
| `build/bin/ocamlcc` | `dune build bin/ocamlcc` (with `(public_name ocamlcc)` for `dune build -p ocamlcc`) → copy out of `_build/`. |
| `build/stdlib/libocamlstdlib.a` | `ocamlcc compile-mli` / `compile --mod` over `stdlib/*.ml` → `qbe` → `cc -c` → `ar rcs`. |
| `build/<name>` | `ocamlcc compile x.ml -o x.ssa` → `qbe x.ssa > x.s` → `cc x.s libocamlstdlib.a libocamlrt.a`. |
| `build/asan/<name>` | ASan + UBSan (`-fsanitize=address,undefined -fno-sanitize-recover=all`) runtime `build/asan/rt/libocamlrt.a` linked with compiled examples. |

`ninja smoke` builds and runs `build/hello`; `ninja test` runs all checked
tests by redirecting `$builddir/$name > $builddir/$name.out` before `diff` so
non-zero exit codes never fail silently; `ninja asan_test` runs key runtime-heavy
examples under ASan+UBSan; `dune runtest` runs the compiler unit, IR, and
negative diagnostic tests in `test/`; `.github/workflows/ci.yml` runs all
three suites on both Linux (epoll) and macOS (kqueue). All outputs stay under
the gitignored `build/` directory — nothing is ever written into `vendor/qbe`
or `_build` by ninja itself.

# Decisions and gotchas

- **QBE jumps never carry arguments** — loop-carried values flow through
  **phi instructions** in a dedicated `@loop` header block, and QBE forbids
  jumping to a function's start block outright. The compiler therefore
  emits `@start → @loop` with per-parameter phis (see
  [compiler-pipeline](/concepts/compiler-pipeline.md)).
- **QBE writes assembly to stdout** — upstream `qbe` has no `-o` flag; the
  pipeline redirects (`qbe x.ssa > x.s`).
- **`ret <val>` requires a return class** — QBE rejects `ret %x` inside
  functions declared without one (`function $f()` implies `rcls == K0`).
  Value-returning functions are declared `function l $f(...)`; the module
  initializer is void.
- **Ninja does not re-tokenize expanded variables** — a variable used in a
  path list must itself be a single path; lists are spelled out inline.
- **dune wraps libraries by default** — `lib/dune` sets `wrapped false` so
  the CLI can reference `Pipeline`, `Codegen`, etc. directly.
- **Vendored tarballs restore old mtimes** — after re-vendoring QBE, run
  `ninja -t clean` or ninja will happily link stale objects.

When the compiler grows (see [roadmap](/concepts/roadmap.md)), embedding QBE
into the `ocamlcc` executable (design goal "single binary") will replace the
subprocess step; the ninja structure above stays otherwise unchanged.
