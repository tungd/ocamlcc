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

The initial integration compiles 68/72 modules. Lexing, Parsing, Bigarray,
and Marshal remain unsupported. A pre-existing report records 53/77 standalone
tests passing; this count is historical until the runner is executed again.
Compilation success alone does not establish behavioral compatibility.

The runner skips toplevel expect tests and tests with C stubs, multiple modules,
or unsupported ocamltest directives. Those require an adapter rather than being
counted as passing. GC, domains, and OS-specific behavior may differ under ARC.
Core regression commands are `ninja -j1 test`, `ninja -j1 asan_test`, and
`dune runtest -j1`.[^runtime]

[^runner]: Native compilation and test orchestration in the compatibility runner.
[^upstream]: Vendored source identity and test inventory.
[^runtime]: ARC/PAL implementation of upstream primitives.
