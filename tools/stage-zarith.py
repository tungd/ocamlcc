#!/usr/bin/env python3
"""Stage Zarith 1.14 and print its ocpkg recipe."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess


def wrappers(source: str) -> bytes:
    bindings = {}
    declarations = re.finditer(r"^CAMLprim value (ml_z_\w+)\(([^\n]*)\)", source, re.M)
    for match in declarations:
        name, arguments = match.groups()
        if name.startswith("ml_z_mlgmpidl_"):
            continue
        types = tuple(arg.split()[0] for arg in arguments.split(",")) if arguments else ()
        if not all(ty in {"value", "int"} for ty in types) or name in bindings:
            raise ValueError(f"Unsupported Zarith declaration for {name}")
        bindings[name] = types
    if len(bindings) != 83:
        raise ValueError(f"Expected 83 Zarith native declarations, found {len(bindings)}")

    lines = [f"#define {name} upstream_{name}" for name in bindings]
    lines.append('#include "caml_z_source.h"')
    for name, types in bindings.items():
        inner_args = ", ".join(f"({ty})args[{i}]" for i, ty in enumerate(types))
        params = types or ("value",)
        signature = ", ".join(f"{ty} a{i}" for i, ty in enumerate(params))
        values = ", ".join(f"a{i}" for i in range(len(params)))
        lines.extend([f"#undef {name}", f"static value call_{name}(const value *args) {{"])
        if not types:
            lines.append("    (void)args;")
        lines.extend([
            f"    return upstream_{name}({inner_args});",
            "}",
            f"value {name}({signature}) {{",
            f"    const value args[] = {{{values}}};",
            f"    return ocamlcc_caml_call(call_{name}, args);",
            "}",
        ])
    return ("\n".join(lines) + "\n").encode()


def stage(source: Path, port: Path) -> None:
    version = re.search(r'^version\s*=\s*"([^"]+)"', (source / "META").read_text(), re.M)
    if version is None or version[1] != "1.14":
        raise ValueError("Expected Zarith 1.14 sources")

    names = ("caml_z.c", "zarith.h", "z.ml", "z.mli")
    files = {name: (source / name).read_bytes() for name in names}
    files["zarith_version.ml"] = f'let version = "{version[1]}"\n'.encode()
    files["zarith_arc.c"] = wrappers(files["caml_z.c"].decode())
    entries = [
        [name, False, hashlib.sha256(data).hexdigest()]
        for name, data in sorted(files.items())
    ]
    tree = hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest()
    flags = [("cflag", "-DHAS_GMP"), ("cflag", "-DOCAMLCC_CAML_ALLOC")]
    for kind, query in [("cflag", "--cflags"), ("ldflag", "--libs")]:
        output = subprocess.check_output(["pkg-config", query, "gmp"], text=True)
        flags.extend((kind, flag) for flag in shlex.split(output))

    port.mkdir(parents=True)
    for name, data in files.items():
        (port / name).write_bytes(data)

    print(f"pkg zarith 1.14\n  local {json.dumps(port.as_posix())}\n  tree {tree}\n  export Z")
    for name in sorted(files):
        target = "caml_z_source.h" if name == "caml_z.c" else name
        print(f"  file {target} <= {name}")
    for kind, flag in flags:
        print(f"  {kind} {json.dumps(flag)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="unpacked Zarith 1.14 source directory")
    parser.add_argument("port", type=Path, help="new directory relative to the snapshot directory")
    args = parser.parse_args()
    if (args.port.is_absolute() or ".." in args.port.parts
            or not args.port.resolve().is_relative_to(Path.cwd())):
        parser.error("port must be relative to the snapshot directory")
    try:
        stage(args.source, args.port)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"stage-zarith: {error}\n")


if __name__ == "__main__":
    main()
