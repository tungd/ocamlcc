---
type: Concept
title: Vendored QBE
description: QBE as an out-of-tree vendored source drop under vendor/qbe, built by ninja for all targets.
tags: [qbe, vendor, build]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-13
sources:
  - id: qbe-upstream
    resource: https://c9x.me/compile/release/qbe-1.2.tar.xz
    title: QBE 1.2 release tarball
  - id: build-ninja
    resource: ../build.ninja
    title: Top-level ninja build pipeline
---

# Schema

`vendor/qbe/` is a plain source drop of the **official QBE 1.2 release**
(`https://c9x.me/compile/release/qbe-1.2.tar.xz`); its `.git` directory is
not committed — to re-vendor a different version, download the release
tarball and replace the tree[^qbe-upstream].

QBE compiles out-of-tree: objects land in `build/qbe/`, `config.h` is
generated into `build/qbe/` by `tools/gen-config.sh` (mirroring the logic in
`vendor/qbe/Makefile`), and all three code-generator targets (amd64_sysv,
arm64/_apple, rv64) are compiled so target selection stays a runtime choice
of the `qbe` driver. Note that the 1.2 release has no `gvn.c`, `gcm.c`, or
`ifopt.c` — `build.ninja` lists exactly the files the release ships.

# Implementation status

Today the pipeline shells out to `build/qbe/qbe` (1.2, phi-node IL). The
design goal is to embed QBE's generators inside the single `ocamlcc`
executable (via C stubs); that lands in Phase 4 (see
[roadmap](/concepts/roadmap.md)) and will not change the IL emitted by
[codegen](/concepts/compiler-pipeline.md).

[^qbe-upstream]: The official git repo (`c9x.me/git/qbe.git`) is not
    cloneable over its dumb-HTTP gateway; releases are fetched as tarballs
    instead.
