# Stdlib Overlay

Files placed in `stdlib/overlay/` override matching upstream OCaml stdlib
files from `vendor/ocaml-stdlib/src/` when running `tools/stdlib_compat.py`.

Examples:
- `stdlib/overlay/gc.ml` overrides `vendor/ocaml-stdlib/src/gc.ml`
- `stdlib/overlay/weak.mli` / `stdlib/overlay/weak.ml` override `Weak`
- `stdlib/overlay/fiber.mli` / `stdlib/overlay/fiber.ml` provide `ocamlcc`-specific additions

All unoverlaid modules fall through directly to `vendor/ocaml-stdlib/src/`.
