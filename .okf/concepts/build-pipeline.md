---
type: Concept
title: Ninja build pipeline
description: How the top-level build.ninja orchestrates vendored QBE, the C runtime, dune, and end-to-end example compilation.
tags: [build, ninja, dune, qbe]
status: stable
generated:
  by: codex/1
  at: 2026-11-18
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
| `build/qbe/qbe` | `cc -c` each `vendor/qbe/*.c` (amd64 sysv/winabi, arm64/_apple, rv64, plus `gvn`/`gcm`/`ifopt`) → link. `config.h` is generated out-of-tree by `tools/gen-config.sh` (host default target). |
| `build/rt/libocamlrt.a` | `cc -c -fPIC` `runtime/*.c` (with `main_entry.c` separated from `builtins.c` so `.so`/`.dylib` libraries do not pull `main`) + `runtime/pal_ctx.S` → `ar rcs`. |
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

When compiling user projects without `build.ninja`, `ocamlcc build`
(`lib/driver.ml`) orchestrates the full pipeline in one command:
topological dependency ordering over `.mli`/`.ml` units via compiler-libs
`Depend` (allowing `.mli`-mediated mutual `.ml` dependencies via Tarjan SCC
condensation), automatic resolution of `ocamlcc`'s own `stdlib.cmi` (from
prebuilt `build/stdlib` on host or compiled from `stdlib/` into `work_dir/stdlib`
before user units, passing `--nostdlib` internally unless `--nostdlib` was
explicitly requested), `.cmi`/`.ssa` compilation, optional `.mli -> .h` +
`_shim.c` generation (`lib/c_bindgen.ml`, emitting an umbrella header +
`<stem>_<mod>.h` sub-headers when multiple `.mli`s are passed to `--emit-header`),
`qbe -t <target>` assembly, target C/xcrun/NDK toolchain compilation of
`runtime/` and `stdlib/` (excluding `main_entry.o` for library targets and
hiding internal runtime/stdlib symbols on `--shared` via Darwin
`-exported_symbols_list` / `-unexported_symbols_list` or ELF `--version-script`
/ `--exclude-libs,ALL`), and executable, shared, static, or `.xcframework`
packaging (only emitting/attaching `-headers` for `ios-xcframework` when a `.mli`
is present or `--emit-header` is explicitly passed).

# Executable startup

The executable initializes every explicitly linked implementation once, in dependency order. This includes units whose only effect is registration at startup.

# Installed driver

A staged Dune installation supplies the vendored QBE executable and core stdlib and runtime sources relative to the compiler prefix. The installed driver can build multi-unit executables outside the checkout.

# C record field names

Bindgen reserves legal record member names before escaping C and C++ keywords and resolving collisions. The header and conversion shim share the resulting field names.
