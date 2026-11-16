---
type: Concept
title: Perceus ARC and freestanding slab allocator
description: Static Perceus reference counting with reuse analysis, zero-leak error-return exceptions, weak references, and freestanding slab allocation.
tags: [arc, memory, allocator, perceus, phase-2]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-15
sources:
  - id: design-doc
    resource: ../docs/design.md
    title: OCaml-QBE design document
  - id: arc-pass
    resource: ../lib/arc_pass.ml
    title: Static Perceus ARC and reuse pass
  - id: arc-runtime
    resource: ../runtime/arc.c
    title: Freestanding ARC runtime and slab allocator
---

# Perceus ARC & Freestanding Slab Allocator

Phase 2 replaces libc `malloc`/`free` with a freestanding slab allocator and static Perceus reference counting with zero-leak error-return exceptions and weak references.

## Freestanding Slab Allocator (`runtime/arc.c`)
- **Size classes**: 12 classes from `16` to `2048` bytes (`16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 1024, 2048`) backed by `64 KB` slabs obtained from `pal_page_alloc`, with per-class LIFO free lists. All slots are 16-byte aligned (even user pointers, preserving the bit-0 immediate tag invariant).
- **Large blocks**: allocations `> 2048` bytes round up to `16 KB` page alignment and release directly via `pal_page_free`.
- **O(1)-stack tail drop**: `release_subtree` tail-iterates on the last dying child (`tail`) and uses a `256`-entry stack buffer plus lazy `pal_page_alloc` overflow pages (`DropPage`) for deep non-tail trees.

## Middle-End ARC Pass (`lib/arc_pass.ml`)
- **Ownership**: `Let`-bindings and function parameters start owned (`+1` rc); `Pure` global functions and static literals/immediates omit refcount traffic; closure captures (`env`), self-refs, and `LetJoin`/`While`/`For` outer references are **borrowed** (with `frame_borrowed` distinguished so exceptional unwinding cleans them up cleanly).
- **Field & mutation balance**: `Field`/`ArrayGet` retain loaded values; `SetField`/`ArraySet`/`Assign` release overwritten values; `MutLet` slots release via `ReleaseMut` on all exits.
- **In-place reuse**: `DropReuse` pairs dead unique heap blocks with downstream `AllocReuse` (even across `If` and `CheckExn` via `FreeReuse`).

## Zero-Leak Exceptions, Cycle Collection & Weak Clearing
- **Error-return channel**: `ocamlcc_exn_slot` carries raised exception blocks; `CheckExn`/`Unwind` execute local frame cleanup before branching to enclosing `TryWith` handlers or returning `1` to callers. `ce_may_raise_fn` treats `App`, yielding `Ccall`s, `Weak` `Ccall`s, `Binop ((Div | Mod), _, _)`, safe indexing (`StringGet`/`BytesSet`/`ArrayGet`/`ArraySet` with `safe = true`), `CreateBytes`, and `MakeArrayInit` as potentially raising so enclosing `TryWith` handlers retain live values, `CheckExn` unwinds frame values/reuse tokens, and `arc_alloc_bytes`/`arc_alloc_array`/`ocamlcc_weak_*` raise `Invalid_argument` (releasing consumed `init` on invalid array length) instead of aborting. `TryWith` preserves `env.frame_borrowed` alongside `catch_owned` in `try_owned` so raising inside joined expressions keeps borrowed references alive across handler and continuation execution.
- **Cycle collector (`ocamlcc_arc_collect`)**: opt-in Bacon-Rajan trial-deletion collector over candidate roots in `g_cc_roots` using `ArcHeader.reserved` color/buffer metadata; `drop_child_val` inside `release_subtree` registers surviving decremented children so cycles exposed when freeing acyclic parents are collected.
- **Weak arrays (`ARC_TAG_WEAK = 249`)**: unscanned weak slot arrays automatically cleared to `0` (`None`) inside `release_subtree` whenever any pointed-to heap object dies (including on `arc_drop_reuse` and when a dying weak array is itself tracked by another weak array after `weak_unlink`). `ocamlcc_weak_get` stays rc-neutral for the slot's uncounted target (retain before wrapping in `Some`, since the caller's field-read retain + `Some` drop + binding release net to −1); `ocamlcc_weak_get_copy` instead returns a fresh one-level block copy (same `tag`/`scan_fields`/`byte_size`, scanned fields retained, **no** wrap-retain — the fresh block's refcount 1 is exactly balanced to one free by the caller), so mutating the copy never reaches the stored element.
