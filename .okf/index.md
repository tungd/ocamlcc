---
okf_version: "0.2"
---

# ocamlcc — Knowledge Bundle

Living knowledge for the ocamlcc project: an AOT compiler backend for OCaml
targeting vendored [QBE](/concepts/vendored-qbe.md), paired with a
freestanding Perceus-ARC runtime and Wren-style stackful fibers.

Start with the canonical design document at `../docs/design.md`, then follow
links into the concepts below.

## Concepts

| Concept | Status | Summary |
|---------|--------|---------|
| [/concepts/getting-started.md](/concepts/getting-started.md) | stable | Build, smoke-test, and navigate the project. |
| [/concepts/compiler-pipeline.md](/concepts/compiler-pipeline.md) | stable | The four-stage compilation architecture. |
| [/concepts/build-pipeline.md](/concepts/build-pipeline.md) | stable | How ninja orchestrates vendored QBE, the C runtime, and dune. |
| [/concepts/value-representation.md](/concepts/value-representation.md) | stable | Tagged 63-bit immediates vs. heap ARC objects. |
| [/concepts/vendored-qbe.md](/concepts/vendored-qbe.md) | stable | QBE as an out-of-tree vendored dependency. |
| [/concepts/perceus-arc.md](/concepts/perceus-arc.md) | stable | Freestanding slab allocator, Perceus ARC, and weak refs (Phase 2). |
| [/concepts/memory-views.md](/concepts/memory-views.md) | draft | Bigarray scalar specialization and retained native memory views on ARM64/AMD64 Linux/macOS. |
| [/concepts/arc-finalizers.md](/concepts/arc-finalizers.md) | draft | Finalizer ownership, resurrection and cycle collection. |
| [/concepts/wren-fibers.md](/concepts/wren-fibers.md) | stable | Stackful fibers, shadow stack, and async poller (Phase 3). |
| [/concepts/platform-abstraction-layer.md](/concepts/platform-abstraction-layer.md) | stable | The 6-hook freestanding PAL. |
| [/concepts/roadmap.md](/concepts/roadmap.md) | stable | Phases, deliverables, and key risks. |

| [/concepts/stdlib-compatibility.md](/concepts/stdlib-compatibility.md) | stable | Upstream stdlib overlays and native test execution. |

| [/concepts/package-catalog.md](/concepts/package-catalog.md) | draft | Curated package sources, vendoring and generated rules; ocaml-crunch MVP. |

## Maintenance

This bundle is maintained in-repo: when code changes, update the affected
concepts in the same pass and append a dated entry to [log.md](log.md).
Validate with the OKF v0.2 checker before committing.
