# ocpkg companion MVP

`tools/ocpkg.py` selects a curated package closure, vendors exact source trees,
queries package metadata as JSON, and emits Ninja rules. It does not schedule
builds or run a dependency solver. Python 3.11+ and its standard library suffice
to run the companion. Ninja and an existing ocamlcc toolchain perform builds.

The design and implementation plan are in
[the package catalog concept](../.okf/concepts/package-catalog.md).

## First target: ocaml-crunch

The checked-in snapshot selects crunch 4.1.0, Cmdliner 1.3.0 and Ptime 1.2.0,
plus an explicit ARC Unix adapter for the API crunch uses. Release archives
were checked against opam repository checksums before deriving their SHA-256
and extracted-tree hashes. Recipes compile upstream `.ml`/`.mli` sources
directly; no upstream Dune, Topkg, Make, or install hooks run. Crunch sources
are unchanged. The `realpath.unix.ml` selection is staged as `realpath.ml`.

Start from an existing compiler and compatibility stdlib. In a fresh compiler
checkout, their **bootstrap** is still the repository's existing build:

```sh
ninja -j1 build/bin/occ build/qbe/qbe build/rt/libocamlrt.a
python3 tools/stdlib_compat.py --skip-tests
```

Then the package workflow is:

```sh
python3 tools/ocpkg.py lock \
  --snapshot packages/snapshots/crunch-mvp.json --package crunch \
  --output build/crunch/ocpkg.lock.json
python3 tools/ocpkg.py vendor \
  --lock build/crunch/ocpkg.lock.json --directory build/crunch/vendor
python3 tools/ocpkg.py query --lock build/crunch/ocpkg.lock.json
python3 tools/ocpkg.py emit ninja \
  --lock build/crunch/ocpkg.lock.json --vendor build/crunch/vendor \
  --output build/crunch/build.ninja --compiler build/bin/occ \
  --qbe build/qbe/qbe --stdlib build/stdlib_compat/out --runtime runtime
ninja -j1 -f build/crunch/build.ninja
build/crunch/ocaml-crunch --version
```

Only `vendor` accesses the network; add `--offline` to require cached archives.
The default cache is `build/ocpkg-cache`, keyed by archive SHA-256. Entire source
archives are retained in the vendor tree, including licenses and test fixtures.
Sources are never fetched implicitly by Ninja. Paths in generated build files
are absolute; regenerate rules after relocating a checkout.

`status --lock ... --directory ...` checks all vendored file contents and
executable bits against locked tree hashes. Added, missing or edited files and
symlinks are detected. Fetching never overwrites a modified package directory.
To adopt an upstream or local adapter change, update its snapshot entry and
hashes, regenerate the lock explicitly, and vendor into a new directory.

The generated rules verify the lock, snapshot, source trees and toolchain
files on every Ninja invocation. A successful no-change check preserves its
stamp, so it does not trigger compilation. The recorded host `cc` resolution
must remain unchanged. The compiler's `--runtime-objects-dir` option points at
an explicitly empty directory, so the driver compiles the fingerprinted runtime
sources instead of discovering unrecorded prebuilt objects. The verifier checks
that the directory remains empty. C compiler SDKs/system headers and other ambient host
state are **not** a hermetic toolchain closure.

The MVP emits one driver build action for the selected executable closure.
Package-by-package archives, fine-grained module rules, Make output, general
Dune import, signatures, published snapshots and automatic package updates are
future work. Metadata exports currently describe OCaml module names, not a
complete installed-library discovery protocol.

## Compatibility evidence

```sh
python3 -m unittest discover -s tests/ocpkg -v
python3 tests/ocpkg/crunch_integration.py
python3 tests/ocpkg/non_lwt.py
```

The integration harness records full command logs, exit codes, binary/plan
hashes, upstream output comparisons and generated-code round trips under
`build/crunch/integration/`. Each command has a timeout; timed-out process groups
are terminated and reported. The generation tests include Lwt output, but do
not compile/run the upstream Lwt/Mirage consumer. That exclusion remains explicit
in the receipt. The separate non-Lwt runner executes Crunch's two plain golden
checks, compares 65 invocations of 18 upstream Cmdliner programs with stock OCaml,
and runs unchanged upstream Ptime assertions using a test-only B0 adapter. It
preserves the upstream randomized loop counts and uses an independent libc
`gmtime_r` oracle. Negative controls verify nine deliberate assertion failures
are detected on both compilers. Ptime's exhaustive `test_gmtime_all` and
`min_clock` remain excluded as upstream `run:false` targets.

See [the individual non-Lwt results](evidence/non-lwt-macos-arm64.md). This is
package behavior coverage, not validation of the upstream B0 framework itself.
The runner waits for existing compiler jobs and serializes every compilation;
its receipts retain stdout, stderr, exit codes, timeouts and source identities.

The Unix adapter exports directory enumeration, chdir, realpath, stat's size,
gettimeofday and gmtime. Directory handles hold a snapshot of names, errors
raise `Sys_error`, and calendar conversion uses Ptime's supported range.
It is deliberately recorded as `crunch-unix`, not advertised as a compatible
implementation of OCaml's complete Unix library.

## Trust boundary

The local snapshot and recipes are trusted through repository review. Hashes
detect changes to selected bytes; they do not establish initial source safety
or protect against a malicious change to the trusted snapshot itself. This MVP
does not implement snapshot signatures, provenance attestations, a sandbox, or
binary reproducibility. Native recipe code runs with the build user's access.
