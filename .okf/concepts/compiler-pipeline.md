---
type: Concept
title: Compiler pipeline
description: The four-stage architecture — official OCaml frontend, middle-end, QBE code generation, packaging.
tags: [compiler, architecture, lambda, qbe]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-15
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: lib-codegen
    resource: ../lib/codegen.ml
    title: ANF-to-QBE code generator
  - id: lib-frontend
    resource: ../lib/frontend.ml
    title: compiler-libs frontend wrapper
  - id: lib-anf
    resource: ../lib/anf.ml
    title: Lambda-to-ANF conversion and free-variable analysis
  - id: lib-arc-pass
    resource: ../lib/arc_pass.ml
    title: Perceus ARC, reuse, exception-unwind, and yield-effect pass
---

# Design

The pipeline has four stages[^design-doc]:

1. **Official OCaml frontend** — ocamlcc links against `compiler-libs.common`
   (OCaml `5.3+` `Unit_info`/`Typemod` APIs) and reuses Parse (syntax),
   Typemod (typechecking, including `.mli` → `.cmi`), and Translmod (Lambda
   lowering). Module system, functors, GADTs, and polymorphic variants all
   arrive pre-desugared: frontend fidelity is free, and unsupported
   constructs are rejected downstream by `Anf`/`Codegen` with a
   descriptive error.
2. **Middle-end (pure OCaml)** — ANF conversion (`lib/anf.ml`), fixed-point
   yield-effect inference and the [Perceus ARC](/concepts/perceus-arc.md) +
   shadow-stack fiber + error-return exception pass (`lib/arc_pass.ml`).
3. **Code generation** — `Codegen` lowers ANF to the
   [QBE IL](/concepts/vendored-qbe.md) model in `Qbe_il`; QBE turns SSA into
   target assembly (including void `arc_retain_val` calls on `GetGlobal`,
   exception/intermediate-closure cleanup on direct over-application, and
   explicit zero-divisor guards raising `Division_by_zero` on `Div`/`Mod`).
4. **Linking & packaging** — `dune` exposes the `ocamlcc` public executable,
   `build.ninja` archives `build/rt/libocamlrt.a` and
   `build/stdlib/libocamlstdlib.a`, and Phase 4 adds `.mli → .h` C ABI header
   generation and xcframework/AAR packaging.

# Implementation status

The Lambda → ANF → ARC → QBE pipeline works end-to-end (`ninja test`, 19
checked examples spanning ADTs, closures, Perceus ARC, exceptions, cycles,
weak arrays, multi-module linking, ARC-native stdlib, and Wren fibers).
Supported Lambda subset: integer/char constants, string literals,
immortal structured constant blocks (`Const_block`), `let` / `let mut` /
`let rec` bindings, sequences, arithmetic/bitwise/comparison/boolean
primitives, `if/then/else`, `while`/`for` loops, heap blocks (`Pmakeblock`,
`Pfield`, `Psetfield`, `Poffsetref`, `Pisint`, `Pisout`), arrays/bytes
(`Pmakearray`, `Pduparray`, bounds-checked get/set), `match` on integers,
constant constructors, strings, and block constructors (`Lswitch`,
`Lstringswitch`, `Lstaticraise`/`Lstaticcatch`), closures with free-variable
capture, lazy immortal wrappers for pure functions, partial & over-application
(`ArcPap` + `runtime/closure.c`), top-level (mutually recursive) pure
functions with direct saturated calls, `Ltrywith`/`Praise` exceptions, `Pccall`
FFI, multi-module `GetGlobal`, and direct calls to known Stdlib builtins
resolved via [Builtins](/concepts/compiler-pipeline.md). Everything else fails
with an "unsupported" error naming the construct.

# Match lowering

Pattern compilation in translmod produces two shapes:

- **`Lswitch`** over the scrutinee with `sw_consts` (immediate ints /
  constant constructors) and `sw_blocks` (heap block tags) — when both are
  non-empty, `scrut & 1` discriminates immediates from heap pointers;
  block arms load the 16-bit constructor tag from `ArcHeader.tag` (`scrut -
  12`) and dispatch via a comparison chain, sharing a single `swfail` block
  when `sw_failaction` is present and merging arms with `phi` nodes.
- **`Lstaticcatch`/`Lstaticraise`** — static exits for or-patterns and
  wildcards. Raise sites record their predecessor block and argument
  values; the handler block emits one phi per binder merging all sites, and
  both the normal path and the handler merge into a join block (phi in
  tail position, copies otherwise).

# Self tail-calls

QBE has no `musttail` and forbids jumping to a function's start block, so a
self tail-call lowers to an explicit loop: `@start` jumps to a dedicated
`@loop` header whose **phi nodes** merge the formal parameters (from
`@start`) with the backedge arguments (one recorded site per tail call), and
the backedge is a plain `jmp @loop`[^design-doc]. This is the design doc's
§7 mitigation for unbounded recursion: `sum_to 0 100000` runs in constant
stack space.

**Mutual tail recursion** uses the design doc's trampoline convention: a
tail-call graph over toplevel definitions is computed, and each strongly
connected component (of size ≥ 2) is compiled as *one* QBE function — the
trampoline. Its `@dispatch` header compares a selector argument against each
member's tag and jumps to the member's body; member parameters flow through
uniform phi slots (arities are padded with unit values). A tail call to any
group member — self or mutual — records a backedge site and jumps to
`@dispatch`, so `even`/`odd` ping-pong 100k times in constant stack. Calls
from outside the group pass the member's tag as the first argument.

# Builtin resolution

Stdlib entry points surface in Lambda as field loads from the Stdlib module
block, e.g. `(field_imm 43 (global Stdlib!))`. The field offsets are an
implementation detail of the linked compiler-libs, so `lib/builtins.ml`
probes that very compiler with tiny reference programs (`let () = print_int
1`) and learns the rendered form of each builtin at startup, instead of
hardcoding offsets that would break across OCaml versions.

[^design-doc]: Stage structure, goals, and the exception/fiber lowering
  plans are specified in `docs/design.md` §3–§4.
