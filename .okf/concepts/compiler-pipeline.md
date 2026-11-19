---
type: Concept
title: Compiler pipeline
description: The four-stage architecture — official OCaml frontend, middle-end, QBE code generation, packaging.
tags: [compiler, architecture, lambda, qbe]
status: stable
generated:
  by: codex/1
  at: 2026-11-19T03:35:08Z
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: lib-codegen
    resource: ../lib/codegen.ml
    title: Modular ANF-to-QBE code generator (codegen_ctx, codegen_analysis, codegen_expr, codegen_fn, codegen)
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
   (OCaml `5.5.x` `Unit_info`/`Typemod` APIs) and reuses Parse (syntax),
   Typemod (typechecking, including `.mli` → `.cmi` and `-open <Mod>` via
   `Clflags.open_modules`), and Translmod (Lambda lowering). Module system,
   functors, GADTs, and polymorphic variants all arrive pre-desugared:
   frontend fidelity is free, and unsupported constructs are rejected
   downstream by `Anf`/`Codegen` with a descriptive error.
2. **Middle-end (pure OCaml)** — ANF conversion (`lib/anf.ml`), fixed-point
   yield-effect inference and the [Perceus ARC](/concepts/perceus-arc.md) +
   shadow-stack fiber + error-return exception pass (`lib/arc_pass.ml`).
3. **Code generation** — `Codegen` (split across `codegen_ctx.ml`,
   `codegen_analysis.ml`, `codegen_expr.ml`, `codegen_fn.ml`, and `codegen.ml`,
   with per-function state isolated via `Codegen_ctx.with_fn_state`) lowers ANF
   to the
   [QBE IL](/concepts/vendored-qbe.md) model in `Qbe_il`; QBE turns SSA into
   target assembly (including void `arc_retain_val` calls on `GetGlobal`,
   exception/intermediate-closure cleanup on direct over-application,
   explicit zero-divisor guards raising `Division_by_zero` on `Div`/`Mod`,
   `compile_bounds_guarded` / `compile_bytes_slice_bounds_guarded` raising `Invalid_argument` via
   `ocamlcc_raise_invalid_arg_oob`—with consumed RHS release on failed
   `ArraySet`—on out-of-range indexing instead of aborting, inline QBE lowering
   for `BytesGetN`/`BytesSetN` (unaligned 16/32/64-bit loads/stores) and
   `Bswap16`/`BswapBint`, `caml_string_*`/`caml_bytes_*` comparison mapping to
   `caml_{equal,notequal,compare,lessthan,lessequal,greaterthan,greaterequal}`, overflow-safe
   `For` loops that check `iv < ev` / `iv > ev` before stepping, and
   `b.term = None` guards after compiling `While` conditions).
4. **Linking & packaging** — `dune` exposes the `ocamlcc` public executable,
   `build.ninja` archives `build/rt/libocamlrt.a` and
   `build/stdlib/libocamlstdlib.a`, and Phase 4 adds `.mli → .h` C ABI header
   generation and xcframework/AAR packaging.

# Implementation status

The Lambda → ANF → ARC → QBE pipeline works end-to-end (`ninja test`, 24
checked checks spanning ADTs, closures, Perceus ARC, exceptions, cycles,
weak arrays, multi-module linking, PIC `.so`, multi-threaded FFI, `Tupled`
functions + `value let rec`, `float` / `float array` / `int32` / `int64` /
`nativeint` + `Printf`, ARC-native stdlib, and Wren fibers).
Supported Lambda subset: integer/char constants, `float` (`Const_float`,
`+.`/`-.`/`*.`/`/.`/`~-.`/`abs_float`/comparisons/`float_of_int`/`int_of_float`),
`float array` & all-float records (`Const_float_array`, `Pfloatarray`,
`Pgenarray` runtime dispatch, `Pfloatfield`/`Psetfloatfield`), boxed integers
(`int32`, `int64`, `nativeint`, constants, arithmetic, shifts, `Division_by_zero`
-guarded `div`/`mod` avoiding `INT_MIN / -1` traps, comparisons, conversions),
string literals, immortal structured constant blocks (`Const_block`), `let` /
`let mut` / `let rec` bindings (both function `let rec` and value `let rec` via
`caml_alloc_dummy*`/`caml_update_dummy*`), sequences, arithmetic/bitwise/
comparison/boolean primitives, `if/then/else`, `while`/`for` loops, heap blocks
(`Pmakeblock`, `Pfield`, `Psetfield`, `Poffsetref`, `Pisint`, `Pisout`),
arrays/bytes (`Pmakearray`, `Pduparray`, bounds-checked get/set), `match` on
integers, constant constructors, strings, and block constructors (`Lswitch`,
`Lstringswitch`, `Lstaticraise`/`Lstaticcatch`), `Curried` and `Tupled`
functions, closures with free-variable capture, lazy immortal wrappers for pure
functions, partial & over-application (`ArcPap` + `runtime/closure.c`),
top-level (mutually recursive) pure functions with direct saturated calls,
`Ltrywith`/`Praise` exceptions, `Pccall` FFI, multi-module `GetGlobal`, and
direct calls to known Stdlib builtins resolved via
[Builtins](/concepts/compiler-pipeline.md). Everything else fails with an
"unsupported" error naming the construct.

# Bigarray scalar accesses

