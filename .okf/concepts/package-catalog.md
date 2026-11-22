---
type: Design
title: Native package catalog and workspace builder
description: Pinned package metadata, verified vendoring, offline incremental compilation, and the Crunch integration.
status: draft
tags: [packages, supply-chain, build-cache, compatibility]
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

# Native toolchain

`occ` compiles OCaml to native code with QBE and the ARC runtime. `ocpkg`
manages the project manifest, curated dependency closure, vendor tree,
and incremental builds. Both binaries find their bundled resources
relative to the installation prefix under `lib/occ/`.

# Content digests

`Sha256` streams file bytes and hashes directory trees using the existing
package companion's canonical encoding. It orders paths by component and
includes the file digest and executable bit for each regular file.
Symlinks and special files are rejected.

# Text formats

`ocpkg.mod` declares the project kind, entry point, source paths, and direct
requirements. `ocpkg.lock` records the selected catalog digest and resolved
recipes in sorted package order. The native tool reads the line-based
`packages/snapshots/default.snap` catalog derived from the Crunch snapshot.
Package names, relative paths, compilation inputs, and SHA-256 values are
validated before they enter the parsed model.

# Verified vendoring

`Pkg_vendor` resolves dependencies before their users and re-derives the
locked closure from the selected catalog and project inputs. Extraction first
checks the entire archive for unsafe paths, duplicate members, link and
device entries, and the 256 MiB limit. It then verifies the staged tree
digest before publishing it. Vendoring refuses a changed package directory
and offline mode uses existing digest-verified archives.

# Dependency commands

The native `ocpkg` binary links libcurl. Its downloads accept HTTPS across
redirects, time out after 30 seconds, and stream at most 64 MiB to the
archive cache. `add`, `get`, and `vendor` can download package sources.
`vendor --offline`, `tidy`, `verify`, and `query` work from local inputs.

# Build cache

`Build_cache` hashes length-prefixed input fields and verifies the digest
of each stored artifact tree. A builder writes to a private directory.
Successful outputs are published by rename while the cache key is locked.

`ocpkg build` verifies the lock and vendor tree before preparing the
toolchain. The fingerprint covers the compiler, QBE, stdlib, runtime,
target, ARC profile, and compiler flags. Vendored recipes build into
archives with `.a.opt` metadata in the shared package cache. A wrapped recipe
exposes its chosen public module and keeps its prefixed implementation
interfaces on the hidden OCaml load path.

Workspace units use the local `.ocpkg/cache/unit/` store, keyed by source
bytes, imported interface and export digests, and effective dependency
fingerprints. The linker reuses an output whose inputs and digest still
match. The incremental test measures zero compiler and linker invocations
on an unchanged rebuild, then one compiled unit and relinking after a leaf
edit. `run` invokes the executable and `test` builds the selected manifest
entries. Static and shared library builds cache their generated C bindings
alongside unit outputs. Mach-O shared libraries record the final output
path as the install name, which supports atomic publication.

The native Crunch integration ran `ocpkg vendor` and `ocpkg build` on
macOS ARM64. All nine generation and runtime checks passed, including
byte-for-byte upstream golden outputs and both binary-data round trips.

# Standalone bundle

`ninja dist` creates a host bundle with both binaries, QBE, both ARC
runtime archives and their sources, the canonical stdlib archive and
source bundle, the default snapshot, and its local recipe sources. The
macOS ARM64 smoke moved the extracted prefix to a new path and ran
`ocpkg init`, `ocpkg add cmdliner`, `ocpkg build`, and `ocpkg run` outside
the checkout. It also built the same low-level example with the bundled
single-thread runtime and from the canonical stdlib sources.

# Compatibility evidence

`tests/ocpkg/crunch_native.sh` records the nine native integrations and
the invalid-option exit check. The fixture verifies generated Lwt code
and interfaces as text. The upstream Lwt/Mirage consumer suite remains
outside that coverage. The checked-in evidence files preserve the source
and toolchain identities from their historical runs.

The local snapshot and recipes rely on repository review. The vendor
and cache checks verify selected source and artifact bytes. Native
builds use the host C tools, SDK, and system headers.

# Non-Lwt verification

`python3 tests/ocpkg/non_lwt.py` records per-command output and exit status in
`build/crunch/non-lwt/`. The native toolchain's macOS ARM64 run passed all
71 checks, including both Crunch plain golden tests, all 65 Cmdliner reference
comparisons, and the Ptime suites and API examples. The assertion-adapter
negative controls passed. See
`packages/evidence/non-lwt-macos-arm64.md` for every check and the explicit
upstream test-framework adaptation. No package or upstream test body was edited.
