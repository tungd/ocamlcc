---
type: Design
title: Curated packages and vendoring companion
description: Package metadata, verified source vendoring and generated build rules, with ocaml-crunch as the first integration target.
status: draft
tags: [packages, supply-chain, ninja, compatibility]
generated: { by: codex/1, at: 2026-11-18T07:31:41+00:00 }
sources:
  - id: user-design
    resource: conversation:ocamlcc-package-companion-2026-11-18
    title: User-approved direction and ocaml-crunch MVP target
  - id: crunch
    resource: https://github.com/mirage/ocaml-crunch
    title: Upstream ocaml-crunch
  - id: stackage
    resource: https://www.stackage.org/
    title: Tested package snapshots
  - id: mfetch
    resource: https://github.com/robur-coop/mfetch
    title: Source vendoring and locking
---

# Intent

The companion is a package catalog, source acquisition tool and metadata query
interface. It emits build rules for an external executor; it does not own a
scheduler or replace Ninja/Make. A curated snapshot ties exact sources and
recipes to an ocamlcc compiler/runtime and records compatibility evidence.
Module dependency ordering is an implementation detail, not the product focus.

# Content digests

`Sha256` streams file bytes and hashes directory trees using the existing
package companion's canonical encoding. It orders paths by component and
includes the file digest and executable bit for each regular file.
Symlinks and special files are rejected.

# Model

- Snapshot: immutable package selection, dependencies, source SHA-256 digests,
  recipes, patches/adapters, and compiler/target compatibility evidence.
- Lock: project-selected dependency closure plus the snapshot and recipe digest.
- Vendor tree: complete local source inputs, materialized only by an explicit
  fetch command. Query and build generation never access the network.
- Recipe: modules, interfaces, source mappings, native inputs, generated inputs,
  dependencies and exported artifacts. Do not execute upstream install hooks.
- Query: machine-readable metadata consumed by Ninja/Make generators or callers.
- Evidence: exact toolchain/source identities, executed checks, failures/skips,
  logs and artifacts. Building alone does not assert runtime compatibility.

Vendoring and content hashes prevent silently taking changed upstream bytes
after selection. They do not prove initial source safety. Published signed
snapshots and key management are a later feature; this local MVP trusts the
checked-in catalog through repository review. Recipes are trusted executable
build instructions and receive the same review as source changes. Both source
and recipe changes must be visible in the lock. Updates are explicit.

# MVP decisions

- Temporary name: `ocpkg`. Python standard-library bootstrap follows existing
  repository build helpers and avoids requiring Dune or installing a package
  manager to run the companion. This does not decide the eventual implementation
  language.
- JSON catalog/lock/query, tarball URLs with required SHA-256, safe extraction,
  and deterministic vendor-tree verification. Reject local modifications rather
  than overwrite them. Preserve upstream licenses.
- Emit Ninja first. Use the existing ocamlcc driver for compilation ordering.
  No solver, registry service, package publishing, binary cache, signature system,
  general Dune importer or Make emitter in this slice.
- First package closure: crunch 4.1.0, Cmdliner, Ptime. Upstream crunch's Lwt,
  mirage-kv, mirage-kv-mem and fmt dependencies serve its generated-code consumer
  test, not the generator executable itself. Record that coverage separately.
- The compiler's existing source build still uses Dune. Consumers of this
  companion use an already-built ocamlcc toolchain; that bootstrap dependency is
  distinct from building vendored packages without Dune.
- A local, explicit Unix adapter may be needed for crunch. Its supported surface
  must be documented and tested; do not claim the full Unix package works.

# Implementation plan

1. Inspect and pin upstream source archives and the executable dependency closure.
2. Implement lock, vendor, status and JSON query; exercise digest mismatch,
   archive traversal, changed recipes and local source edits.
