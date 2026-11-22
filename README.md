# ocamlcc — OCaml to QBE with an ARC runtime

An alternative ahead-of-time (AOT) compiler backend and freestanding runtime
for OCaml. It reuses the official OCaml frontend (compiler-libs) and replaces
the tracing GC / multicore domain runtime with:

- **Perceus-style Automatic Reference Counting (ARC)** — deterministic
  reclamation, in-place constructor reuse, zero stop-the-world pauses.
- **Wren-style stackful fibers** — a single cooperative scheduler with
  deterministic ARC cleanup for abandoned fibers.
- **QBE** as the code generator (vendored at `vendor/qbe`), driven by a
  single compiler executable, `occ`.
- A **freestanding platform abstraction layer** (`runtime/pal.h`) so the core
  runtime depends on only 6 platform hooks.

See [.okf/](.okf/index.md) for the living knowledge bundle, including the
full design and roadmap.

## Status

Phases 1–5 complete (`ninja test`: 26/26, `ninja asan_test`: 16/16,
`dune runtest`: 14/14 passing).

`ocamlcc` compiles multi-module OCaml programs (`.mli` interfaces and `.ml`
implementations) to native binaries, shared/static libraries, and iOS
`.xcframework`s via a single CLI driver (`occ build --target <t>`) backed
by vendored QBE 1.3 with Perceus-style Automatic Reference Counting, a
freestanding 12-class slab allocator (returning empty 64 KB slabs to
`pal_page_free`) + opt-in trial-deletion cycle collector
(`ocamlcc_arc_collect` in `runtime/cycle.c`, synchronized with FFI mutator
gates), `.mli -> .h` C99 header & FFI shim generation (`occ bindgen`,
surfacing OCaml exceptions via `ocamlcc_error_t *`), Wren-style stackful
fibers + cooperative `kqueue`/`epoll` async I/O poller with yield-effect
shadow-stack lowering (`runtime/fiber.c`, `runtime/pal_ctx.S`, `Stdlib.Fiber`),
error-return exceptions (`try ... with`), `Weak.t`, unboxed `float`/`float
array` and boxed `Int32`/`Int64`/`Nativeint`, compiler warnings on cyclic
non-pure mutual `let rec` closures, and an ARC-native core standard library
built from the pinned upstream OCaml stdlib, the ARC overlay, and `Stdlib.Fiber`.
`runtime/builtins.c` provides the POSIX/libc/libm/pthread OS helpers for stdlib I/O, sync, and crypto, while `runtime/main_entry.c` stays minimal. Unsupported OCaml features include objects/methods (`Lsend`), ephemerons, backtraces, signal handlers, and `Marshal.Closures`.

## Build

Source builds use OCaml 5.5.x, Dune, Ninja, Make, Python 3, and a host C
compiler. Building `ocpkg` also uses libcurl development headers. A Dune
installation includes both binaries, QBE, and the canonical stdlib and
runtime sources. A C toolchain is needed on the consumer host. The default
Ninja build supplies a prebuilt host archive in `build/stdlib`. Use
`--stdlib-dir` to select a prebuilt pack explicitly.

