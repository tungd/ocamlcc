# ocpkg package catalog

`ocpkg` selects a curated dependency closure, vendors exact sources, and
builds projects offline. The catalog pins release archives by SHA-256 and
records the digest of each extracted source tree. The default cache lives in
`~/.cache/ocpkg`. Set `OCPKG_CACHE` to choose another cache.

Use `ocpkg init` to create a project. `ocpkg add NAME [VERSION]` pins and
vendors a package from the snapshot. Commit `ocpkg.mod` and `ocpkg.lock`
alongside the project sources. `ocpkg vendor --offline` restores packages
from the archive cache, and `ocpkg verify` detects edited, added, or missing
files and rejects symlinks in vendored trees. `ocpkg tidy` updates the lock
from the manifest. `ocpkg query` lists the locked closure.

`ocpkg build` uses the local vendor tree. It keeps compiled dependency
archives and export metadata in the shared cache and workspace units in
`.ocpkg/cache/unit/`. `ocpkg run -- args` runs the application. `ocpkg test`
runs the test entries declared in the manifest. The
[package catalog concept](../.okf/concepts/package-catalog.md) describes the
formats and build inputs.

## Crunch 4.1.0

The default snapshot selects Crunch 4.1.0, Cmdliner 1.3.0, and Ptime 1.2.0,
plus a local ARC Unix adapter for the API Crunch uses. It retains the
previously verified release checksums and source-tree digests. The Crunch
recipe compiles the upstream sources and stages `realpath.unix.ml` as
`realpath.ml`.

Build the checkout tools and run the native integration:

```sh
ninja -j1
sh tests/ocpkg/crunch_native.sh build/bin/ocpkg build/crunch
```

The integration uses `ocpkg vendor` and `ocpkg build` and records command
logs and nine check results in `build/crunch/receipt.txt`. The checks cover
version and help, four upstream byte-for-byte matches, two binary-data
round trips, and live-clock output. The invalid option probe also checks
the expected exit status.

## Upstream non-Lwt tests

After the native integration, run the separate differential harness:

```sh
python3 tests/ocpkg/non_lwt.py
```

The native toolchain's macOS ARM64 run passed all 71 checks. It compared
65 invocations of 18 upstream Cmdliner programs with stock OCaml, ran Crunch's
two plain golden checks, and ran the upstream Ptime assertions with a test-only
B0 adapter and independent libc calendar oracle. The harness preserves the randomized loop counts and
checks nine deliberate assertion failures on both compilers. The coverage
excludes the Lwt/Mirage consumer, Ptime's upstream-disabled exhaustive test,
and its optional clock target.
[Recorded non-Lwt results](evidence/non-lwt-macos-arm64.md)

The Unix adapter supports directory enumeration, chdir, realpath, file size,
gettimeofday and gmtime. Directory handles snapshot names, errors raise
`Sys_error`, and calendar conversion uses Ptime's supported range.

## Catalog trust

The checked-in snapshot and recipes rely on repository review. The digests
verify selected source bytes, file paths, and executable bits. Vendoring
preserves upstream archive contents and licenses, and refuses changed
package directories. Native recipe code builds with the invoking user's
access and the host SDK and system headers.
