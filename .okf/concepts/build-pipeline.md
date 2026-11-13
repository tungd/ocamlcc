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
| `build/rt/libocamlrt.a` | `cc -c` `runtime/*.c` → `ar rcs`. |
| `build/bin/ocamlcc` | `dune build bin/ocamlcc` → copy out of `_build/`. |
| `build/<name>` | `ocamlcc compile x.ml -o x.ssa` → `qbe x.ssa > x.s` → `cc x.s libocamlrt.a`. |

`ninja smoke` builds and runs `build/hello`; the default target builds all
artifacts. All outputs stay under the gitignored `build/` directory —
nothing is ever written into `vendor/qbe` or `_build` by ninja itself.

# Decisions and gotchas

- **QBE writes assembly to stdout** — upstream `qbe` has no `-o` flag; the
  pipeline redirects (`qbe x.ssa > x.s`).
- **`ret <val>` requires a return class** — QBE rejects `ret %x` inside
  functions declared without one (`function $f()` implies `rcls == K0`).
  The module initializer is therefore a void function ending in bare `ret`.
- **Ninja does not re-tokenize expanded variables** — a variable used in a
  path list must itself be a single path; lists are spelled out inline.
- **dune wraps libraries by default** — `lib/dune` sets `wrapped false` so
  the CLI can reference `Pipeline`, `Codegen`, etc. directly.

When the compiler grows (see [roadmap](/concepts/roadmap.md)), embedding QBE
into the `ocamlcc` executable (design goal "single binary") will replace the
subprocess step; the ninja structure above stays otherwise unchanged.
