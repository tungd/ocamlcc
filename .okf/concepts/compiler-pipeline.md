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
envelope (`setglobal`, `makeblock`), top-level (mutually independent,
possibly recursive) function definitions with direct saturated calls, and
direct calls to known Stdlib builtins resolved via
[Builtins](/concepts/compiler-pipeline.md). Everything else fails with an
"unsupported" error naming the construct.

# Self tail-calls

QBE has no `musttail` and forbids jumping to a function's start block, so a
self tail-call lowers to an explicit loop: `@start` jumps to a dedicated
`@loop` header whose **phi nodes** merge the formal parameters (from
`@start`) with the backedge arguments (one recorded site per tail call), and
the backedge is a plain `jmp @loop`[^design-doc]. This is the design doc's
§7 mitigation for unbounded recursion: `sum_to 0 100000` runs in constant
stack space. Mutual tail recursion still raises an unsupported error; the
trampoline convention is future work.

# Builtin resolution

Stdlib entry points surface in Lambda as field loads from the Stdlib module
block, e.g. `(field_imm 43 (global Stdlib!))`. The field offsets are an
implementation detail of the linked compiler-libs, so `lib/builtins.ml`
probes that very compiler with tiny reference programs (`let () = print_int
1`) and learns the rendered form of each builtin at startup, instead of
hardcoding offsets that would break across OCaml versions.

[^design-doc]: Stage structure, goals, and the exception/fiber lowering
  plans are specified in `docs/design.md` §3–§4.
