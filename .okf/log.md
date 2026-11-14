# Change Log

- 2026-11-13 (autoagent/1): Match lowering — `Lswitch` desugared to
  comparison chains; `Lstaticraise`/`Lstaticcatch` lowered with per-binder
  phis and two-way joins (integers and constant constructors). Mutual tail
  recursion: tail-call graph + SCC analysis groups mutually tail-recursive
  functions into single trampoline functions with a selector argument and
  uniform phi slots; `even`/`odd` ping-pong 100k in constant stack. Two new
  checked tests (`match`, `mutual`).
- 2026-11-13 (autoagent/1): Phase 1 increment — top-level/recursive function
  definitions with direct calls, self-tail-call loop lowering via QBE phi
  nodes (constant stack space), booleans as values, string literals via QBE
  data emission with `print_string`/`print_endline` runtime builtins, and
  `ninja test` (5 checked examples). Re-vendored QBE from the official 1.2
  release tarball (the sr.ht dev snapshot used phi-less IL and was replaced);
  updated build-pipeline and value-representation concepts with the QBE
  gotchas learned.
- 2026-11-13 (autoagent/1): Initial bundle produced during project
  initialization — captured the design document (`docs/design.md`), the
  scaffolded pipeline (compiler, build, runtime), and the planned ARC/fiber
  designs as draft concepts.
