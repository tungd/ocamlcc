---
type: Concept
title: Getting started with ocamlcc
description: How to build the project, run the end-to-end smoke test, and where the pieces live.
tags: [build, quickstart]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-13
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: build-ninja
    resource: ../build.ninja
    title: Top-level ninja build pipeline
  - id: readme
    resource: ../README.md
    title: Project README
---

# Getting started

Requirements: OCaml 5.3+ (opam switch), dune >= 3.0, a C compiler, and
[ninja](https://ninja-build.org).

## Build

```sh
ninja            # vendored QBE + ARC/fiber runtime + ocamlcc compiler + examples
ninja smoke      # compile examples/hello.ml end-to-end and run it
ninja -t clean   # remove build/
```

One `ninja` invocation produces, in order (see [build-pipeline]):

1. `build/qbe/qbe` — the vendored QBE executable[^build-ninja]
2. `build/rt/libocamlrt.a` — the C runtime (PAL, ARC, fibers, builtins)
3. `build/bin/ocamlcc` — the compiler CLI, built by dune
4. `build/hello` — an example OCaml program compiled to a native binary

The [smoke test](/concepts/build-pipeline.md) exercises the full
[compiler pipeline](/concepts/compiler-pipeline.md): `hello.ml` → Lambda →
QBE IL → arm64/AMD64 assembly → linked executable.

## CLI

```sh
build/bin/ocamlcc compile examples/hello.ml -o build/hello.ssa  # emit QBE IL
build/bin/ocamlcc dump-lambda examples/hello.ml                 # dump Lambda IR
```

## Layout

| Path | Contents |
|------|----------|
| `bin/` | CLI entry point (`compile`, `dump-lambda`) |
| `lib/` | `Qbe_il` (IL model + printer), `Frontend`, `Codegen`, `Builtins`, `Pipeline` |
| `runtime/` | `pal.h/.c`, `arc.h/.c`, `fiber.h/.c`, `builtins.c` |
| `vendor/qbe/` | vendored QBE source (see [vendored-qbe]) |
| `examples/` | example programs |
| `docs/design.md` | canonical design document |
| `.okf/` | this knowledge bundle |

[build-pipeline]: /concepts/build-pipeline.md
[vendored-qbe]: /concepts/vendored-qbe.md
[^build-ninja]: The ninja rules, artifact paths, and flags live in
  `build.ninja` and are the authority for build behavior.