3. Emit an offline Ninja build for the closure, using explicit toolchain inputs.
4. Compile with ocamlcc, resolving only concrete compatibility gaps on the path
   to the crunch binary. Keep adapters and patches in the catalog.
5. Run the binary against upstream generation fixtures and a binary/nested-file
   round trip. Save command logs, exact identities and a machine-readable receipt.
6. Record the measured outcome and remaining limitations here, with reproducible
   commands. Keep unrelated main-worktree changes untouched.

# Progress

- Initially isolated on `codex/ocpkg-mvp` at compiler commit `81a5644`.
- Rebased onto main `c7db0de` on 2026-11-19. The combined compiler, runtime/ASan,
  15 package tests, nine Crunch integration checks and all 71 non-Lwt checks pass.
  The stdlib rebuilt all 72 modules. Fresh identities and command results are in
  `packages/evidence/main-integration-2026-11-19.json`; earlier receipts remain historical.
- Verified crunch 4.1.0 release archive against the opam SHA-256.
- Inspected upstream build and tests: executable needs Cmdliner, Ptime and Unix;
  upstream generation fixtures cover plain, extension-filtered and Lwt output.
- Implemented `tools/ocpkg.py`: exact closure locks, checked archive and source-tree
  hashes, explicit vendoring, local edit detection, JSON metadata and Ninja rules.
- 15 offline package tests pass, including actual Ninja path quoting, no-change
  rebuild behavior, and detection of timestamp-preserving vendor edits.
- ocaml-crunch 4.1.0 builds and runs on macOS arm64. All nine integration checks
  pass: version/help, four upstream golden outputs, two binary-data round trips,
  and live-clock output. Invalid command-line input also returns the expected
  usage-error exit. See `packages/evidence/crunch-macos-arm64.json` for identities,
  exact coverage and exclusions.
- Added `--runtime-objects-dir` to the compiler CLI, exposing an existing driver
  configuration field. The emitter uses an empty directory to prevent discovery
  of unrecorded prebuilt runtime objects and compiles pinned runtime sources.
- The existing compiler Dune suite passes. Dune excludes generated `build/`
  content so vendored upstream Dune projects do not join compiler validation.
- An unchanged generated build performs only verification and preserves the
  executable's modification time. Logs and receipts are under
  `build/ocpkg-final-2/` and `build/crunch/integration/`.

# Boundaries and follow-up

The observed target is macOS arm64. The Unix adapter covers only crunch's API
surface. The Lwt/Mirage generated-code consumer was not run. Separate non-Lwt
verification now covers 65 invocations of 18 upstream Cmdliner programs and
Ptime's 22 default test groups (900,813 comparisons), plus its API examples.
Ptime uses a test-only B0 assertion adapter; nine deliberate failures are
detected by negative controls on both compilers. Its libc calendar oracle is
independent of Ptime. Upstream-disabled exhaustive/clock targets remain excluded. Three Cmdliner closure groups
produce ARC-cycle warnings; successful generation is not evidence of leak-free
execution. No package source was patched to hide a compiler error.

Builds use the host `cc` and pinned compiler/QBE/stdlib/runtime files; SDKs and
system headers remain ambient. Signatures, published snapshot curation, Make
emission, independent library artifacts and general Dune recipe import remain
follow-up work. Repository review is the local snapshot trust root.

The MVP uses one driver action for an executable's entire closure. It keeps
package selection and source integrity independently queryable while leaving
scheduling to Ninja. `packages/README.md` contains the reproducible workflow.

# Non-Lwt verification

`python3 tests/ocpkg/non_lwt.py` records per-command output and exit status in
`build/crunch/non-lwt/`. The 2026-11-18 run passed both Crunch plain golden tests,
all 65 Cmdliner reference comparisons and both Ptime suites plus API examples.
The assertion-adapter controls passed separately. See
`packages/evidence/non-lwt-macos-arm64.md` for every check and the explicit
upstream test-framework adaptation. No package or upstream test body was edited.
