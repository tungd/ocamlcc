---
type: Concept
title: Roadmap
description: Development phases, deliverables, and key risks with mitigations.
tags: [planning, roadmap, risks]
status: stable
generated:
  by: codex/1
  at: 2026-11-18T04:57:21Z
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
---

# Phases

Estimates assume solo development (~5–6 months total)[^design-doc].

| Phase | Duration | Deliverables | Status |
|-------|----------|--------------|--------|
| 1. Lambda → QBE MVP | 4–6 weeks | Lambda IR via compiler-libs; ANF & closure conversion; QBE SSA with self-tail-call loops; native desktop binaries. | **done** |
| 2. Perceus ARC & allocator | 5–7 weeks | Freestanding slab allocator; dup/drop/reuse pass; zero-leak error-return exceptions; Weak.t support. | **done** (`arc_test`, `exn`, `weak_cycle`) |
| 3. Wren fibers & I/O poller | 3–4 weeks | Fiber struct, shadow-stack lowering, deterministic fiber-drop cleanup, kqueue/epoll driver. | **done** (`fiber_test`, `fiber_io`) |
| 4. Mobile & cross-build CLI | 3–4 weeks | Single-binary driver (`ocamlcc build --target ...`); `.mli → .h` C99 header + FFI shim generator (`ocamlcc bindgen`); `.xcframework`, shared/static libraries, and cross-target QBE/toolchain orchestration. | **done** (`c_bindgen_test`, `driver_test`, `bindgen`) |
| 5. Core stdlib port | 3–4 weeks | Multi-module linking + ARC-native Option, Result, List, Array, Bytes, String, Buffer, Hashtbl, Printf, Weak, Fiber, Stdlib. | **done** (`mod_main`, `stdlib_test`) |

# Current focus

Improve Bigarray scalar processing and native memory views on ARM64 and AMD64,
Linux and macOS. Keep automatic ARC and QBE, with Bigarray as the opt-in path
for contiguous data and reusable native buffers. The
[memory-view implementation brief](/concepts/memory-views.md) records the
ownership contracts, compiler work, FFI changes, and behavioral checks.

MCU support, RV32, embedded runtime profiles, and backend expansion are future
work. The current brief does not introduce a general ownership/region system
or replace the existing ARC reclamation policy.

# Key risks

| Risk | Mitigation |
|------|------------|
| Unbounded mutual tail recursion (QBE has no `musttail` across mutual calls) | Compile self-recursion into explicit QBE loops; trampoline convention for mutual tail calls. |
| Hidden reference cycles leak under pure ARC | `Weak.t` in stdlib; warnings on cyclic `let rec`; opt-in trial-deletion collector. |
| Shadow-stack overhead on deep call chains | Static yield-effect inference — only potentially-suspending functions spill to the shadow stack. |

[^design-doc]: Phases, durations, and risk table mirror `docs/design.md` §6–§7.
