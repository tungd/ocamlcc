#!/usr/bin/env python3
"""Stage a package source tree and print its ocpkg snapshot recipe.

Computes the compatible SHA-256 tree codec digest over a source root and
emits a snapshot stanza skeleton (mirroring tools/stage-zarith.py). The
file mappings default to basename <= relative path; unit names follow the
staged basename.
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path


def tree_hash(root: Path) -> str:
    rows = []

    def walk(prefix: str, path: Path) -> None:
        for name in sorted(path.iterdir(), key=lambda p: p.name):
            rel = prefix + name.name
            stat = name.lstat()
            if name.is_dir() and not name.is_symlink():
                walk(rel + "/", name)
            elif name.is_file() and not name.is_symlink():
                digest = hashlib.sha256(name.read_bytes()).hexdigest()
                rows.append([rel, (stat.st_mode & 0o111) != 0, digest])
            else:
                raise SystemExit(f"stage-package: unsupported entry: {name}")

    walk("", root)
    return hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--url")
    parser.add_argument("--archive-sha256")
    parser.add_argument("--archive-root", help="top-level directory inside the archive")
    parser.add_argument("--local", help="port path relative to the snapshot")
    parser.add_argument("--module", action="append", default=[],
                        help="compilation input, [staged<=]source relative to root")
    parser.add_argument("--export", action="append", default=[])
    parser.add_argument("--dep", action="append", default=[])
    parser.add_argument("--wrapped", help="wrapping module name")
    parser.add_argument("--cflag", action="append", default=[])
    parser.add_argument("--ldflag", action="append", default=[])
    parser.add_argument("--license")
    args = parser.parse_args()

    root = args.root
    if not root.is_dir():
        raise SystemExit(f"stage-package: not a directory: {root}")

    lines = [f"pkg {args.name} {args.version}"]
    if args.local:
        lines.append(f"  local {args.local}")
    else:
        if not args.url or not args.archive_sha256:
            raise SystemExit("stage-package: --url and --archive-sha256 (or --local) required")
        lines.append(f"  url {args.url}")
        lines.append(f"  sha256 {args.archive_sha256}")
        if args.archive_root:
            lines.append(f"  root {args.archive_root}")
    lines.append(f"  tree {tree_hash(root)}")
    for dep in args.dep:
        lines.append(f"  dep {dep}")
    lines.append(f"  wrapped {args.wrapped}" if args.wrapped else "  wrapped false")
    if args.license:
        lines.append(f"  license \"{args.license}\"")
    for name in args.export:
        lines.append(f"  export {name}")
    for spec in args.module:
        staged, sep, source = spec.partition("<=")
        if not sep:
            source = staged
            staged = Path(source).name
        lines.append(f"  file {staged} <= {source}")
    for flag in args.cflag:
        lines.append(f"  cflag {flag}")
    for flag in args.ldflag:
        lines.append(f"  ldflag {flag}")
    sys.stdout.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
