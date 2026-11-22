---
type: Design
title: OCaml finalizers under ARC
description: Ownership, discovery and callback delivery for finalise, finalise_last and GC alarms.
tags: [arc, finalizers, weak-references, cycle-collector]
status: draft
generated:
  by: codex/1
  at: 2026-11-22
sources:
  - id: gc-api
    resource: https://ocaml.org/manual/5.5/api/Gc.html
    title: OCaml 5.5 Gc interface
  - id: gc-ml
    resource: vendor/ocaml-stdlib/src/gc.ml
    title: Vendored implementation of GC alarms
  - id: runtime
    resource: runtime/arc.c
    title: ARC destruction, weak upgrades, trial deletion and GC primitives
  - id: ffi-test
    resource: tests/mt_ffi_host.c
    title: Released callbacks across concurrent FFI mutators
  - id: contract
    resource: tests/finalizer_lifecycle.ml
    title: Executable reference contract for resurrection, weak slots and alarms
  - id: compiler
    resource: lib/anf.ml
    title: Finalizer polls at function entries and loop boundaries
  - id: abi
    resource: lib/ccalls.ml
    title: Primitive exception and fiber ABI
---

# Decision

Discover unreachable objects in the ARC runtime. Run their OCaml callbacks at a point where generated code can handle an exception and where every live OCaml value has an owner. Ordinary finalizers can publish their argument, so discovery must preserve the object and its outgoing edges. Last finalizers receive unit and become eligible after permanent death. Explicit major collections and allocation-driven polls share a dispatcher. It calls each eligible ordinary closure with its target and each eligible last closure with unit.[^runtime][^gc-api]

## Registration and ownership

Each ordinary registration owns its callback and pins its target in the runtime registry. The collection trial subtracts precisely one pin per registration from its private counts, so pins preserve storage without contributing to reachability. A callback that captures its target, even indirectly, therefore keeps it alive. Two registrations of the same function are independent. Newest-first ordinary and last registration lists preserve reverse registration order during discovery. At registration, reject immediate values, empty array constants, boxed floats and identifiable lazy/forcing/forward values with `Invalid_argument`. An accepted immortal heap constant can never become eligible. Its callback remains a root, since releasing its captures early could make other finalizers run.[^gc-api]

## What happens when an owner disappears

| Event | Runtime action |
| --- | --- |
| Last strong owner drops an object with ordinary registrations | The registration pin keeps the count positive. At a major collection, detach the registrations when the trial finds no other path. Preserve fields, backing storage and native resources. The batch owns its argument through delivery. |
| A parent drops a child, or Perceus requests storage for reuse | The pin keeps the target shared for child and root drops. Perceus therefore receives an empty reuse token. |
| An ordinary callback publishes its argument | The published owner keeps the original identity and graph alive after the batch releases its hold. Registrations already claimed stay consumed. Subsequent registrations belong to a later discovery. |
| Permanent death with only last registrations left | ARC clears weak slots before returning storage for reuse. The next eligible dispatch detaches registrations whose weak slots are empty and passes unit to their callbacks. A new object at the same address inherits nothing. |

The retirement decision and weak upgrades must agree on the winning owner under concurrency. A successful weak upgrade held at discovery delays eligibility. The pending hold for ordinary callbacks is a real reference, and releasing it goes through normal ARC. Unregistered values continue down the existing drop path. Registry bookkeeping must release displaced references after unlocking, since those releases can themselves discover more work.[^runtime]

## Lock order and the ordinary drop path

The collector takes its collection lock, excludes competing mutators, and takes the candidate-root lock. The candidate-root lock also protects ordinary registrations. The weak lock protects last registrations and their slots. A single active dispatcher owns the pending queue. Registration and queue operations must release the registry lock before entering the mutator gate, acquiring a collector or weak lock, releasing an ARC owner, waiting, or invoking a callback. A collector waiting for a mutator that is itself waiting for the collector would otherwise deadlock. Detach work into owned batches so unlocking cannot invalidate it.[^runtime]

Registration retains the target before its caller can release it. Ordinary drops and in-place reuse never consult a registration list. The collector consults the list during trial discovery. The native FFI regression drops one owner concurrently with registration, keeps two mutators active across a skipped collection, and checks single delivery after both owners release.

