---
type: Concept
title: Upstream standard library compatibility
description: Pinned OCaml sources, ARC overlays, and native upstream test execution.
tags: [stdlib, compatibility, testing, arc]
status: stable
generated:
  by: codex/1
  at: 2026-11-17
sources:
  - id: runner
    resource: tools/stdlib_compat.py
  - id: upstream
    resource: vendor/ocaml-stdlib/UPSTREAM.txt
  - id: runtime
    resource: runtime/arc.c
---

# Build and test

`tools/import-ocaml-stdlib.sh` vendors OCaml 5.5.0 standard library sources,
interfaces, licenses, and 48 upstream `lib-*` test directories. The pin is
recorded in `vendor/ocaml-stdlib/UPSTREAM.txt`.[^upstream]

After `ninja -j1`, run `python3 tools/stdlib_compat.py`. The runner selects
`stdlib/overlay/` files before upstream sources, compiles the interfaces and
implementations with ocamlcc/QBE, archives the objects, and links upstream tests
against that archive and our ARC runtime. It does not use the host OCaml runtime.
`build/stdlib_compat/report.md` records module and test outcomes.[^runner]

The Lexing overlay implements both DFA engines in OCaml, including signed
16-bit transitions, unsigned memory-code offsets, captures, backtracking,
refill continuations, EOF, and positions. `tests/stdlib/lexing` uses real
ocamllex output and passes against both stock OCaml and ocamlcc. The Parsing overlay interprets ocamlyacc action/goto tables in OCaml and
preserves token translation, stack growth, reductions, error recovery,
semantic-action suspension, positions, and trace state. A generated-parser
fixture checks reductions, deep nesting, parse errors, and subsequent parses.
Bigarray primitive lowering dispatches typed and generic 1/2/3-dimensional
accesses to ARC runtime helpers. `%caml_ba_dim_N` is translated from its
one-based primitive number to the zero-based generic dimension API. Views
retain a backing descriptor, which releases its PAL allocation after the last
view dies. The core API supports all element kinds, both layouts, checked
indexing, fill/blit, and shared sub/slice/reshape/layout views. These helpers
live in `runtime/bigarray.inc`, included by `arc.c`.
The native stdlib build now compiles 71/72 modules; Marshal remains unsupported.
The initial public API regression verifies int/float64 access, dimensions,
bounds, and C/Fortran indexing. Follow-up regressions verify view lifetime,
structural comparison/hash equality, and complex record representation.
Bigarray channel I/O works through existing buffered channel helpers.
Random retains the upstream Bigarray state representation and the pure OCaml
LXM algorithm, so upstream testvectors can inspect the state directly.

Eight of nine selected upstream standalone tests pass: change_layout, fftba,
pr5115, reshape_overflow, specialized, weak_bigarray, channel bigarrays, and
Random testvectors. The large Bigarray test reaches its Marshal I/O section
with no preceding Bad result lines and fails at the unsupported Marshal stub.
The C-stub subarray test is explicitly skipped by the native runner.

Use `--tests 'lib-bigarray/*'` to select upstream tests and `--reuse-stdlib`
after a build. The runner saves module/test JSON receipts and complete per-command
logs, including timeouts. Tests run in isolated copied working directories so
test-created files do not modify the vendor tree. A pre-existing report records 53/77 standalone
tests passing; this count is historical until the runner is executed again.
Compilation success alone does not establish behavioral compatibility.

The runner skips toplevel expect tests and tests with C stubs, multiple modules,
or unsupported ocamltest directives. Those require an adapter rather than being
counted as passing. GC, domains, and OS-specific behavior may differ under ARC.
`python3 tools/stdlib_regressions.py` runs repository API fixtures against the
compatibility archive; `--stock` checks the same fixtures with host OCaml.
Generated sources, commands, executables, and outputs stay under
`build/stdlib_regressions/`. Core regression commands are `ninja -j1 test`, `ninja -j1 asan_test`, and
`dune runtest -j1`.[^runtime]

[^runner]: Native compilation and test orchestration in the compatibility runner.
[^upstream]: Vendored source identity and test inventory.
[^runtime]: ARC/PAL implementation of upstream primitives.
