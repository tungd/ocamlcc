---
type: Concept
title: Upstream standard library compatibility
description: Pinned OCaml sources, ARC overlays, and native upstream test execution.
tags: [stdlib, compatibility, testing, arc]
status: stable
generated:
  by: codex/1
  at: 2026-11-23
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
  - id: sys-runtime
    resource: stdlib/camlinternalSys.ml
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


The canonical build publishes each loose object's `.exports` file after
assembly so later units can import its digest-checked call and ownership facts.
This lets the bulk clients call `Stdlib.invalid_arg` directly on their error
paths and advertise their borrowed entries. The final archive publishes the
same facts in `build/stdlib/libocamlstdlib.a.opt`.
See [persisted export summaries](/concepts/build-pipeline.md#persisted-export-summaries).

The compiler verifies the scalar intervals in `Uchar.is_valid` and the
identity success path in `Uchar.of_int` before including their inline hints
in the summary. Consumers test those intervals inline. Invalid inputs go
through the original, link-stamped entry so validation and exception text
come from the same stdlib implementation.

# Build and test

`tools/import-ocaml-stdlib.sh` vendors OCaml 5.5.0 standard library sources,
interfaces, licenses, and 48 upstream `lib-*` test directories. The pin is
recorded in `vendor/ocaml-stdlib/UPSTREAM.txt`.[^upstream]

The default Ninja build selects the ARC overlay ahead of the pinned upstream
sources, compiles 78 modules with `occ` and QBE, and publishes the host archive
and the source bundle. `Stdlib_build` compiles that same bundle when the driver
needs target objects or a host archive is unavailable. `Stdlib.Fiber` and the
`Camlinternal` helpers are part of the overlay.

Run `ninja -j1 stdlib_compat` to link the upstream tests against the default
archive and the ARC runtime. `build/stdlib_compat/report.md` records module and
test outcomes.[^runner]

# POSIX Unix compatibility

`ocpkg add arc-unix` provides POSIX `Unix` descriptors, sockets, process
status and wall-clock operations used by terminal applications on macOS and Linux. The ML interface
keeps descriptors abstract in `Unix.File_descr`, exposes their borrowed
integer through `to_int` for `Fiber.fd_wait`, and checks byte ranges before
entering native code. `Unix.Error` maps POSIX errors to `Unix.Unix_error`.
Native stubs own system
calls and clean up partially configured pipes. Linux sets close-on-exec
atomically using `pipe2`. macOS sets it with `fcntl` after creating the pipe.
The separate Crunch port continues to provide its own `Unix` module.

`Unix.File_descr.adopt` checks an open native descriptor and transfers
ownership without making a copy. It pairs with `to_int`, which only borrows
the integer. `openfile` supports the file creation and access flags used by
the daemon. `dup ~cloexec:true` duplicates the handle with close-on-exec set
atomically. `set_close_on_exec` and `clear_close_on_exec` control inheritance
on existing handles.

`stat`, `lstat` and `fstat` expose file kind, permissions, owner, size,
and timestamps through `Unix.Stats.t` with stock field names. The port also
supports directory creation and removal, permission changes, renaming,
unlinking, access checks, current UID, and canonical path resolution.
Path errors keep the supplied path in `Unix.Unix_error`.

`lseek`, `ftruncate`, and `fsync` work on existing descriptors.
`Unix.Lock_command.t` exposes POSIX process-owned record locks relative to
the descriptor's current offset. A zero-length region extends through
future end-of-file. The daemon uses `F_TLOCK` so a competing owner reports
contention immediately. `F_LOCK` and `F_RLOCK` block the calling OS thread.

The socket interface supports Unix-domain and IPv4 stream and datagram
sockets. It exposes `Unix.Sockaddr.t` and keeps IPv4 addresses abstract in
`Unix.Inet_addr`. It includes listener and client operations, socket pairs,
local and peer addresses, shutdown, address reuse, buffer sizes and timeouts.
Linux sets close-on-exec at creation or accept. macOS applies it before
returning the descriptor and closes the descriptor if setup fails. The
listener leaves accepted sockets in the mode supplied by the kernel.
Set nonblocking mode explicitly before using `Fiber.fd_wait` with a client.
Linux supports Unix abstract names beginning with a NUL byte.

The process interface exposes `getpid`, `kill` and `waitpid` with
`Unix.Wait_flag.t` and `Unix.Process_status.t`. The native adapter translates
`Sys.sig*` constants in both directions and preserves the POSIX nonblocking
result as `(0, WEXITED 0)`. A fiber can reap all ready children with
`WNOHANG` without blocking the scheduler.
`Unix.signal_number` converts a returned `Sys.sig*` value to the native
number, for example when encoding a shell exit status.

`environment` copies the current environment. `create_process` inherits it
and `create_process_env` supplies a child-only environment. Both use
`posix_spawnp` and map the supplied descriptors to the child's standard
streams. The daemon bootstrap can use `fork` and `setsid` from a single
OS thread, and `execv` replaces the current image during reload.
`Unix.Error.of_number` converts errno values from native bindings.

`Unix.Signal_events.with_events` temporarily owns delivery of SIGINT,
SIGTERM, and SIGCHLD for the process. Use it from the single scheduler
thread. Await its borrowed descriptor with `Fiber.fd_wait` and drain
`next` until it returns `None`. Reap with `waitpid [WNOHANG]` until no
status is ready because one `Child_exit` event can cover multiple children.
macOS uses kqueue. Linux uses an eventfd watched by epoll and keeps the
caller's signal mask during the callback, including when launching children.
The scope restores previous signal actions and closes the descriptor on
exit, including on exceptions. Other platforms report `ENOSYS`.

`ninja -j1 ocpkg_arc_unix` exercises a close-on-exec pipe, nonblocking reads,
offset byte transfers, end of file, file creation and append, native
descriptor adoption, duplication, and inheritance flags. The package
fixture also checks Unix-domain and loopback connections, listener and
client readiness, half-close, datagram pairs, running, stopped, signaled,
and exited children, and signal readiness through the Fiber scheduler on
macOS and Linux. A subprocess launched within the scope can still exit
from SIGTERM.
File checks cover symlink-aware metadata, seek and truncation, and record
lock contention against a separate process.
Subprocess checks cover PATH lookup, standard stream redirection, inherited
and explicit environments, and fork, session creation, exec, and reap.

`stdlib/camlinternalIntFmt.ml` (`--nopervasives`, compiled right after `CamlinternalFormatBasics`) implements integer parsing and formatting (`format_int`, `format_int32`, `format_int64`, `format_nativeint`, `parse_int`, `parse_int32`, `parse_int64`, `parse_nativeint`) in pure OCaml, replacing the C `caml_*format*` / `caml_*_of_string` implementations previously in `runtime/builtins.c`/`runtime/arc.c`. It handles 63-bit signed decimal bounds (`[-(1<<62), (1<<62)-1]`), signed/unsigned base-prefixed literals (`"-0x30"`, `"0x7fffffffffffffff"` -> `-1`, magnitude `<= INT64_MAX`, sign-extending bit 62) matching `Misc.Int_literal_converter.int`, 32/64-bit parsing, and `%[flags][width][.prec][l|ll|L|n][d|i|u|x|X|o]` formatting.[^int-fmt]

`stdlib/camlinternalBulkOps.ml` compiles with `--nopervasives` after
`CamlinternalIntFmt`. It checks byte and string slices in OCaml, then calls
the runtime's overlap-safe move or byte fill. An unsafe string view can alias
its byte destination. Array fill, blit, and sub also validate slices in
OCaml before entering a native kernel. The kernels copy flat floats as raw
payloads. For tagged word arrays they check the affected source and destination
slices before a bulk move or fill. Pointer-capable slices retain incoming
owners before releasing replaced ones, in overlap-safe order. The tests
cover zero-scan-count
arrays with pointers, empty slices, and the preservation of floating-point
bits. Scalar comparisons, hashing, append, and concat use the OCaml
module.[^bulk-ops]

The compatibility builder makes the stamped CamlinternalBulkOps entries
available before compiling Array, Bytes, and String. Explicitly applied
shims use direct calls and can select borrowed entries under ARC liveness.
The final archive includes the same provider object. The compatibility
implementations of `Array.fill`, `Array.sub`, `Bytes.fill`, and `Bytes.sub`
apply the upstream bounds checks and then enter the native kernels through
CamlinternalBulkOps' unchecked primitives. `Bytes.sub_string` uses the same
checked `Bytes.sub` path. The separately exposed unsafe Bytes entry points
continue to delegate to the compatibility helpers with slice checks.
The Uchar interface exposes `to_int` as the tagged identity already used by
its implementation, so Bytes UTF-8 writers need no closure call to convert it.

In five paired tterm trials, plain and Unicode replay went from 31.73 to
31.09 ms and from 150.83 to 147.85 ms on default ARC. On single-thread ARC
they went from 29.33 to 28.94 ms and from 130.33 to 126.00 ms.

The Effect overlay uses [stackful fibers](/concepts/wren-fibers.md#ocaml-5-effect-handlers)
for `Effect.Deep`, `Effect.Shallow`, and the OCaml effect-pattern syntax. The standard library
regression runs the same fixture on ocamlcc and stock OCaml and covers
forwarding, one-shot continuations, exception injection, abandonment, and
shallow handler replacement.
Continuation callstack introspection still returns an empty backtrace.

The Lexing overlay implements both DFA engines in OCaml, including signed
16-bit transitions, unsigned memory-code offsets, captures, backtracking,
refill continuations, EOF, and positions. Direct OCaml declarations of
`caml_lex_engine` and `caml_new_lex_engine` dispatch to the same raw engine.
These calls advance byte offsets and capture state. The public
`Lexing.engine` and `Lexing.new_engine` wrappers also update the position
records. The compiler initializes the Lexing module for callers that
only reference the primitive. The generated fixtures in
`tests/stdlib/lexing` cover both entry points, including refill, EOF,
exceptions, and unchanged position records on direct calls.
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
The native stdlib build compiles all 78 modules, including Fiber. `stdlib/camlinternalSys.ml` (`--nopervasives`, compiled right after `CamlinternalMarshal`) implements the `Callback` named-value table (calling the 1-line `ocamlcc_set_at_exit_fn` hook for `"Pervasives.do_at_exit"`), backtrace stubs (`record_backtrace`, `backtrace_status`, `get_exception_raw_backtrace`, `get_current_callstack`, slot/debug helpers; while `lib/anf.ml` lowers `caml_restore_raw_backtrace` to `Int 0`), and `Sys` config/warnings/temp-dir/executable-name helpers over `ocamlcc_sys_is_win32`, `caml_sys_argv`, and `caml_sys_getenv_opt` (`runtime_variant`/`parameters`/`signal` and 22 C stubs removed from `runtime/arc.c` & `lib/ccalls.ml`). `stdlib/camlinternalChannel.ml` (`--nopervasives`, compiled right after `CamlinternalBulkOps` and before `CamlinternalMarshal`) implements buffered `in_channel` and `out_channel` (4096-byte `bytes` buffers, weak array registry for `out_channels_list ()` / `flush_all ()`, unbuffered mode, 64-bit `LargeFile` seeks/lengths, `input_scan_line`, binary 32-bit ints, and Bigarray 1D `char` slice transfers) over thin POSIX fd shims (`ocamlcc_raw_fd_{read,write,lseek,size,close,isatty}`, `ocamlcc_stdio_flush`, and `ocamlcc_ba_{to_bytes,of_bytes_slice}`), removing `OcamlccChannel`, `ARC_TAG_CHANNEL`, and all `caml_ml_*` channel functions from `runtime/arc.c` and `runtime/arc.h`. `stdlib/camlinternalMarshal.ml` (`--nopervasives`, compiled right after `CamlinternalChannel`) implements Marshal in pure OCaml over `CamlinternalChannel` and tiny object/bigarray metadata helpers (`ocamlcc_ptr_id`,
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