## Trial deletion

1. Run the existing trial to find the complete set of unreachable candidates. While the mutators are excluded, snapshot **all** ordinary registrations on that set before changing any colors. Otherwise the first finalizable vertex in a cycle could hide another in the same cycle.
2. Claim those registrations once. Keep the registration pins on all claimed targets. From the pinned targets trace all strong outgoing edges and exclude their reachable subgraph from this sweep. This includes paths through closures and suspended fibers. Order callbacks discovered together by reverse registration order, including a leaf and its registered parent.
3. Reclaim the remaining dead set. For each outgoing strong edge from that set to a survivor, decrement the survivor exactly once, including a survivor newly protected by a finalizer. Edges wholly inside the reclaimed set need no decrement. Noncandidate leaves losing their last owner use normal retirement. Preserve the existing collector count of objects actually reclaimed.
4. Release collector locks and reopen the mutator gate before dispatch. A completed collection and a collection skipped because another mutator is active are distinct outcomes even though the current primitive can return zero for either. A skipped trial preserves all undiscovered registrations. The caller may still deliver work that an earlier successful trial discovered and a callback explicitly released. When the batch drops its pins, surviving cycles become candidates for another trial. Finalizers may have altered arbitrary edges, so that trial evaluates the graph again.[^runtime]

## Delivery, exceptions and alarms

Queue batches in discovery order. Within each simultaneous discovery, run ordinary callbacks in reverse registration order. Last callbacks for a target wait for all of its ordinary callbacks, including any subsequent registrations and resurrection. By the time a last callback runs, a weak lookup of its target returns `None`. Ephemeron clearing belongs to the same permanent-death phase when that API gains runtime support.[^gc-api][^runtime]

Programs can request delivery with `Gc.major`, `Gc.full_major`, or `Gc.compact`. A successful trial freezes its eligible ordinary registrations before the dispatcher starts. A callback that re-registers its argument can run again at a later collection. A nested collection leaves the current callback in control until it calls `Gc.finalise_release`. The vendored alarm uses this re-registration behavior and checks its active flag to honor deletion.[^gc-ml]

One dispatcher enters the mutator context and removes each pending registration before calling its closure. An outstanding exception defers dispatch. If a callback raises, the dispatcher releases its owners, preserves the remaining queue and propagates the exception at the explicit collection or generated poll. Each call into the dispatcher carries the raising and yielding ABI. Raw collection from a C host can reclaim cycles without entering OCaml code. Process exit has no guaranteed finalizer flush.[^abi]

### Allocation-driven delivery

A counted loop uses the low six bits of its raw induction variable
minus the initial index. It checks on the first iteration and then every
64 iterations in either direction. Address arithmetic and this poll do
not require a tagged copy of the index.

When registrations exist, the runtime compares allocation progress since the last completed dispatch with the minor-heap size from `Gc.get ()`. Each newly allocated word and each successful in-place reuse advance the counter. Reuse leaves the public allocation statistics unchanged. Finishing a dispatch also accounts for work done inside callbacks. A skipped collection leaves the allocation budget due.[^runtime]

The ANF poll lowers to a branch on the aligned registration count. A zero
count continues directly. A nonzero count checks the dispatch state and
allocation budget. The path that dispatches callbacks handles any exception
before rejoining the caller.

Generated code omits entry polls in bounded leaf functions. The analysis
follows switch arms, local static exits and mutable slots. Calls, allocations, checked operations and generic array reads that can box
floats keep the conservative path. Local field stores and integer division
or remainder by a known nonzero divisor can omit the entry poll. Scalar cross-unit expressions expanded in the
caller qualify as local operations. A self-tail loop made entirely of local
operations checks on entry and then every 64 backedges using a counter in
the loop header. Other recursive bodies and explicit Lambda polls retain
their original cadence.

