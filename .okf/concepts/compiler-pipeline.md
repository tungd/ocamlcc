---
type: Concept
title: Compiler pipeline
description: The four-stage architecture — official OCaml frontend, middle-end, QBE code generation, packaging.
tags: [compiler, architecture, lambda, qbe]
status: stable
generated:
  by: codex/1
  at: 2026-11-22
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: lib-codegen
    resource: ../lib/codegen.ml
    title: Modular ANF-to-QBE code generator (codegen_ctx, codegen_analysis, codegen_expr, codegen_fn, codegen)
  - id: lib-pipeline
    resource: ../lib/pipeline.ml
    title: Typed per-unit compile request and output
  - id: lib-frontend
    resource: ../lib/frontend.ml
    title: compiler-libs frontend wrapper
  - id: lib-anf
    resource: ../lib/anf.ml
    title: Lambda-to-ANF conversion
  - id: lambda-opt
    resource: ../lib/lambda_opt.ml
    title: Pre-ANF Lambda optimization and export analysis
  - id: anf-scalar
    resource: ../lib/anf_scalar.ml
    title: Unboxed scalar selection inside ANF
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
2. **Middle-end (pure OCaml)** — Lambda optimization and ANF conversion feed
   `Arc_analysis`, which computes call effects and representation facts.
   `Arc_pass` inserts [Perceus ARC](/concepts/perceus-arc.md), shadow-stack
   and exception cleanup using these facts and the local rewrites in
   `Arc_views`.
3. **Code generation** — `Codegen` (split across `codegen_ctx.ml`,
   `codegen_analysis.ml`, `codegen_scalar.ml`, `codegen_expr.ml`,
   `codegen_fn.ml`, and `codegen.ml`) lowers ANF to the
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
4. **Linking & packaging** — `dune` exposes the `occ` public executable,
   `build.ninja` archives `build/rt/libocamlrt.a` and
   `build/stdlib/libocamlstdlib.a`, and Phase 4 adds `.mli → .h` C ABI header
   generation and xcframework/AAR packaging.

# Compilation requests

`Pipeline.Request.t` holds the per-unit source, compiler options, and import
inputs. `compile_source` and `compile_file` return `Pipeline.Output.t` with
QBE SSA, the selected or emitted CMI path when available, and cross-unit
export facts.[^lib-pipeline] The export policy chooses ordinary code generation,
in-process export collection, or sealed link symbols for separately built
objects. The CLI and driver pass export facts and CMI paths directly from the
result into publication. An optional summary loader reads external metadata
against the CMI selected by the frontend.

# Code generation interfaces

`Codegen_ctx` owns the mutable builder and per-function state. It scopes
nested function emission, static handler labels, try handlers, and raw loop
indices. `Codegen_scalar` lowers boxed and unboxed numeric operators and
Bigarray scalar accesses. `Qbe_il.optimize_blocks` simplifies branches and
splits wide phis using caller-provided fresh-name counters.

Export summary rows share a codec for object and archive sidecars. Writers
emit v5. Loaders check the object or archive and CMI digests before using
the facts. Older rows without an exception field are read as raising.

# ANF lowering

`Lambda_opt.optimize` owns Lambda optimization and returns the rewritten term
with binder representations, module slots, and export identifiers.[^lambda-opt]
Each `Anf.lower` invocation passes its own immutable environment through
conversion. The optimizer and converter share the import lookup for that
invocation. `Anf_ir` owns the common IR and free-variable queries, and
`Anf_scalar.run` selects unboxed scalar operations over that IR.[^anf-scalar]
Boxed arithmetic and shifts carry the integer width and operation separately.
ARC and QBE use those fields to classify and lower the operation.

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

# Local inlining and known callbacks

Before ANF lowering and ARC insertion, the compiler can inline saturated
calls to lexically known non-recursive curried functions. It uses definition
and call-site inline hints, a size heuristic for small direct-only helpers,
and specialization when a known closure can replace a call-only parameter.
The inliner bounds expansion by depth and total copied Lambda nodes. A copy
gets fresh variable and static exit identifiers, and strict argument bindings
preserve evaluation order and side effects. Partial applications, unknown
callees, and functions marked `[@inline never]` keep ordinary calls.

The tterm codepoint replay uses this path to inline the iterator, its
callback, and the local dirty-span helpers in `State.handle_codepoints`.
`test/lambda_inline_test.ml` checks the direct loop and the absence of
closure allocations in a fixture with the same callback shape.

# Local functor applications

The Lambda inliner can expand a known, saturated functor application within
its existing size and expansion budget. Bindings for a functor's initialized
module fields stay visible to the compiler, so calls through a known
immutable module projection can name the specialized function directly.
Initializer effects still run in order for each application. The module
value and its fields remain available to first-class consumers, and functors
whose bodies are available only in a prebuilt archive use ordinary module
application.

# Cross-unit calls

