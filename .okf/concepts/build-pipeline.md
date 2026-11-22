---
type: Concept
title: Ninja build pipeline
description: How the top-level build.ninja orchestrates vendored QBE, the C runtime, dune, and end-to-end example compilation.
tags: [build, ninja, dune, qbe]
status: stable
generated:
  by: codex/1
  at: 2026-11-22
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
| `build/bin/occ` | `dune build bin/occ` (with `(public_name occ)` for `dune build -p ocamlcc`) → copy out of `_build/`. |
| `build/stdlib/libocamlstdlib.a` | `occ compile-mli` / `compile --mod` over `stdlib/*.ml` → `qbe` → `cc -c` → `ar rcs`. |
| `build/<name>` | `occ compile x.ml -o x.ssa` → `qbe x.ssa > x.s` → `cc x.s libocamlstdlib.a libocamlrt.a`. |
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

The Ninja build provides a temporary `build/bin/ocamlcc` alias for `occ`.

When compiling user projects without `build.ninja`, `occ build`
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

# Persisted export summaries

The bundled and compatibility archives ship a versioned `.a.opt` companion.
`compile --emit-opt` emits per-unit records with the SSA. `archive-opt`
combines the records for the archive and writes a `.exports` companion for
each loose object. The archive and object companions carry binary and
interface digests.

`occ build -c` publishes the unit's `.cmi` and `.exports` next to the
output object. The CMI and summary use the OCaml unit name. The summary
records the object basename, including a custom `-o` name. Consumers look up
metadata for the interface the typechecker selected, including interfaces
from `-I` and `--stdlib-dir`. Executable, object, and assembly builds can
consume the prebuilt stdlib archive summary. Loose object packs use the
per-unit companions.

Saturated calls can use the resolved entry, suspension, immediate-result,
and exception effects. Version 3 distinguishes calls that can propagate only
automatic finalizer exceptions. Version 2 records a boolean raising flag. Version 1
summaries are still readable and keep the conservative exception check.
Suspending callbacks retain shadow-stack protection. Partial
applications and calls without matching metadata use closure dispatch.
Persisted entry names identify the implementation and its call facts, so
relinking a previously optimized caller against a changed implementation
requires recompiling the caller. Inline bodies are available through the
in-process summary.

# Executable startup

The executable initializes every explicitly linked implementation once, in dependency order. This includes units whose only effect is registration at startup.

Each unit's generated `ocamlcc_init_<Mod>` first calls `ocamlcc_init_try_enter` on its `ocamlcc_global_<Mod>` slot (`0` uninitialized, `-2` claimed, other value published) and skips initialization if it does not win the claim. Units that mutually reference each other through their `.mli` interfaces recurse into each other's init functions; the runtime treats a same-thread re-entrant call as "already initializing here" (returns `0`, no spin), so the inner unit completes with whichever of its dependencies were initialized before the cycle re-entered. `ocamlcc_init_finish` publishes the unit value — or `0` when `ocamlcc_get_exn()` holds a raised exception, so the failure can be retried — and releases the claim.

# Driver modules

`Target` resolves host and cross targets, toolchain commands, and resource
paths. `Dep_graph` scans source dependencies and returns ordered interface
and implementation steps. It restores the caller's compiler-libs dependency
state after each scan. `Linker` owns native compilation commands, final
archive and linker arguments, symbol visibility, and XCFramework packaging.
`Driver` coordinates these operations with the compilation pipeline.

# Runtime objects

The default, single-thread, ASan and TSan archives include separate ARC,
slab, cycle, weak and primitive objects. The driver uses the same source
list to build a runtime for a different target or an installed toolchain.

The compiler uses the thread-safe ARC profile by default. Pass
`--single-thread-rc` to `build` to enable inline single-thread ARC and select
`libocamlrt_st.a` or build matching target objects. The driver test exercises
the prebuilt archive and the compiled-from-source path.

# Shared filesystem and process operations

`Sys_util` owns binary file IO, temporary file publication, directory
operations, and direct subprocess invocation for the compiler CLI and driver.
`write_if_changed` keeps an identical file in place and uses a same-directory
rename for new contents. Export summaries use the shared atomic writer.

# Installed driver

A staged Dune installation supplies the vendored QBE executable and core stdlib and runtime sources relative to the compiler prefix. The installed driver can build multi-unit executables outside the checkout.

# C record field names

Bindgen reserves legal record member names before escaping C and C++ keywords and resolving collisions. The header and conversion shim share the resulting field names.

# Linux runtime compilation

The Linux PAL and libc bindings request the default glibc interfaces before including headers. Strict C11 builds use these interfaces for the monotonic clock, anonymous mappings and mutex attributes.

# Missing toolchain executables

The driver returns a diagnostic naming an unavailable external tool, including xcrun when an iOS build runs on a Linux host.

# Generated C headers for Bigarray views

Array1, Array2, Array3, and Genarray bindings embed the common view type
definitions in the generated header.
Their module-prefixed import, inspection and ownership functions use the producing
library’s runtime. An imported handle can be passed directly to a matching typed
OCaml binding. See [memory views](/concepts/memory-views.md).

# Ninja shared-library linkage

The Ninja shared-library rule links libm for the math primitives it includes. Its C host can link the resulting shared library directly on Linux.

# Verified on Linux and macOS (2026-11-18)

The 14 Dune suites, 26 Ninja checks, 16 ASan/UBSan checks and installed core-stdlib driver smoke test pass on Ubuntu 24.04 arm64 with OCaml 5.5.2 and on macOS arm64 with OCaml 5.5.0. The macOS installed driver also passes the three-module Map.Make(String) registration test with the compatibility stdlib.

# Package companion

The [package catalog](/concepts/package-catalog.md) describes `tools/ocpkg.py`,
which vendors locked package sources and emits a separate Ninja file. Dune
excludes the generated `build/` tree, including vendored upstream projects.
The compiler CLI exposes `--runtime-objects-dir` to select a prebuilt runtime
directory explicitly; an empty directory forces compilation from runtime sources.
