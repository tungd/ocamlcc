# ocamlcc — OCaml to QBE with an ARC runtime

An alternative ahead-of-time (AOT) compiler backend and freestanding runtime
for OCaml. It reuses the official OCaml frontend (compiler-libs) and replaces
the tracing GC / multicore domain runtime with:

- **Perceus-style Automatic Reference Counting (ARC)** — deterministic
  reclamation, in-place constructor reuse, zero stop-the-world pauses.
- **Wren-style stackful fibers** — a single cooperative scheduler with
  deterministic ARC cleanup for abandoned fibers.
- **QBE** as the code generator (vendored at `vendor/qbe`), driven by a
  single compiler executable.
- A **freestanding platform abstraction layer** (`runtime/pal.h`) so the core
  runtime depends on only 6 platform hooks.

See [.okf/](.okf/index.md) for the living knowledge bundle, including the
full design and roadmap.

## Status

Phases 1, 2, 3, and 5 complete (`ninja test`: 24/24, `ninja asan_test`: 14/14,
`dune runtest`: 12/12 passing).

`ocamlcc` compiles multi-module OCaml programs (`.mli` interfaces and `.ml`
implementations) to native binaries and PIC shared libraries via vendored QBE
1.3 with Perceus-style Automatic Reference Counting, a freestanding 12-class
slab allocator (returning empty 64 KB slabs to `pal_page_free`) + opt-in
trial-deletion cycle collector (`ocamlcc_arc_collect` in `runtime/arc.c`,
synchronized with FFI mutator gates), Wren-style stackful fibers +
cooperative `kqueue`/`epoll` async I/O poller with yield-effect shadow-stack
lowering (`runtime/fiber.c`, `runtime/pal_ctx.S`, `Stdlib.Fiber`), error-return
exceptions (`try ... with`), `Weak.t`, unboxed `float`/`float array` and boxed
`Int32`/`Int64`/`Nativeint`, compiler warnings on cyclic non-pure mutual `let
rec` closures, and an ARC-native core standard library (`stdlib/` →
`build/stdlib/libocamlstdlib.a`: `Option`, `Result`, `List`, `Array`, `Bytes`,
`String`, `Buffer`, `Hashtbl`, `Int32`, `Int64`, `Nativeint`, `Printf`, `Weak`,
`Fiber`, `CamlinternalFormatBasics`, `Stdlib`). `runtime/builtins.c` and
`runtime/main_entry.c` stay minimal.

## Build

The whole project is driven by [ninja](https://ninja-build.org):

```sh
ninja            # vendored QBE 1.3 + ARC/fiber runtime + ocamlcc compiler + examples
ninja smoke      # compile examples/hello.ml end-to-end and run it
ninja test       # run all 24 ninja checks (examples, PIC/DSO, multi-threaded FFI)
ninja asan_test  # run 14 ASan+UBSan runtime checks
dune runtest     # run 12 compiler unit/IR/negative test suites
ninja -t clean   # remove build/
```

Currently passing (`ninja test`, 24/24): `hello`, `fib`, `tail`, `bools`,
`strings`, `match`, `mutual`, `adt`, `closures`, `loops`, `arrays_bytes`,
`arc_test`, `exn`, `weak_cycle`, `cycle_collect` (trial-deletion cycle
collector), `mod_main` (multi-module `.mli`/`.ml` linking), `stdlib_test`
(core `stdlib/` modules with `arc_delta = 0`), `fiber_test` (Wren coroutines,
cooperative scheduler, abandoned-fiber shadow-stack cleanup, fiber exceptions),
`fiber_io` (non-blocking pipe async I/O via `kqueue`/`epoll`), `qbe_pic_check`
(ARM64/AMD64 PIC GOT/PLT output), `pic_so` (shared library + C host),
`mt_ffi` (8-thread FFI + concurrent cycle collector stress), `tupled_letrec`
(`Tupled` functions and `value let rec`), and `primitives_test` (`float`,
`float array`, `Int32`/`Int64`/`Nativeint`, `Printf` numeric formatters).

The pipeline:

1. `vendor/qbe/*.c` → `build/qbe/qbe` (host target selected by
   `tools/gen-config.sh`)
2. `runtime/*.c` → `build/rt/libocamlrt.a`
3. `dune build` → `build/bin/ocamlcc` (OCaml compiler-libs frontend, ANF,
   Perceus ARC pass, QBE IL writer)
4. `stdlib/*.ml` → `build/stdlib/libocamlstdlib.a`
5. `examples/*.ml` → `.ssa` (ocamlcc) → `.s` (qbe) → native executable (cc)

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
build/bin/ocamlcc compile examples/hello.ml -o build/hello.ssa
build/bin/ocamlcc compile --nostdlib -I build/stdlib examples/stdlib_test.ml -o build/stdlib_test.ssa
build/bin/ocamlcc compile-mli examples/mod_lib.mli -o build/mod_lib.cmi
build/bin/ocamlcc dump-lambda examples/hello.ml
```
