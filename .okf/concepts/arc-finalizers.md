---
type: Design
title: OCaml finalizers under ARC
description: Proposed ownership, discovery and callback delivery for finalise, finalise_last and GC alarms.
tags: [arc, finalizers, weak-references, cycle-collector]
status: draft
generated:
  by: codex/1
  at: 2026-11-18
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
  - id: contract
    resource: tests/finalizer_lifecycle.ml
    title: Executable reference contract for resurrection, weak slots and alarms
  - id: abi
    resource: lib/ccalls.ml
    title: Primitive exception and fiber ABI
---

# Decision

Discover unreachable objects in the ARC runtime. Run their OCaml callbacks at a point where generated code can handle an exception and where every live OCaml value has an owner. Ordinary finalizers can publish their argument, so discovery must preserve the object and its outgoing edges. Last finalizers receive unit and become eligible after permanent death. Today both registration primitives raise `Failure`. This document defines their intended replacement.[^runtime][^gc-api]

## Registration and ownership

A runtime side table associates each target identity with registrations. Each registration owns its callback closure. Its target key is weak. A callback that captures its target, even indirectly, therefore keeps it alive. Two registrations of the same function are independent. Give registrations a serial number under the registry lock. At registration, reject immediate values, empty array constants, boxed floats and identifiable lazy/forcing/forward values with `Invalid_argument`. An accepted immortal heap constant can never become eligible. Its callback remains a root, since releasing its captures early could make other finalizers run.[^gc-api]

## What happens when an owner disappears

| Event | Runtime action |
| --- | --- |
| Last strong owner drops an object with ordinary registrations | Atomically transfer the retiring reference to one pending batch before the count can reach zero. Detach the eligible registrations. Preserve fields, backing storage and native resources. The batch owns its argument through delivery. |
| A parent drops a child, or Perceus requests storage for reuse | Use the same retirement decision for children and roots. A pending ordinary batch prevents teardown. Return an empty reuse token for its target. |
| An ordinary callback publishes its argument | The published owner keeps the original identity and graph alive after the batch releases its hold. Registrations already claimed stay consumed. Subsequent registrations belong to a later discovery. |
| Permanent death with only last registrations left | Detach the callbacks, clear weak slots and remove the identity from the table before exposing storage for reuse. Complete normal teardown and enqueue unit callbacks with no target pointer. A new object at the same address inherits nothing. |

The retirement decision and weak upgrades must agree on the winning owner under concurrency. A successful weak upgrade before retirement delays death. The pending hold for ordinary callbacks is a real reference, and releasing it goes through normal ARC. Unregistered values continue down the existing drop path. Registry bookkeeping must release displaced references after unlocking, since those releases can themselves discover more work.[^runtime]

## Trial deletion

1. Run the existing trial to find the complete set of unreachable candidates. While the mutators are excluded, snapshot **all** ordinary registrations on that set before changing any colors. Otherwise the first finalizable vertex in a cycle could hide another in the same cycle.
2. Claim those registrations once. Pin each distinct target. From the pinned targets trace all strong outgoing edges and exclude their reachable subgraph from this sweep. This includes paths through closures and suspended fibers. Order callbacks discovered together by decreasing registration serial, including registrations on different objects.
3. Reclaim the remaining dead set. For each outgoing strong edge from that set to a survivor, decrement the survivor exactly once, including a survivor newly protected by a finalizer. Edges wholly inside the reclaimed set need no decrement. Noncandidate leaves losing their last owner use normal retirement. Preserve the existing collector count of objects actually reclaimed.
4. Release collector locks and reopen the mutator gate before dispatch. A completed collection and a collection skipped because another mutator is active are distinct outcomes even though the current primitive can return zero for either. A skipped attempt preserves registrations and pending work. When the batch drops its pins, surviving cycles become candidates for another trial. Finalizers may have altered arbitrary edges, so that trial evaluates the graph again.[^runtime]

## Delivery, exceptions and alarms