ANF carries the operation, rank, kind, layout and bounds-check mode for
Bigarray accesses. A concrete float32 or float64 Array1 store accepts raw doubles
from nested reads and arithmetic. A backwards scan of consecutive
`let` bindings also selects raw loads and arithmetic results when every use accepts a
double in the same chain. Captures and other boxed uses keep the existing
OCaml value. ARC borrows the arrays, checks for exceptions after
access, and excludes raw temporaries from reference counting and shadow
frames. QBE emits double addition, subtraction, multiplication, or division between
the typed load and store helpers. Float32 converts at the buffer boundary. Inline and scalar-only named float conditionals use a double phi and keep the selected
result out of ARC ownership tracking. See [memory views](/concepts/memory-views.md).

Int32, int64, and nativeint Array1 stores also propagate scalar demand through
straight-line loads, wrapping arithmetic, negation, bitwise operations, and
shifts, signed division, and remainder. These produce
QBE words for int32 and longs for int64 and nativeint. Scalar-only
conditionals, variant switches, and static catches join results using a phi
of the same width. Static catch arguments retain the ordinary OCaml value
ABI. ARC releases any boxed branch operand after the compiler extracts
its scalar value. Signed
relational and three-way comparisons may take raw inputs and produce
tagged bool or int results. Integer conversions share the signed widening,
narrowing, and tagged-int instructions used by the boxed path. The
demand scan selects a binding only when its scalar uses agree on the
representation and the binding has no boxed use.

# Match lowering

Pattern compilation in translmod produces two shapes:

- **`Lswitch`** over the scrutinee with `sw_consts` (immediate ints /
  constant constructors) and `sw_blocks` (heap block tags) — when both are
  non-empty, `scrut & 1` discriminates immediates from heap pointers;
  block arms load the 16-bit constructor tag from `ArcHeader.tag` (`scrut -
  12`) and dispatch via a comparison chain, sharing a single `swfail` block
  when `sw_failaction` is present and merging arms with `phi` nodes. Any
  block with > 50 incoming `phi` edges is automatically split by
  `Codegen_ctx.split_wide_phis` into a trampoline tree so arbitrarily wide
  switches stay below QBE's `NPred = 63` parser cap without modifying
  vendored QBE.
- **`Lstaticcatch`/`Lstaticraise`** — static exits for or-patterns and
  wildcards. Raise sites record their predecessor block and argument
  values; the handler block emits one phi per binder merging all sites, and
  both the normal path and the handler merge into a join block (phi in
  tail position, copies otherwise). The matcher's tuple-let optimization
  (`assign_pat`) can also leave an `Lstaticraise` at the tail of a `Llet`
  chain used as a binding RHS; `Anf.conv_bind` lowers it as a terminator
  (bare `StaticRaise`, unreachable continuation dropped) exactly like
  `conv_expr` does in tail position — regression-tested in
  `test/anf_staticraise_test.ml`. Shared multi-constructor catch arms whose
  constructors have different payload arities (e.g. `Typedtree`'s
  `shallow_iter_pattern_desc`) also emit 0-occurrence `Llet(Alias, _, w,
  Pfield i param, ...)` wildcard bindings; `Anf.drop_unused_alias_lets` prunes
  zero-occurrence `Alias`/`StrictOpt` bindings before ANF lowering so higher
  field indices are never loaded out of bounds from smaller constructors
  (regression-tested in `test/anf_unused_alias_test.ml`).

# Self tail-calls

QBE has no `musttail` and forbids jumping to a function's start block, so a
self tail-call lowers to an explicit loop: `@start` jumps to a dedicated
`@loop` header whose **phi nodes** merge the formal parameters (from
`@start`) with the backedge arguments (one recorded site per tail call), and
the backedge is a plain `jmp @loop`[^design-doc]. This is the design doc's
§7 mitigation for unbounded recursion: `sum_to 0 100000` runs in constant
stack space.

**Mutual tail recursion** uses the design doc's trampoline convention: a
tail-call graph over saturated direct calls in `tail` position (for both pure
top-level/nested `pure_defs` and non-pure `let rec` closure groups) is
computed, and each strongly connected component (of size ≥ 2) is compiled as
*one* QBE function — the trampoline. Its `@dispatch` header compares a selector
argument against each member's tag and jumps to the member's body; member
parameters flow through uniform phi slots (arities are padded with unit
values), and non-pure closure groups also thread `%phi_clos` so each member
entry unpacks its closure environment without pushing stack frames. A tail
call to any group member — self or mutual — records a backedge site and jumps
to `@dispatch`, so `even`/`odd` and `ocamllex` lexer DFAs run 300k+ transitions
in constant stack. Calls from outside the group pass the member's tag as the
dispatch selector (while individual member closure wrappers forward through to
the trampoline for indirect `ocamlcc_apply_n` calls).

# Builtin resolution

When `--nostdlib` is off, `Stdlib` entry points surface in Lambda as field
loads from the `Stdlib` module block (`Lprim (Pfield (pos, _, _), [Lprim
(Pgetglobal id, [], _)], _)`). Instead of hardcoding slot offsets or
compiling throwaway probe snippets against the host switch's `Stdlib`,
`lib/builtins.ml` locates the active `stdlib.cmi` along `include_dirs`
(falling back to `Config.standard_library`), computes each entry point's
runtime slot index directly from `Cmi_format.read_cmi` (skipping `Val_prim`
primitives and `Mty_alias` module aliases), and matches the Lambda AST
directly without invoking the frontend or mutating global compiler-libs
state. Regression-tested in `test/builtins_test.ml`.

[^design-doc]: Stage structure, goals, and the exception/fiber lowering
  plans are specified in `docs/design.md` §3–§4.
