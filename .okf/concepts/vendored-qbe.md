---
type: Concept
title: Vendored QBE
description: QBE 1.3 as an out-of-tree vendored source drop under vendor/qbe, built by ninja for all targets with PIC and Windows ABI support.
tags: [qbe, vendor, build, pic]
status: stable
generated:
  by: codex/1
  at: 2026-11-23
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

# CFG optimization

`Qbe_il.optimize_blocks` rewrites local branch conditions and splits wide
phi predecessor sets. The function takes blocks and a fresh-name supply
and returns the rewritten blocks and the resulting supply.

# ARM64 conditional branch reach

Generated initializers such as Uucp 17.0.0's Unicode block tables can exceed
the ARM64 conditional branch's signed 19-bit word displacement. The ARM64
emitter computes conservative upper bounds on block offsets. It retains the
direct conditional form when the bound proves the target is in range. For
longer edges it inverts the condition to skip an unconditional branch to
the target. The longer form uses the ordinary unconditional branch's
signed 26-bit word displacement.

`ninja -j1 test_qbe_arm64_long_branch` assembles and runs both forward and
backward long edges on native ARM64. On macOS ARM64, the original emitter
failed to assemble both edges. With the fix, the test passed and the
unchanged four-unit Uucp reproducer built through `ocpkg` and printed `342`.
[Package compatibility](/concepts/package-catalog.md#compatibility-evidence)

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
