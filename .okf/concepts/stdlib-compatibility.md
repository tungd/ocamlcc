---
type: Concept
title: Upstream standard library compatibility
description: Pinned OCaml sources, ARC overlays, and native upstream test execution.
tags: [stdlib, compatibility, testing, arc]
status: stable
generated:
  by: codex/1
  at: 2026-11-19
sources:
  - id: runner
    resource: tools/stdlib_compat.py
  - id: upstream
    resource: vendor/ocaml-stdlib/UPSTREAM.txt
  - id: lexing-overlay
    resource: stdlib/overlay/lexing.ml
  - id: parsing-overlay
    resource: stdlib/overlay/parsing.ml
  - id: bigarray-runtime
    resource: runtime/bigarray.inc
  - id: marshal-runtime
    resource: stdlib/camlinternalMarshal.ml
  - id: channel-runtime
    resource: stdlib/camlinternalChannel.ml
  - id: api-regressions
    resource: tools/stdlib_regressions.py
  - id: runtime
    resource: runtime/arc.c
  - id: numeric-format
    resource: runtime/builtins.c
  - id: int-fmt
    resource: stdlib/camlinternalIntFmt.ml
  - id: bulk-ops
    resource: stdlib/camlinternalBulkOps.ml
  - id: runtime-tests
    resource: tests/stdlib_runtime.c
---

# Build and test

`tools/import-ocaml-stdlib.sh` vendors OCaml 5.5.0 standard library sources,
interfaces, licenses, and 48 upstream `lib-*` test directories. The pin is
recorded in `vendor/ocaml-stdlib/UPSTREAM.txt`.[^upstream]

After `ninja -j1`, run `python3 tools/stdlib_compat.py`. The runner selects
`stdlib/overlay/` files before upstream sources, compiles the interfaces and
implementations with ocamlcc/QBE, archives the objects, and links upstream tests
against that archive and our ARC runtime. It does not use the host OCaml runtime.
`build/stdlib_compat/report.md` records module and test outcomes.[^runner]

`stdlib/camlinternalIntFmt.ml` (`--nopervasives`, compiled right after `CamlinternalFormatBasics`) implements integer parsing and formatting (`format_int`, `format_int32`, `format_int64`, `format_nativeint`, `parse_int`, `parse_int32`, `parse_int64`, `parse_nativeint`) in pure OCaml, replacing the C `caml_*format*` / `caml_*_of_string` implementations previously in `runtime/builtins.c`/`runtime/arc.c`. It handles 63-bit signed decimal bounds (`[-(1<<62), (1<<62)-1]`), signed/unsigned base-prefixed literals (`"-0x30"`, `"0x7fffffffffffffff"` -> `-1`, magnitude `<= INT64_MAX`, sign-extending bit 62) matching `Misc.Int_literal_converter.int`, 32/64-bit parsing, and `%[flags][width][.prec][l|ll|L|n][d|i|u|x|X|o]` formatting.[^int-fmt]

`stdlib/camlinternalBulkOps.ml` (`--nopervasives`, compiled right after `CamlinternalIntFmt`) implements `blit_bytes`, `blit_string`, `fill_bytes`, `string_equal`, `bytes_equal`, `string_compare`, `bytes_compare`, `string_hash`, `array_sub`, `array_append`, `array_concat`, `array_blit`, `array_fill`, `array_create_float`, and `floatarray_{create,make,sub,append,concat,blit,fill}` in pure OCaml (reusing `%opaque` casts over `ARC_TAG_FLOAT_ARRAY` / `ARC_TAG_ARRAY`), removing those C implementations and `caml_bswap*` / `caml_bytes_{get,set}{16,32,64}_*` from `runtime/arc.c` (`runtime/arc.h`, `lib/ccalls.ml`).[^bulk-ops]

