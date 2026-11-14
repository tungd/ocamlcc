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

Phase 1 — Lambda → QBE MVP (in progress).

`ocamlcc` currently compiles a growing integer/string subset of OCaml:
integer literals, `let` (including toplevel and recursive function
definitions), arithmetic/comparison, booleans as values, `if/then/else`,
string literals, the builtins `print_int` / `print_string` /
`print_endline` / `exit`, and self tail-recursion (lowered to constant-stack
phi loops). Unsupported Lambda constructs (closures, `try`, pattern
matching, floats, …) are rejected with a descriptive error. Memory is not
yet reclaimed (Phase 2 adds Perceus ARC).

## Build

The whole project is driven by [ninja](https://ninja-build.org):

```sh
ninja            # vendored QBE + ARC/fiber runtime + ocamlcc compiler + examples
ninja smoke      # compile examples/hello.ml end-to-end and run it
ninja test       # compile every example and diff against tests/*.expected
ninja -t clean   # remove build/
```

Currently passing: `hello` (arithmetic + branch), `fib` (non-tail
self-recursion), `tail` (self tail-calls lowered to a phi loop — constant
stack), `bools` (booleans as values), `strings` (string literals +
`print_string`/`print_endline`).

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
vendor/qbe/   vendored QBE 1.2 (source drop, built out-of-tree by ninja)
examples/     example programs
tests/        expected outputs for the examples (ninja test)
.okf/         OKF knowledge bundle: design, decisions, roadmap
tools/        build helpers
```

## Usage

```sh
build/bin/ocamlcc compile examples/hello.ml -o build/hello.ssa   # emit QBE IL
build/bin/ocamlcc dump-lambda examples/hello.ml                  # dump Lambda IR
```