Queue batches in discovery order. Within each simultaneous discovery, run ordinary callbacks in reverse registration order. Last callbacks for a target wait for all of its ordinary callbacks, including any subsequent registrations and resurrection. By the time a last callback runs, a weak lookup of its target returns `None`. Ephemeron clearing belongs to the same permanent-death phase when that API gains runtime support.[^gc-api][^runtime]

Use explicit major collection calls as initial delivery points. A completed major cycle advances a generation even when it reclaims zero objects. Freeze its eligible work before draining. A registration created inside a callback can first run in a later eligible generation. A major collection requested by an alarm callback cannot trigger that same alarm. The vendored alarm callback re-registers itself and checks an active flag, so deletion suppresses future user calls. The primitive sees ordinary registrations for alarms. Associate registrations with their creating domain and dispatch there while it is live. On domain exit, run its alarm deactivation hooks before transferring outstanding registrations to a surviving dispatcher. Cycle collection is currently opt-in. For automatic progress while finalizers are registered or pending, charge allocations and service major work at compiler-emitted polls in allocating loops and call paths, after establishing live roots. With no finalizer work, the collector keeps its existing opt-in policy. This gives an allocating program progress without invoking OCaml from a C allocator. Exact allocation cadence is a scheduling policy.[^gc-ml][^gc-api]

One dispatcher owns a callback at a time. It takes work under a lock, unlocks, and enters the OCaml mutator context before applying the closure. It consumes the registration before calling user code. A nested collection may discover work. Only an explicit `Gc.finalise_release ()` hands off the right to start the next eligible callback while the current callback is active. Releasing that right preserves the current callback’s roots, and returning from it must never revoke a newer dispatcher’s ownership. A callback can yield, so dispatch sites must support the fiber/shadow-stack ABI as well as exceptions. Keep queue entries and arguments owned through suspension. If an exception is already pending, defer dispatch. If a callback raises, release its holds, preserve remaining entries and propagate the exception at the calling OCaml poll. A raw C release, collector call, or FFI teardown can enqueue work without acquiring an OCaml exception handler. Process exit has no guaranteed finalizer flush.[^abi][^gc-api]

## Executable reference

Run the standalone fixture from the repository root. It checks reverse registration order, resurrection with an intact payload and cycle, eventual last-callback delivery after weak clearing, and repeatable alarm delivery followed by deletion. It deliberately fails if registration is unsupported. Stock OCaml 5.5.0 passed each case. The current ARC executable built successfully and exited at the first registration with `Gc.finalise: unsupported by ARC`.[^contract]

```sh
ocaml tests/finalizer_lifecycle.ml
# With the compatibility archive already built
work=$(mktemp -d)
build/bin/ocamlcc build --stdlib-dir build/stdlib_compat/out tests/finalizer_lifecycle.ml -o "$work/run"
"$work/run"
```

## First implementation slice

Start with a dynamically allocated ref whose ordinary callback reads the ref, publishes it, and returns. Exercise the path from last-owner release through `Gc.full_major` delivery, then release the published ref and check that the callback ran once. Extend that same test to a self-cycle discovered by trial deletion, followed by last-callback delivery with its weak slot cleared. Both paths must preserve the same observable object identity. Use a separate alarm that counts calls and can be deleted to exercise re-registration. The upstream Marshal `intern_final` test validates data during interleaving, but its success message alone does not establish that its alarm fired.

[^gc-api]: Public eligibility, callback ordering, resurrection, weak visibility and alarm guarantees.
[^gc-ml]: `create_alarm`, `call_alarm` and `delete_alarm` use ordinary finalization and an active flag.
[^runtime]: `arc_release`, `drop_child_val`, `release_subtree`, `arc_drop_reuse`, `ocamlcc_arc_collect` and the GC primitives are the relevant runtime seams.
[^contract]: `tests/finalizer_lifecycle.ml` uses the public Gc and Weak APIs.
[^abi]: The primitive table currently marks major collection calls as raising and non-yielding.
