---
type: Design
title: Native package catalog and workspace builder
description: Pinned package metadata, verified vendoring, offline incremental compilation, and the Crunch integration.
status: draft
tags: [packages, supply-chain, build-cache, compatibility]
generated: { by: codex/1, at: 2026-11-23 }
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
recipes in sorted package order. The line-based
`packages/snapshots/default.snap` catalog includes the Crunch recipes, the
ARC Unix descriptor package, and Astring, Base64, Bytesrw, Fmt, Jsonm, Logs,
Re, and Uutf. [ARC Unix compatibility](/concepts/stdlib-compatibility.md#posix-unix-compatibility)
Package names, relative paths, compilation inputs, and SHA-256 values are
validated before they enter the parsed model.

# Verified vendoring

`Pkg_vendor` resolves dependencies before their users. `Pkg_project.read_lock`
validates the manifest's requirements and replacements against the closure
stored in the lock. Build, run, test, and offline vendoring use those recipes
across toolchain snapshot updates. Extraction first checks the entire
archive for unsafe paths, duplicate members, link and
device entries, and the 256 MiB limit. It then verifies the staged tree
digest before publishing it. Vendoring refuses a changed package directory
and offline mode uses existing digest-verified archives.

# Dependency commands

The native `ocpkg` binary initializes libcurl once per process. Downloads
accept HTTPS across redirects, allow 15 seconds to connect and 120 seconds
for the full transfer, and stream at most 64 MiB to the archive cache.
`add`, `tidy`, and `upgrade` read the selected catalog. `remove`, `verify`,
`query`, and `vendor` use the locked recipes. `add`, `upgrade`, and online
`vendor` can download a recipe's archive.

`add` accepts multiple `name[@version]` selectors and deduplicates requests
that resolve to the same pin. `remove` drops direct
requirements and unused vendor trees. `upgrade` refreshes selected direct
dependencies, or all direct dependencies when invoked without names.
`tidy` regenerates the lock for the current manifest, updates existing
vendor trees from offline sources, and leaves missing packages for
`vendor`. Dependency edits check existing trees before moving them, undo
vendor moves on publication failure, and share the project lock with
commands that read the lock or build against the vendor tree.
`clean` clears workspace build artifacts. `clean --global` clears shared
compiled artifacts, downloaded archives, and the stat index. `version`
prints the version declared in `ocamlcc.opam`.

# Build cache

`Build_cache` hashes length-prefixed input fields and verifies the digest
of each stored artifact tree. The stat index under `$OCPKG_CACHE/stat-index`
reuses file digests while device, inode, size, and nanosecond modification
and change timestamps match. `--verify-cache` recomputes file hashes for
the build, and `ocpkg verify` recomputes vendor tree hashes. A builder writes
to a private directory and publishes successful outputs by rename while the
cache key is locked.

`ocpkg build` verifies the lock and vendor tree before preparing the
toolchain. The fingerprint covers the compiler, QBE, stdlib, runtime,
target, ARC profile, and compiler flags. Vendored recipes build into
archives with `.a.opt` metadata in the shared package cache. A wrapped recipe
exposes its chosen public module and keeps its prefixed implementation
interfaces on the hidden OCaml load path. C recipes can stage headers next
to their sources, supply compiler arguments with `cflag`, and supply
downstream executable or shared-library linker arguments with `ldflag`.
C source and header names may contain hyphens, so recipes can preserve
upstream header names and their corresponding includes.

Workspace units use the local `.ocpkg/cache/unit/` store, keyed by source
bytes, imported interface and export digests, and effective dependency
fingerprints. Workspace C sources compile on each build to pick up current
headers. The linker reuses a regular output whose inputs and digest still
match, with an execute permission check for executables. Executables and
shared libraries with custom linker flags resolve those inputs on every link.
The incremental test measures zero compiler and linker invocations
on an unchanged rebuild, then one compiled unit and relinking after a leaf
edit. `run` invokes the executable. `test` builds the selected manifest
entries, forwards arguments after `--`, and reports pass and failure counts.
Static and shared library builds cache their generated C bindings
alongside unit outputs. An explicit header path publishes the umbrella
header and every generated companion header. The CLI rejects conflicting
native and XCFramework output modes. An XCFramework pairs each ARM64 iOS
device or simulator archive with its own headers. Mach-O shared libraries
record the final output path as the install name for atomic publication.

On 2026-11-22, a warm, unchanged Cmdliner workspace in an extracted
macOS ARM64 bundle measured nine runs per command and toolchain. Median
`ocpkg build` time dropped from 707.3 ms to 13.7 ms, and median `ocpkg run`
time dropped from 706.0 ms to 15.4 ms. One warm build with `--verify-cache`
took 693.3 ms.

The 2026-11-23 review rechecked the unchanged Cmdliner workspace from a
relocated macOS ARM64 bundle. Over nine warm runs per command, the medians
were 15.3 ms for `ocpkg build` and 17.7 ms for `ocpkg run`. A reader blocked
while dependency metadata was being published and succeeded after the writer
released the project lock.

The native Crunch integration ran `ocpkg vendor` and `ocpkg build` on
macOS ARM64. All nine generation and runtime checks passed, including
byte-for-byte upstream golden outputs and both binary-data round trips.

# Standalone bundle

`ninja dist` creates a host bundle with both binaries, QBE, both ARC
runtime archives and their sources, the canonical stdlib archive and
source bundle, the default snapshot, and its local recipe sources.
`lib/occ/toolchain.sha256` records hashes for the bundled executables and
resources. The macOS ARM64 and Ubuntu 24.04 ARM64 smoke tests verified that
manifest, moved the extracted prefix, and ran `ocpkg init`,
`ocpkg add cmdliner`, `ocpkg build`, and `ocpkg run` outside the checkout.
They also built the same low-level example with the bundled single-thread
runtime and from the canonical stdlib sources.

The tagged workflow for `tungd/ocamlcc` targets macOS ARM64, Linux x86-64,
and Linux ARM64. Its installer selects an archive for the host and checks
it against the release's `SHA256SUMS` before extracting it. A local macOS
fixture passed installation and rejected an invalid checksum. Release
publishing and the Linux x86-64 bundle remained unverified on 2026-11-22.
[Build and release jobs](/concepts/build-pipeline.md)

# Compatibility evidence

`tests/ocpkg/crunch_native.sh` records the nine native integrations and
the invalid-option exit check. The fixture verifies generated Lwt code
and interfaces as text. The upstream Lwt/Mirage consumer suite remains
outside that coverage. The checked-in evidence files preserve the source
and toolchain identities from their historical runs.

`ninja -j1 ocpkg_catalog` vendors and tests the public APIs of Astring,
Base64, Bytesrw, Fmt, Jsonm, Logs, Re, and Uutf. It passed on macOS ARM64
and Ubuntu 24.04 ARM64. The Fmt and Logs recipes cover their core libraries.
The review also passed `ocpkg_test` and `dist_smoke` on both hosts. On macOS,
the device and simulator XCFramework slices each contained a compilable
umbrella header and its companion headers.

Uucp 17.0.0's generated Unicode block table initially hit the ARM64
conditional branch range limit. With the QBE emitter fix, a custom snapshot
with the unchanged four upstream units builds on macOS ARM64 and prints
the same block count (`342`) as stock OCaml.
[ARM64 conditional branch reach](/concepts/vendored-qbe.md#arm64-conditional-branch-reach)

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
