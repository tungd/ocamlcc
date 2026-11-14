---
type: Concept
title: Compiler pipeline
description: The four-stage architecture — official OCaml frontend, middle-end, QBE code generation, packaging.
tags: [compiler, architecture, lambda, qbe]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-13
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: lib-codegen
    resource: ../lib/codegen.ml
    title: Lambda-to-QBE code generator
  - id: lib-frontend
    resource: ../lib/frontend.ml
    title: compiler-libs frontend wrapper
---

# Design

The pipeline has four stages[^design-doc]:

1. **Official OCaml frontend** — ocamlcc links against `compiler-libs.common`
   and reuses Parse (syntax), Typemod (typechecking), and Translmod (Lambda
   lowering). Module system, functors, GADTs, and polymorphic variants all
   arrive pre-desugared: frontend fidelity is free, and unsupported
   constructs are rejected downstream by the code generator with a
   descriptive error (see `Codegen.describe`).
2. **Middle-end (pure OCaml)** — planned: ANF conversion, closure
   conversion, the [Perceus ARC](/concepts/perceus-arc.md) pass, shadow-stack
   fiber lowering, and error-return exception lowering.
3. **Code generation** — `Codegen` lowers the Lambda subset to the
   [QBE IL](/concepts/vendored-qbe.md) model in `Qbe_il`; QBE turns SSA into
   target assembly.
4. **Linking & packaging** — currently plain `cc`; Phase 4 adds `.mli → .h`
   header generation and xcframework/AAR packaging.

# Implementation status

The Lambda → QBE slice is working end-to-end (`ninja test`). Supported
Lambda subset: integer constants, string literals (data emission), `let`
bindings, sequences, arithmetic and comparison primitives, `if/then/else`
(including booleans as first-class values), the module-initialization
envelope (`setglobal`, `makeblock`), `match` on integers and constant
constructors (`Lswitch` + `Lstaticraise`/`Lstaticcatch`), top-level
(mutually recursive) function definitions with direct saturated calls, and
direct calls to known Stdlib builtins resolved via
[Builtins](/concepts/compiler-pipeline.md). Everything else fails with an
"unsupported" error naming the construct.

# Match lowering

Pattern compilation in translmod produces two shapes:

- **`Lswitch`** over the scrutinee with `case int k` arms — desugared into a
  comparison chain of `Lifthenelse` (`ceql` against `tag_int k`) so the
  existing tail/epilogue machinery applies. Complex scrutinees are bound to
  a fresh variable first (defensively; translmod usually does this itself).
  Block-constructor cases (`sw_blocks`) are rejected for now.
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