The Lexing overlay implements both DFA engines in OCaml, including signed
16-bit transitions, unsigned memory-code offsets, captures, backtracking,
refill continuations, EOF, and positions. `tests/stdlib/lexing` uses real
ocamllex output and passes against both stock OCaml and ocamlcc.
The Digest overlay (`stdlib/overlay/digest.ml`) implements RFC 1321 MD5 and
RFC 7693 BLAKE2b (`MD5`, `BLAKE128`, `BLAKE256`, `BLAKE512`) in pure OCaml
with zero C externals (`ARC_CUSTOM_BLAKE2`, `caml_md5_*`, and `caml_blake2_*`
removed from `runtime/` and `lib/ccalls.ml`).
The Parsing overlay interprets ocamlyacc action/goto tables in OCaml and
preserves token translation, stack growth, reductions, error recovery,
semantic-action suspension, positions, and trace state. A generated-parser
fixture checks reductions, deep nesting, parse errors, and subsequent parses.
Bigarray primitive lowering dispatches typed and generic 1/2/3-dimensional
accesses to ARC runtime helpers. `%caml_ba_dim_N` is translated from its
one-based primitive number to the zero-based generic dimension API. Views
retain a backing descriptor. When the last view dies, the runtime frees its
PAL allocation or invokes the imported buffer’s release callback. The core
API supports all element kinds, both layouts, checked indexing, fill/blit,
and shared sub/slice/reshape/layout views. These helpers
live in `runtime/bigarray.inc`, included by `arc.c`. C callers can retain a
subview with its data and dimensions across collection. The public interface
is documented in [memory views](/concepts/memory-views.md).
The native stdlib build now compiles all 76/76 modules. `stdlib/camlinternalChannel.ml` (`--nopervasives`, compiled right after `CamlinternalBulkOps` and before `CamlinternalMarshal`) implements buffered `in_channel` and `out_channel` (4096-byte `bytes` buffers, weak array registry for `out_channels_list ()` / `flush_all ()`, unbuffered mode, 64-bit `LargeFile` seeks/lengths, `input_scan_line`, binary 32-bit ints, and Bigarray 1D `char` slice transfers) over thin POSIX fd shims (`ocamlcc_raw_fd_{read,write,lseek,size,close,isatty}`, `ocamlcc_stdio_flush`, and `ocamlcc_ba_{to_bytes,of_bytes_slice}`), removing `OcamlccChannel`, `ARC_TAG_CHANNEL`, and all `caml_ml_*` channel functions from `runtime/arc.c` and `runtime/arc.h`. `stdlib/camlinternalMarshal.ml` (`--nopervasives`, compiled right after `CamlinternalChannel`) implements Marshal in pure OCaml over `CamlinternalChannel` and tiny object/bigarray metadata helpers (`ocamlcc_ptr_id`,
`ocamlcc_marshal_kind`, `ocamlcc_ba_info`/`read_bytes`/`of_bytes`), supporting
uncompressed standard streams (`0x8495a6be`/`0x8495a6bf`, relative sharing
distances) and optional OCaml-hook-backed compressed streams (`0x8495a6bd` with
10–63 byte VLQ headers and 0-based absolute sharing indices per OCaml 5.5
`extern.c`/`intern.c` via `CamlinternalMarshal.register_codec`, registered by
`compiler-libs`'s `Compression` over `ocamlcc_zstd_{compress,decompress}_bytes`
while keeping `libocamlrt.a` zstd-free) for integers,
ordinary blocks, strings, floats, float arrays, and boxed integers, via
strings/bytes/buffers/channels (reading channels in bounded 64 KiB chunks so
malformed multi-GB headers fail cleanly on EOF without OOM). The
encoder uses an open-addressed pointer map and explicit work stack. The decoder
registers objects before their fields, severs partial cyclic block edges before
dropping `owners` on error so ARC reclaims partial graphs without leaks. Arrays and ordinary tag-zero blocks
share OCaml structural comparison/hash semantics despite their ARC tags.
Functional values raise `Invalid_argument`, including when `Closures` is set;
there is no portable native code-pointer registry.
Bigarray custom payloads use upstream `_bigarr02` descriptors, packed dimensions,
layout/kind flags, big-endian element data, and native-int width markers.
Repository regressions preserve sharing/cycles and distinguish `No_sharing`,
traverse 50,000-element lists without C recursion, read sequential channel
values/EOF, and check `Compat_32`. A checked-in wire fixture matches stock
OCaml byte-for-byte for integer boundaries, strings, float arrays, boxed
integers, sharing flags, and Bigarray payloads.
The initial public API regression verifies int/float64 access, dimensions,
bounds, and C/Fortran indexing. Follow-up regressions verify view lifetime,
structural comparison/hash equality, and complex record representation.
Bigarray channel I/O works through existing buffered channel helpers.
Random retains the upstream Bigarray state representation and the pure OCaml
LXM algorithm, so upstream testvectors can inspect the state directly.

# Numeric formatting

The float, int, int32, int64, and nativeint formatting primitives accept a
single conversion with optional flags, decimal width, and decimal precision.
The runtime checks the entire byte string before calling `snprintf`. Float
conversions are `fFeEgGaA`. Integer conversions are `diuxXo`, with an optional
`l`, `ll`, `L`, or `n` immediately before the conversion. The runtime replaces
that modifier with the length matching the C argument and passes the matching
signed or unsigned type.[^numeric-format]

Malformed formats and results that exceed the primitive's output buffer return
an empty OCaml string.[^runtime] The native and sanitizer suites exercise the
five primitive entry points with valid and rejected inputs.[^runtime-tests]

# Verified coverage (2026-11-17, macOS arm64 / OCaml 5.5.0)

The compatibility build compiles 72/72 interfaces and implementations.
The complete native-runner matrix scans 119 upstream files: 68/77 attempted
standalone tests pass, nine fail, and 42 are skipped (11 expect, 28 directive/
multifile/C-stub, three helpers). The prior integration report recorded 53/77;
that is a historical comparison, not a rerun baseline.

