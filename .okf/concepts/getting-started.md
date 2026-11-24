---
type: Concept
title: Getting started with ocamlcc
description: How to build the project, run the end-to-end smoke test, and where the pieces live.
tags: [build, quickstart]
status: stable
generated:
  by: codex/1
  at: 2026-11-18
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

Build with OCaml 5.5.x, a C compiler, Python 3.10+, Ninja, and libcurl
development headers.

## Build

```sh
ninja            # vendored QBE + ARC/fiber runtime + ocamlcc compiler + examples
ninja smoke      # compile examples/hello.ml end-to-end and run it
ninja test       # run compiler, package-manager and native end-to-end tests
ninja test_host  # run compiler unit, IR, and driver suites
ninja asan_test  # run runtime-heavy examples under ASan + UBSan
ninja -t clean   # clean generated build outputs
```

One `ninja` invocation produces, in order (see [build-pipeline]):

1. `build/qbe/qbe` — the vendored QBE executable[^build-ninja]
2. `build/rt/libocamlrt.a` — the C runtime (PAL, ARC, fibers, builtins)
3. `build/bin/occ` and `build/bin/ocpkg` — the host tools built with `ocamlopt`
4. `build/hello` — an example OCaml program compiled to a native binary

The [smoke test](/concepts/build-pipeline.md) exercises the full
[compiler pipeline](/concepts/compiler-pipeline.md): `hello.ml` → Lambda →
QBE IL → arm64/AMD64 assembly → linked executable.

## CLI

```sh
build/bin/occ build examples/mod_main.ml examples/mod_lib.ml examples/mod_lib.mli -o build/mod_app
build/bin/occ build --shared --emit-header build/mod_lib.h examples/mod_lib.mli examples/mod_lib.ml -o build/libmod_lib.dylib
build/bin/occ bindgen examples/bindgen_lib.mli -o build/bindgen_lib.h --shim build/bindgen_lib_shim.c
build/bin/occ compile examples/hello.ml -o build/hello.ssa  # emit QBE IL
build/bin/occ dump-lambda examples/hello.ml                 # dump Lambda IR
```

## Layout

| Path | Contents |
|------|----------|
| `bin/` | CLI entry point (`build`, `compile`, `compile-mli`, `bindgen`, `dump-lambda`) |
| `lib/` | `Qbe_il`, `Frontend`, `Lambda_opt`, `Anf`, `Anf_ir`, `Anf_scalar`, `Arc_analysis`, `Arc_views`, `Arc_pass`, `Ccalls`, `C_bindgen`, `Driver`, `Codegen`, `Builtins`, `Pipeline` |
| `runtime/` | `pal.h/.c`, `arc.h/.c`, `fiber.h/.c`, `builtins.c` |
| `vendor/qbe/` | vendored QBE source (see [vendored-qbe]) |
| `examples/` | example programs |
| `docs/design.md` | canonical design document |
| `.okf/` | this knowledge bundle |

[build-pipeline]: /concepts/build-pipeline.md
[vendored-qbe]: /concepts/vendored-qbe.md
[^build-ninja]: The ninja rules, artifact paths, and flags live in
  `build.ninja` and are the authority for build behavior.

# Clean-checkout tests

`ninja test` works from a clean checkout. Ninja builds the host test
executables alongside the vendored QBE and stdlib source bundle used by
the driver integration suite.
