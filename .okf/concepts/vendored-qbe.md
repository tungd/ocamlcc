---
type: Concept
title: Vendored QBE
description: QBE 1.3 as an out-of-tree vendored source drop under vendor/qbe, built by ninja for all targets with PIC and Windows ABI support.
tags: [qbe, vendor, build, pic]
status: stable
generated:
  by: autoagent/1
  at: 2026-11-17
sources:
  - id: qbe-upstream
    resource: https://c9x.me/compile/release/qbe-1.3.tar.xz
    title: QBE 1.3 release tarball
  - id: build-ninja
    resource: ../build.ninja
    title: Top-level ninja build pipeline
---

# Schema

`vendor/qbe/` is a plain source drop of the **official QBE 1.3 release**
(`https://c9x.me/compile/release/qbe-1.3.tar.xz`); its `.git` directory is
not committed — to re-vendor a different version, download the release
tarball and replace the tree[^qbe-upstream].

QBE compiles out-of-tree: objects land in `build/qbe/`, `config.h` is
generated into `build/qbe/` by `tools/gen-config.sh` (mirroring the logic in
`vendor/qbe/Makefile`), and all target generators (`amd64_sysv`, `amd64_apple`,
`amd64_win`, `arm64`, `arm64_apple`, `rv64`) are compiled so target selection
stays a runtime choice of the `qbe` driver. QBE 1.3 adds `gvn.c`, `gcm.c`,
`ifopt.c`, `amd64/winabi.c`, upstream `R18`/`IP1` reservation on Darwin arm64,
and `extern $sym` PIC addressing (`:got:`/`:got_lo12:` on ELF arm64,
`@gotpcrel`/`@plt` on ELF amd64, `@gotpage`/`@gotpageoff` on Apple arm64,
`la` on rv64).

# Implementation status

Today the pipeline shells out to `build/qbe/qbe` (1.3, phi-node IL).
`Qbe_il.to_string` emits `extern $sym` inside function bodies for external
and exported symbols (while keeping non-exported local data/functions direct
PC-relative), enabling `-shared -fPIC` `.so`/`.dylib` builds without text
relocations. The design goal is to embed QBE's generators inside the single
`ocamlcc` executable (via C stubs); that lands in Phase 4 (see
[roadmap](/concepts/roadmap.md)).

[^qbe-upstream]: The official git repo (`c9x.me/git/qbe.git`) is not
    cloneable over its dumb-HTTP gateway; releases are fetched as tarballs
    instead.