Passing requested suites include all seven standalone `lib-bigarray` tests,
channel bigarrays, Random testvectors, Dynarray (including marshalling),
Floatarray, all three Hashtbl tests, and Marshal intern_final/marshal_bigarray.
The upstream Marshal fuzzy test attempts closure serialization and fails on
functional-value rejection. The other failures are Format domains/mc_pr586_par/
mc_pr586_par2, Obj reachable_words/reachable_words_bug/with_tag, Sync prodcons,
and Sys opaque; the report records the exact exit/mismatch for each.
C-stub subarray and Marshal intext/intext_par/compressed tests are skipped.

All nine repository API fixtures pass on stock OCaml and ocamlcc. The
lexer fixture also forces buffer growth during capture; the parser checks
error recovery, semantic-action errors, empty productions, positions, and
nested parses. Foreign decoder fixtures cover big-model/64-bit block headers
and big-endian float payloads. `ninja -j1 test` (26 checks),
`ninja -j1 asan_test` (16 checks), and `dune runtest -j1` all pass.

Use `--tests 'lib-bigarray/*'` to select upstream tests and `--reuse-stdlib`
after a build. `build/stdlib_compat/report.md` and `.json` contain the matrix;
`build/stdlib_compat/logs/` contains full command output and JSON command receipts,
including timeouts. Tests run in copied working directories and leave vendor
sources/references unchanged. Compilation success is reported separately from
behavioral results.

The runner skips toplevel expect tests and tests with C stubs, multiple modules,
or unsupported ocamltest directives. Those require an adapter rather than being
counted as passing. GC, domains, and OS-specific behavior may differ under ARC.
`python3 tools/stdlib_regressions.py` runs repository API fixtures against the
compatibility archive; `--stock` checks the same fixtures with host OCaml.
Generated sources, commands, executables, and outputs stay under
`build/stdlib_regressions/`. Core regression commands are `ninja -j1 test`, `ninja -j1 asan_test`, and
`dune runtest -j1`.[^runtime]

[^runner]: Native compilation and test orchestration in the compatibility runner.
[^upstream]: Vendored source identity and test inventory.
[^runtime]: ARC/PAL implementation of upstream primitives.
[^numeric-format]: Numeric format validation and C argument selection.
[^runtime-tests]: Runtime primitive regression coverage.

# Runtime ownership checks

`tests/stdlib_runtime.c` exercises malformed streams containing a partially
constructed cycle, every truncation of a valid stream, payload-byte mutations,
successful cycle collection, and a Bigarray view after its owner is dropped.
Both native and ASan/UBSan runs pass with the original live-object count restored.
The test is integrated into `ninja -j1 test` and `ninja -j1 asan_test`.
`ninja -j1 stdlib_compat` builds the compatibility archive, records the upstream
matrix, and runs repository API regressions. The default compiler/driver still
uses the smaller original `stdlib/` archive unless given the compatibility
CMI/archive paths explicitly; 72/72 describes the compatibility build.

# Finalizer registration

`Gc.finalise` delivers ordinary callbacks during explicit major collections and at compiler polls once allocations consume the minor-heap budget. `Gc.finalise_last` receives unit after its target’s weak slots clear. Both use the same dispatcher. The [ARC finalizer design](/concepts/arc-finalizers.md) covers ordering, resurrection and exceptions.

# Before finalizer delivery (2026-11-18, macOS arm64 / OCaml 5.5.0)

The compatibility build compiles 72/72 interfaces and implementations. All 11 repository API fixtures pass on both stock OCaml and ocamlcc, including structural comparison and finalizer registration. Of 119 upstream files, 67 pass, ten fail and 42 are skipped.

Compared with the November 17 run, `lib-marshal/intern_final.ml` changed from passing to a runtime failure, and `lib-sys/opaque.ml` changed from an output mismatch to a runtime failure. The Marshal test reaches `Gc.finalise` through `Gc.create_alarm`, and the Sys test calls it directly. Both leave the ARC exception uncaught. The other 117 results match the prior report.

# After explicit major-collection finalizer delivery (2026-11-18, macOS arm64 / OCaml 5.5.0)

All 72 interfaces and implementations compile, and all 11 API fixtures pass on stock OCaml and ocamlcc. The upstream run passes 68 of 77 attempted tests, with nine failures and 42 skips. Marshal `intern_final` now passes. Sys `opaque` exits normally and prints the expected `lifetime: false false true`. Its allocation count prints `dead: 4`, while the reference expects `dead: 3`. The other 117 test statuses match the pre-delivery matrix.

# After allocation-driven finalizer delivery

On the same macOS arm64 toolchain, all 72 modules compile and all 119 upstream files retain their previous status. The 11 repository fixtures pass on both compilers. The finalizer fixture runs an alarm from a loop with no explicit collection, suppresses it after deletion, and catches a last-finalizer exception during tail recursion. It also passes linked against the ASan/UBSan runtime.
