# OCaml-QBE (ARC & Fiber Runtime) — Project Design Document

## 1. Executive Summary

OCaml-QBE is an alternative ahead-of-time (AOT) compiler backend and
freestanding runtime for OCaml built on top of QBE (v1.3+). By reusing OCaml's
official frontend (compiler-libs) and replacing the tracing garbage collector
and multicore domain runtime with Perceus-style Automatic Reference Counting
(ARC) and Wren-style stackful coroutines, the project enables deterministic
memory management, single-binary Go-style cross-compilation, and first-class
native library packaging for mobile (iOS and Android) and desktop platforms.

## 2. Core Goals & Non-Goals

### Goals

1. **Zero Tracing GC**: Deterministic memory reclamation via compile-time
   Perceus reference counting with in-place constructor reuse and zero
   stop-the-world pauses.
2. **Single-Binary Cross-Compilation**: Embed QBE's multi-target code
   generators (arm64_apple, arm64, amd64_sysv, rv64, plus QBE 1.3's PIC and
   Windows ABI support) inside one compiler executable — eliminating
   per-target opam switches.
3. **Mobile-First Shared Libraries (KMP-Style)**: Emit clean static/dynamic
   libraries (.xcframework on iOS/macOS, .so/.a on Android) paired with
   auto-generated C headers (.h) for direct Swift and Kotlin/JNI interop
   without tagged-pointer boxing overhead.
4. **Lightweight Cooperative Concurrency**: Implement Wren-style stackful
   fibers with deterministic ARC cleanup when suspended fibers are abandoned,
   avoiding heavy external event loops like libuv.
5. **Minimal / Freestanding libc Footprint**: Decouple core runtime logic
   behind a 6-primitive Platform Abstraction Layer (pal.h), enabling
   zero-dependency static binaries on Linux via raw syscalls while
   integrating cleanly with libSystem (iOS) and Bionic libc (Android).

### Non-Goals

- 32-bit microcontrollers (MCUs): QBE targets 64-bit architectures
  exclusively; bare-metal 32-bit targets (Cortex-M, ESP32) are out of scope.
- Binary compatibility with legacy opam C-stubs: breaking away from
  caml/mlvalues.h and GC root macros (CAMLparam/CAMLlocal) is intentional to
  enable direct C ABI interop and unboxed value layouts.
- OCaml 5 multicore domains / multi-shot effects: concurrency is modeled via
  a single-scheduler cooperative fiber and explicit message/channel passing
  rather than shared-heap parallel domains.

## 3. System Architecture

```
  OCaml Source (.ml / .mli)
            │
            ▼
┌───────────────────────────────────────┐
│  1. Official OCaml Frontend           │
│     (compiler-libs: Parse, Typecheck, │
│      GADT/Module Desugar → Lambda IR) │
└───────────────────────────────────────┘
            │
            ▼
┌───────────────────────────────────────┐
│  2. Middle-End (Pure OCaml)           │
│     • ANF Conversion & Closure Conv.  │
│     • Perceus ARC (dup/drop/reuse)    │
│     • Shadow-Stack Fiber Lowering     │
│     • Error-Return Exception Lowering │
└───────────────────────────────────────┘
            │
            ▼
┌───────────────────────────────────────┐
│  3. Code Generation (QBE 1.3)         │
│     • SSA & Phi-Node Emission (.ssa)  │
│     • Self-Tail-Call Loop Lowering    │
│     • PIC / Mach-O / ELF Assembly (.s)│
└───────────────────────────────────────┘
            │
            ▼
┌───────────────────────────────────────┐
│  4. Platform Linker & FFI Packager    │
│     • Clang / NDK / Xcode Toolchain   │
│     • Auto-generated C Header (.h)    │
│     • Freestanding ARC + Fiber C Lib  │
└───────────────────────────────────────┘
```

## 4. Technical Design Specifications

### 4.1 Frontend & IR Extraction

- Link directly against compiler-libs.common and compiler-libs.bytecomp
  (Typemod, Translmod) to consume typed, pattern-match-compiled
  Lambda.lambda trees.
- Retain full support for OCaml's type system, modules, functors,
  polymorphic variants, and GADTs at zero frontend maintenance cost.

### 4.2 Value Representation & Perceus ARC

- **Immediate vs. Heap Values**: tag the least-significant bit
  (`val & 1 == 1`) for unboxed 63-bit integers, booleans, and constant
  constructors; even pointers (`val & 1 == 0`) point to heap-allocated ARC
  objects.
- **Object Header (16 bytes)**:

```c
typedef struct {
    uint32_t refcount;   // Atomic or non-atomic RC (0xFFFFFFFF = immortal/static)
    uint16_t tag;        // Constructor tag or object kind (Closure, String, Array, Fiber)
    uint16_t scan_fields;// Number of pointer fields to recursively dec_ref on drop
    uint32_t byte_size;  // Total allocation size for slab allocator & Perceus reuse
    uint32_t reserved;
} ArcHeader;
```

