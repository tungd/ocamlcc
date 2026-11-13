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

Phase 1 — Lambda → QBE MVP (thin vertical slice).

`ocamlcc` currently compiles a tiny integer-only subset of OCaml: integer
literals, `let`, arithmetic/comparison, `if/then/else`, and the builtins
`print_int` / `exit`. Unsupported Lambda constructs are rejected with a
descriptive error. Memory is not yet reclaimed (Phase 2 adds Perceus ARC).

## Build

The whole project is driven by [ninja](https://ninja-build.org):

```sh
ninja            # vendored QBE + ARC/fiber runtime + ocamlcc compiler + examples
ninja smoke      # compile examples/hello.ml end-to-end and run it
ninja -t clean   # remove build/
```

The pipeline:

1. `vendor/qbe/*.c` → `build/qbe/qbe` (host target selected by
   `tools/gen-config.sh`)
2. `runtime/*.c` → `build/rt/libocamlrt.a`
3. `dune build` → `build/bin/ocamlcc` (OCaml compiler-libs frontend, QBE IL
   writer)
4. `examples/*.ml` → `.ssa` (ocamlcc) → `.s` (qbe) → native executable (cc)

## Layout

```
bin/          ocamlcc CLI (compile, dump-lambda)
lib/          QBE IL model + printer, Lambda frontend, code generator
runtime/      freestanding C runtime: pal.h, arc.h/c, fiber.h/c, builtins
vendor/qbe/   vendored QBE (source drop, built out-of-tree by ninja)
examples/     example programs
.okf/         OKF knowledge bundle: design, decisions, roadmap
tools/        build helpers
```

## Usage

```sh
build/bin/ocamlcc compile examples/hello.ml -o build/hello.ssa   # emit QBE IL
build/bin/ocamlcc dump-lambda examples/hello.ml                  # dump Lambda IR
```