The whole project is driven by [ninja](https://ninja-build.org):

```sh
ninja            # QBE, ARC runtime, occ, ocpkg, stdlib and examples
ninja smoke      # compile examples/hello.ml end-to-end and run it
ninja test       # run the examples, PIC/DSO, bindgen and concurrent FFI checks
ninja asan_test  # run ASan+UBSan runtime checks
dune runtest     # run compiler, driver, and package-manager tests
ninja -t clean   # remove build/
```

The `ninja test` fixtures include `hello`, `fib`, `tail`, `bools`,
`strings`, `match`, `mutual`, `adt`, `closures`, `loops`, `arrays_bytes`,
`arc_test`, `exn`, `weak_cycle`, `cycle_collect` (trial-deletion cycle
collector), `mod_main` (multi-module `.mli`/`.ml` linking), `stdlib_test`
(core `stdlib/` modules with `arc_delta = 0`), `fiber_test` (Wren coroutines,
cooperative scheduler, abandoned-fiber shadow-stack cleanup, fiber exceptions),
`fiber_io` (non-blocking pipe async I/O via `kqueue`/`epoll`), `qbe_pic_check`
(ARM64/AMD64 PIC GOT/PLT output), `pic_so` (shared library + C host),
`mt_ffi` (8-thread FFI + concurrent cycle collector stress), `tupled_letrec`
(`Tupled` functions and `value let rec`), `primitives_test` (`float`,
`float array`, `Int32`/`Int64`/`Nativeint`, `Printf` numeric formatters),
`bindgen` (`.mli -> .h` C99 shim + `ocamlcc_error_t` host verification),
and `stdlib_runtime` (Marshal malformed-input cleanup/cycles and Bigarray
backing lifetime).

The pipeline:

1. `vendor/qbe/*.c` → `build/qbe/qbe` (host target selected by
   `tools/gen-config.sh`)
2. `runtime/*.c` → `build/rt/libocamlrt.a`
3. `dune build` → `build/bin/occ` (OCaml compiler-libs frontend, ANF,
   Perceus ARC pass, QBE IL writer)
4. `vendor/ocaml-stdlib/src/` with the `stdlib/` overlay → `build/stdlib/libocamlstdlib.a` and `build/stdlib.sources`
5. `examples/*.ml` → `.ssa` (occ) → `.s` (qbe) → native executable (cc)

## Toolchain bundle

`ninja -j1 dist` creates `build/dist/occ-<os>-<arch>.tar.gz`. Extract it
to a directory of your choice and add its `bin/` directory to `PATH`.
`occ` and `ocpkg` find QBE, the stdlib, the ARC runtime profiles, and the
package snapshot under `lib/occ/` relative to the executable.

```sh
ocpkg init my-app
ocpkg add cmdliner
ocpkg build
ocpkg run
```

`add`, `get`, and `vendor` can download locked sources. Use
`vendor --offline` to require cached archives. Builds use vendored
sources and content-addressed caches.
[Package commands and compatibility checks](packages/README.md)

## Upstream standard library

The pinned OCaml 5.5.0 sources and `lib-*` tests live under
`vendor/ocaml-stdlib/`; `stdlib/overlay/` provides ARC-specific replacements.
The default archive builds 78 modules, including the ARC helpers and
`Stdlib.Fiber`. The generated source bundle carries the same inputs for
cross-compilation and source-only installations.

```sh
ninja -j1 stdlib_compat                 # run upstream tests and API regressions against the default archive
python3 tools/stdlib_compat.py --skip-tests
python3 tools/stdlib_regressions.py     # generated lexer/parser and Bigarray/Marshal API tests
python3 tools/stdlib_regressions.py --stock
python3 tools/stdlib_compat.py --reuse-stdlib --tests 'lib-bigarray/*' 'lib-marshal/*'
```

The upstream runner links native tests to the default archive and ARC
runtime. It records every result in `build/stdlib_compat/report.md` and `.json`,
with full command logs. Its exit code reports whether the matrix completed;
consult the report for individual failures and skips. It skips toplevel expect
tests, C-stub tests, and unsupported ocamltest directives. Tests execute in
copied working directories. Repository API regressions return nonzero on failure.

On macOS arm64 with OCaml 5.5.0, 68 of 77 standalone upstream tests pass,
nine fail, and 42 additional files are skipped. All 11 repository API fixtures
pass on both stock OCaml and ocamlcc. ARC runs ordinary and last callbacks at
explicit major collections and at function or loop polls once enough allocation
has occurred. An ordinary callback can resurrect the original object. Last
callbacks run after its weak slots clear.

Lexing and Parsing use pure OCaml table interpreters. Bigarray views retain a
shared ARC backing buffer. Marshal reads/writes the standard uncompressed
format, preserves sharing/cycles, and supports Bigarray payloads; functional
values raise `Invalid_argument` even with `Marshal.Closures`. Upstream tests
that require native closure serialization or compression are outside that
implementation scope. See [.okf/concepts/stdlib-compatibility.md](.okf/concepts/stdlib-compatibility.md)
for current coverage and [tests/stdlib/README.md](tests/stdlib/README.md)
for reproducible fixtures.

## Layout

```
bin/          ocamlcc CLI (compile, compile-mli, dump-lambda)
lib/          QBE IL model + printer, Lambda frontend, ANF, ARC pass, codegen
stdlib/       ARC-native core standard library modules
runtime/      freestanding C runtime: pal.h/c, pal_ctx.S, arc.h/c, closure.c, fiber.h/c, builtins.c, main_entry.c
vendor/qbe/   vendored QBE 1.3 (source drop, built out-of-tree by ninja)
test/         compiler unit/IR/negative test suites (dune runtest)
examples/     example programs
tests/        expected outputs and C FFI hosts (ninja test / ninja asan_test)
.okf/         OKF knowledge bundle: design, decisions, roadmap
tools/        build helpers
```

## Usage

```sh
build/bin/occ build examples/mod_main.ml examples/mod_lib.ml examples/mod_lib.mli -o build/mod_app
build/bin/occ build --shared --emit-header build/mod_lib.h examples/mod_lib.mli examples/mod_lib.ml -o build/libmod_lib.dylib
build/bin/occ build --target ios-xcframework --nostdlib -I build/stdlib examples/bindgen_lib.mli examples/bindgen_lib.ml -o build/BindgenLib.xcframework
build/bin/occ bindgen examples/bindgen_lib.mli -o build/bindgen_lib.h --shim build/bindgen_lib_shim.c
build/bin/occ compile examples/hello.ml -o build/hello.ssa
build/bin/occ compile --nostdlib -I build/stdlib examples/stdlib_test.ml -o build/stdlib_test.ssa
build/bin/occ compile-mli examples/mod_lib.mli -o build/mod_lib.cmi
build/bin/occ dump-lambda examples/hello.ml
```

## Package companion MVP

[`ocpkg`](packages/README.md) vendors a curated, hash-pinned package closure,
queries its metadata, and emits Ninja rules. Its first target builds
`ocaml-crunch` 4.1.0 with ocamlcc from upstream sources plus an explicit Unix
adapter. See the [design and plan](.okf/concepts/package-catalog.md) and
[macOS arm64 compatibility evidence](packages/evidence/crunch-macos-arm64.json).
