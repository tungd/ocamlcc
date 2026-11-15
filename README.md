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

Phases 1, 2, 3, and 5 complete (`ninja test`: 19/19 checked examples passing).

`ocamlcc` compiles multi-module OCaml programs (`.mli` interfaces and `.ml`
implementations) to native binaries via QBE with Perceus-style Automatic
Reference Counting, a freestanding 12-class slab allocator + opt-in
trial-deletion cycle collector (`ocamlcc_arc_collect` in `runtime/arc.c`),
Wren-style stackful fibers + cooperative `kqueue`/`epoll` async I/O poller
with yield-effect shadow-stack lowering (`runtime/fiber.c`, `runtime/pal_ctx.S`,
`Stdlib.Fiber`), error-return exceptions (`try ... with`), `Weak.t`, compiler
warnings on cyclic non-pure mutual `let rec` closures, and an ARC-native core
standard library (`stdlib/` → `build/stdlib/libocamlstdlib.a`: `Option`, `Result`,
`List`, `Array`, `Bytes`, `String`, `Buffer`, `Hashtbl`, `Printf`, `Weak`,
`Fiber`, `CamlinternalFormatBasics`, `Stdlib`). `runtime/builtins.c` stays
minimal (`print_int`, `print_string`, `print_endline`, `exit`, `main`).

## Build

The whole project is driven by [ninja](https://ninja-build.org):

```sh
ninja            # vendored QBE + ARC/fiber runtime + ocamlcc compiler + examples
ninja smoke      # compile examples/hello.ml end-to-end and run it
ninja test       # compile every example and diff against tests/*.expected
ninja -t clean   # remove build/
```

Currently passing (19 checked examples): `hello`, `fib`, `tail`, `bools`,
`strings`, `match`, `mutual`, `adt`, `closures`, `loops`, `arrays_bytes`,
`arc_test`, `exn`, `weak_cycle`, `cycle_collect` (trial-deletion cycle
collector), `mod_main` (multi-module `.mli`/`.ml` linking), `stdlib_test`
(core `stdlib/` modules with `arc_delta = 0`), `fiber_test` (Wren coroutines,
cooperative scheduler, abandoned-fiber shadow-stack cleanup, fiber exceptions),
and `fiber_io` (non-blocking pipe async I/O via `kqueue`/`epoll`).

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
runtime/      freestanding C runtime: pal.h, arc.h/c, fiber.h/c, builtins.c
vendor/qbe/   vendored QBE 1.2 (source drop, built out-of-tree by ninja)
examples/     example programs
tests/        expected outputs for the examples (ninja test)
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