- **Perceus Static Reuse Analysis**: during ANF lowering, static liveness
  analysis inserts `arc_dup` on shared variables and `arc_drop` immediately
  after last use. When a constructor is dropped right before allocating a new
  constructor of matching byte_size, the compiler emits a reuse token,
  mutating the dead block in-place instead of calling the allocator.
- **Cycle Safety**: mutable structures (ref, mutable record fields, Array,
  Hashtbl) are statically flagged; cycles are broken explicitly via Weak.t
  references or an optional lightweight trial-deletion cycle collector
  invoked on explicit threshold triggers.

### 4.3 Zero-Leak Exception Handling

- Rather than setjmp/longjmp stack unwinding (which bypasses arc_drop calls
  on intermediate frames), OCaml `raise` and `try ... with` compile into an
  implicit error return channel (a thread/fiber-local error slot checked at
  call sites).
- When an exception is raised, functions execute their normal epilogue
  arc_drop sequence while propagating the error upward — guaranteeing zero
  reference leaks on exceptional paths.

### 4.4 Wren-Style Stackful Coroutines

- Each Fiber is a standard ARC-managed heap object owning a contiguous shadow
  value stack (storing live heap pointers across suspension points) and a
  caller link for asymmetric yield and symmetric transfer.
- **Suspension & Cleanup**: only functions statically reachable from
  Fiber.yield push/pop live ARC references on the fiber's shadow stack; pure
  functions run at full native register speed. If a suspended fiber's
  refcount reaches zero, its destructor walks active shadow-stack slots from
  sp down to base and invokes arc_drop on each live reference before freeing
  the stack buffer.
- **Pluggable Event Poller**: non-blocking I/O suspends the active fiber and
  registers file descriptors/timers with native OS primitives (kqueue/GCD on
  iOS/macOS, epoll/ALooper on Android/Linux).

### 4.5 Freestanding Platform Abstraction Layer (pal.h)

The entire C runtime (~1,200 LOC) is freestanding and depends on only 6
platform hooks:

1. `pal_page_alloc` / `pal_page_free` (mmap/munmap syscalls on Linux;
   libSystem / Bionic on mobile)
2. `pal_abort` (exit_group syscall / `__builtin_trap()`)
3. `pal_monotonic_ns` (clock_gettime)
4. `pal_poll_wait` (epoll / kqueue / libdispatch)
5. `pal_memcpy` / `pal_memset` (freestanding fallback or platform libc)
6. Minimal libm subset for floating-point intrinsics

## 5. Cross-Compilation & Mobile FFI Workflow

A single CLI command drives target codegen and packaging:

```sh
# Build iOS Universal XCFramework (arm64 device + arm64/x86_64 simulator)
ocaml-qbe build --target ios-xcframework src/core.mli src/core.ml -o build/Core.xcframework

# Build Android JNI Shared Libraries (arm64-v8a + x86_64)
ocaml-qbe build --target android-aar src/core.mli src/core.ml -o build/core.aar

# Build Static Zero-Dependency Linux Binary
ocaml-qbe build --target linux-amd64-static src/main.ml -o build/app
```

- **Header Generation**: top-level values exported in .mli files
  automatically emit a clean C99 header (core.h) plus arc_retain / arc_release
  entry points, enabling direct consumption via Xcode Clang module maps
  (Swift) and JNI / KMP cinterop (Kotlin).

## 6. Development Roadmap & Estimates (~5–6 Months Solo)

| Phase | Duration | Key Deliverables |
|-------|----------|------------------|
| 1. Lambda → QBE MVP | 4–6 weeks | Extract Lambda IR via compiler-libs; ANF & closure conversion; QBE SSA emission with self-tail-call loops; native desktop binaries (leaking memory). |
| 2. Perceus ARC & Allocator | 5–7 weeks | Freestanding C slab allocator; Perceus dup/drop/reuse pass; zero-leak error-return exceptions; Weak.t cycle support. |
| 3. Wren Fibers & I/O Poller | 3–4 weeks | Fiber struct, shadow-stack lowering for yielding functions, deterministic fiber-drop cleanup, and kqueue/epoll async driver. |
| 4. Mobile & Cross-Build CLI | 3–4 weeks | Embedded QBE 1.3 multi-target driver (arm64_apple, arm64, amd64_sysv, rv64); .mli → .h generator; .xcframework and Android .so packager. |
| 5. Core Stdlib Port | 3–4 weeks | ARC-native implementations of Option, Result, List, Array, Bytes, String, Buffer, Hashtbl, and Printf. |

## 7. Key Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Unbounded mutual tail recursion | QBE does not enforce musttail across arbitrary mutual calls, risking stack overflow. | Compile self-recursion into explicit QBE loops; use a lightweight trampoline convention for mutual tail calls in tail position. |
| Hidden reference cycles | Mutable records/closures forming cycles will leak under pure ARC. | Provide Weak.t in core stdlib, emit compiler warnings on cyclic `let rec` value definitions, and include an opt-in trial-deletion cycle collector. |
| Shadow-stack overhead on deep call chains | Pushing every live pointer on yielding call paths adds memory traffic. | Run static yield-effect inference so only functions that can transitively suspend emit shadow-stack spills; keep leaf/pure functions purely in registers. |