A `for` body checks on the first iteration and every 64 iterations
in either direction. A `while` with a bounded condition and body checks on
the first condition evaluation and every 64 evaluations thereafter. The
compiler keeps an immediate local counter for that cadence. Other `while` loops check each condition evaluation. A due poll enters the
dispatcher with live owners available for exception unwinding. With an empty
registry, the check returns after a single relaxed load of the registration
count. That count includes pending callbacks through dispatch. A nonempty
registry checks for handed-off work or an exhausted allocation budget.
Cycles without registrations await explicit collection. Straight-line
allocations can cross the budget before execution reaches a poll.[^compiler][^abi][^runtime]

A known call that can propagate only an automatic finalizer exception
checks a process-wide flag before reading the fiber’s exception slot. The
dispatcher sets this flag when an automatic callback raises, and it stays
set even after the final registration is removed. Potential ordinary
exceptions still check the slot directly.

### Releasing dispatch

`Gc.finalise_release ()` lets another collection dispatch while the caller continues. It returns unit and runs no user code itself. Only the executing callback’s fiber can give up dispatch. A repeated release, or one from outside a callback, has no effect. The registration has already left the queue. Its closure stays owned until return, and compiled code owns its argument across the nested collection. On return, a released callback can resume draining the queue only if it reacquires dispatch.[^runtime][^gc-api]

The reference fixture attaches two ordinary callbacks to one ref. The first attempts a collection before release and again after release. The second increments the ref. The first reads both that increment and its captured byte buffer before returning. A subsequent collection checks that each callback ran once.[^contract]

Releasing with callbacks still queued publishes that work to the next compiler poll or explicit collection. A second FFI mutator can drain it while the first callback waits. If multiple mutators prevent a fresh trial, new registrations wait and the allocation budget stays due. The native FFI fixture exercises both entry points and counts exactly one callback before the releasing thread resumes.[^runtime][^ffi-test]

### Remaining delivery work

Callbacks run on the thread that wins dispatch. Delivering an alarm on its registering domain requires recording that owner and handling domain exit.[^gc-api]

## Executable reference

Run the standalone fixture from the repository root. It checks reverse registration order, resurrection with an intact payload and cycle, eventual last-callback delivery after weak clearing, and repeatable alarm delivery followed by deletion. It deliberately fails if registration is unsupported. Stock OCaml 5.5.0 passed each case. Its allocation-only cases check alarm delivery and deletion in a loop, and propagate a last-finalizer exception through tail recursion while a handler still owns a byte buffer.[^contract]

```sh
ocaml tests/finalizer_lifecycle.ml
# With the canonical archive already built
work=$(mktemp -d)
build/bin/occ build --stdlib-dir build/stdlib tests/finalizer_lifecycle.ml -o "$work/run"
"$work/run"
```

## Ordinary finalizer regression

The exception regression checks that the caller catches a raised callback exception and an older registration still runs once. The batch regression checks one callback per distinct target across trial-map growth. The repository fixture also exercises a rooted ref, publication by its callback, and weak clearing after the published owner releases it.

The upstream Marshal `intern_final` test now completes. Its final output does not count alarm firings. The separate lifecycle fixture directly observes alarm delivery, re-registration and deletion under explicit and allocation-driven collections.

[^gc-api]: Public eligibility, callback ordering, resurrection, weak visibility and alarm guarantees.
[^gc-ml]: `create_alarm`, `call_alarm` and `delete_alarm` use ordinary finalization and an active flag.
[^runtime]: `arc_release`, `drop_child_val`, `release_subtree`, `arc_drop_reuse`, `ocamlcc_arc_collect` and the GC primitives are the relevant runtime seams.
[^ffi-test]: The two-thread handoff fixture checks foreign release attempts and delivery through both polls and explicit collection.
[^contract]: `tests/finalizer_lifecycle.ml` uses the public Gc and Weak APIs.
[^compiler]: The ANF conversion inserts the check before ARC computes liveness.
[^abi]: The primitive table distinguishes the cheap eligibility check from the raising and yielding dispatcher.

The Lambda bounds pass requires nonnegative and exclusive-upper-bound
proofs for the same stable index and receiver. It follows ordinary
short-circuit guards and immutable projections. Mutable field reloads and
unproved arithmetic keep their checked path. The ARC effect scan already
attributes escaping exceptions from a try expression to its handler.
Regression cases distinguish a total handler from a rethrow.
