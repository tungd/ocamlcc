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
    resource: https://c9x.me/compile/
    title: QBE compiler homepage
  - id: build-ninja
    resource: ../build.ninja
    title: Top-level ninja build pipeline
---

# Schema

`vendor/qbe/` is a plain source drop of QBE (commit `cf06ce1` at vendoring
time, obtained from the official mirror `https://git.sr.ht/~mpu/qbe`; the
canonical upstream is `https://c9x.me/git/qbe.git`). Its `.git` directory is
not committed — to re-vendor a different version, clone upstream and replace
the tree.

QBE compiles out-of-tree: objects land in `build/qbe/`, `config.h` is
generated into `build/qbe/` by `tools/gen-config.sh` (mirroring the logic in
`vendor/qbe/Makefile`), and all three code-generator targets (amd64_sysv,
arm64/_apple, rv64) are compiled so target selection stays a runtime choice
of the `qbe` driver.

# Implementation status

Today the pipeline shells out to `build/qbe/qbe`. The design goal is to
embed QBE's generators inside the single `ocamlcc` executable (via C stubs);
that lands in Phase 4 (see [roadmap](/concepts/roadmap.md)) and will not
change the IL emitted by [codegen](/concepts/compiler-pipeline.md).