The multi-unit build carries export summaries from compiled units to their
consumers. A summary follows a function through immutable Lambda block
allocations. It resolves the conservative field reads produced by signature
coercions when their owner is a known immutable block. Saturated calls
use the known entry and its ARC argument convention. Capturing entries borrow
a closure environment cached at module initialization. Small closed functions
over tagged scalar parameters can be expanded directly in the caller.
Pure direct calls and inlined leaf expressions preserve initialization
dependencies. Partial applications, dynamic targets, and prebuilt units
without summaries use ordinary closure application.

The summary carries suspension and immediate-result facts into ARC.
Non-suspending imports skip caller shadow roots. A suspending import keeps
the roots, and an over-application stays conservative because the returned
closure can suspend independently of the first call. The driver regression
exercises scalar inlining, signature slots, captured environments, partial
application, and suspension.

# Match lowering

Pattern compilation in translmod produces two shapes:

- **`Lswitch`** over the scrutinee with `sw_consts` (immediate ints /
  constant constructors) and `sw_blocks` (heap block tags) — when both are
  non-empty, `scrut & 1` discriminates immediates from heap pointers;
  block arms load the 16-bit constructor tag from `ArcHeader.tag` (`scrut -
  12`) and dispatch via a comparison chain, sharing a single `swfail` block
  when `sw_failaction` is present and merging arms with `phi` nodes. Any
  block with > 50 incoming `phi` edges is automatically split by
  `Qbe_il.optimize_blocks` into a trampoline tree so arbitrarily wide
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

**Captured recursive calls** share one dispatcher closure when all uses of
the recursive functions inside the group are saturated direct calls. The
dispatcher takes a member selector and argument slots sized to the largest
member arity. It loads the captured environment at entry and borrows those
values across tail-call transitions. A first-class use in the enclosing body
gets a wrapper of its original arity that owns the dispatcher. Dynamic sibling
uses inside the group, tupled functions, and captures of mutable Lambda slots
keep the general closure path. The `cycle_collect` executable checks constant
stack use, escaping wrappers, partial applications and immediate reclamation.
`mutrec_closure_tail_test.ml` checks that the dispatcher signature is
independent of the number of captures.

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

Saturated calls to `Stdlib.Int.min` and `Stdlib.Int.max` use slots from the
selected standard library's `Stdlib__Int.cmi`. The driver passes the chosen
stdlib directory through even when it disables the host include path.
These calls become a signed comparison and selection of the original tagged
integer. The compiler follows immutable local aliases, including alias
chains, for saturated calls. Partial applications and first-class aliases
keep ordinary closure behavior. Project modules named `Int` and units
with a competing `Stdlib__Int.cmi` also keep ordinary application. See
`test/int_selection_test.ml` for the emitted IL checks.

## Captures rooted by a module

Tagged literal bindings propagate before Lambda inlining. For a function
reachable through the published module structure, references to immutable
module-initialization bindings can use private module slots. The initializer
transfers one owned value to each slot. Reads borrow that root and retain it
when transferring ownership. The slot preserves the identity of the value
created at initialization. Locals with per-invocation captures keep their
closure environments.

## Small local calls after the inline budget

The Lambda inliner can expand a saturated, explicitly hinted local call
when the unit's general budget cannot cover it. An expanded body can include
other explicitly hinted local calls when the complete expansion fits the
existing 24-node fallback and call-depth bound. Oversized expansions and
explicit no-inline calls keep their ordinary entry points.

A small local wrapper whose arguments are projections, variables or tagged
literals can also forward directly to a known imported entry. The imported
call keeps its initialization dependency and exception behavior. Both
optimizations run before ARC ownership and finalizer poll insertion.

On the frozen 8,388,705-byte tterm replay, the ARM64 ASCII loop replaces
its row lookup and damage wrapper calls with an inline lookup and a direct
call to the damage unit. Its machine code went from 9,816 to 9,796 bytes.
Total native text grew by 3,984 bytes. Two paired production runs measured
37.73 to 38.41 MiB/s with 135.20 MB allocated per replay on both builds.

## Inlining imported aggregate producers

Units compiled together can share bounded Lambda bodies for functions that
return small immutable blocks. The copied code can include acyclic helper
functions with no module-local value captures. The caller keeps the provider's
initialization dependency. Lambda inlining runs before local aggregate
replacement, so a caller that only projects the result can receive the fields
at a static join without constructing the block. Persisted export summaries
continue to carry direct-entry facts.

[^design-doc]: Stage structure, goals, and the exception/fiber lowering
  plans are specified in `docs/design.md` §3–§4.

[^lib-pipeline]: The compile entry points and their output contract live in
  `lib/pipeline.mli`.

[^lambda-opt]: `lib/lambda_opt.mli` describes the facts returned alongside the optimized term.
[^anf-scalar]: `lib/anf_scalar.mli` exposes one ANF-to-ANF transformation.
