#!/usr/bin/env python3
"""
Stdlib compatibility builder & upstream testsuite runner for ocamlcc.

Resolves modules using a two-layer overlay:
  1. stdlib/overlay/          (ARC/PAL module overrides & extensions)
  2. vendor/ocaml-stdlib/src/ (pinned upstream OCaml stdlib sources)

Compiles all StdlibModules with ocamlcc + qbe + cc + ar, records per-module
pass/fail diagnostics across every stage, and runs standalone upstream
vendor/ocaml-stdlib/testsuite/tests/lib-* tests against the compiled stdlib.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import time
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


def detect_host_qbe_target() -> str:
    sysname = platform.system().lower()
    mach = platform.machine().lower()
    if sysname == "darwin":
        if mach in ("arm64", "aarch64"):
            return "arm64_apple"
        return "amd64_sysv"
    if mach in ("arm64", "aarch64"):
        return "arm64"
    if mach in ("riscv64",):
        return "rv64"
    return "amd64_sysv"


def parse_stdlib_modules(stdlib_modules_path: Path) -> list[str]:
    text = stdlib_modules_path.read_text(encoding="utf-8")
    m = re.search(
        r"STDLIB_MODULE_BASENAMES\s*=\s*(.*?)(?:\n\S|\Z)", text, re.DOTALL
    )
    if not m:
        raise RuntimeError(f"Could not parse STDLIB_MODULE_BASENAMES from {stdlib_modules_path}")
    block = m.group(1)
    tokens: list[str] = []
    for raw_line in block.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if line.endswith("\\"):
            line = line[:-1].strip()
        if line:
            tokens.extend(line.split())
    return tokens


def unit_prefix(base: str) -> str:
    if base == "stdlib" or base == "std_exit" or base.startswith("camlinternal"):
        return base
    return "stdlib__" + base[0].upper() + base[1:]


def extract_first_error(stderr_text: str | None, stdout_text: str | None) -> str:
    combined = ((stderr_text or "") + "\n" + (stdout_text or "")).strip()
    lines = [ln.strip() for ln in combined.splitlines() if ln.strip()]
    if not lines:
        return "(no error output)"
    for ln in lines:
        if "Error:" in ln or "unsupported:" in ln:
            return ln[:220]
    for ln in lines:
        if "ocamlcc: error:" in ln or "qbe:" in ln or "Undefined" in ln or "undefined" in ln:
            return ln[:220]
    return lines[0][:220]


COMMAND_LOG_DIR: Path | None = None
COMMAND_NUMBER = 0

def run_cmd(
    cmd: list[str],
    cwd: Path | None = None,
    timeout: int = 30,
    merge_stderr: bool = False,
) -> subprocess.CompletedProcess[str]:
    global COMMAND_NUMBER
    COMMAND_NUMBER += 1
    started = time.monotonic()
    try:
        result = subprocess.run(
            cmd, cwd=str(cwd) if cwd else None, text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT if merge_stderr else subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        def decoded(value):
            return value.decode(errors="replace") if isinstance(value, bytes) else value or ""
        result = subprocess.CompletedProcess(cmd, 124, decoded(error.stdout),
                                            decoded(error.stderr) + f"\ntimeout ({timeout}s)")
    if COMMAND_LOG_DIR is not None:
        COMMAND_LOG_DIR.mkdir(parents=True, exist_ok=True)
        path = COMMAND_LOG_DIR / f"{COMMAND_NUMBER:05d}.log"
        path.write_text("$ " + shlex.join(cmd) + "\n" + (result.stdout or "") +
                        (result.stderr or ""), encoding="utf-8")
        with (COMMAND_LOG_DIR / "commands.jsonl").open("a") as receipt:
            receipt.write(json.dumps(dict(command=cmd, cwd=str(cwd), exit_code=result.returncode,
                                          seconds=time.monotonic()-started, log=str(path))) + "\n")
    return result


@dataclass
class ModuleResult:
    base: str
    prefix: str
    source_layer: str
    mli_ok: bool
    ml_ok: bool
    qbe_ok: bool
    as_ok: bool
    stage_failed: str
    error: str


_COMPAT_PATCHES: dict[str, list[tuple[str, str]]] = {
    "stdlib.mli": [
        (
            'external int_of_string : string -> int = "caml_int_of_string"',
            "val int_of_string : string -> int",
        ),
    ],
    "int32.mli": [
        (
            'external of_string : string -> int32 = "caml_int32_of_string"',
            "val of_string : string -> int32",
        ),
    ],
    "int64.mli": [
        (
            'external of_string : string -> int64 = "caml_int64_of_string"',
            "val of_string : string -> int64",
        ),
    ],
    "nativeint.mli": [
        (
            'external of_string : string -> nativeint = "caml_nativeint_of_string"',
            "val of_string : string -> nativeint",
        ),
    ],
    "stdlib.ml": [
        (
            'external format_int : string -> int -> string = "caml_format_int"',
            "let format_int = CamlinternalIntFmt.format_int",
        ),
        (
            'external int_of_string : string -> int = "caml_int_of_string"',
            "let int_of_string = CamlinternalIntFmt.parse_int",
        ),
        (
            'external string_blit : string -> int -> bytes -> int -> int -> unit\n'
            '                     = "caml_blit_string" [@@noalloc]\n'
            'external bytes_blit : bytes -> int -> bytes -> int -> int -> unit\n'
            '                        = "caml_blit_bytes" [@@noalloc]',
            "let string_blit = CamlinternalBulkOps.blit_string\n"
            "let bytes_blit = CamlinternalBulkOps.blit_bytes",
        ),
        (
            'external marshal_to_channel : out_channel -> \'a -> unit list -> unit\n'
            '     = "caml_output_value"',
            "let marshal_to_channel = CamlinternalMarshal.to_channel",
        ),
        (
            'external input_value : in_channel -> \'a = "caml_input_value"',
            "let input_value = CamlinternalMarshal.from_channel",
        ),
    ],
    "marshal.mli": [
        (
            'external to_bytes :\n'
            '  \'a -> extern_flags list -> bytes = "caml_output_value_to_bytes"',
            "val to_bytes :\n"
            "  'a -> extern_flags list -> bytes",
        ),
        (
            'external to_string :\n'
            '  \'a -> extern_flags list -> string = "caml_output_value_to_string"',
            "val to_string :\n"
            "  'a -> extern_flags list -> string",
        ),
    ],
    "marshal.ml": [
        (
            'external to_channel: out_channel -> \'a -> extern_flags list -> unit\n'
            '    = "caml_output_value"\n'
            'external to_bytes: \'a -> extern_flags list -> bytes\n'
            '    = "caml_output_value_to_bytes"\n'
            'external to_string: \'a -> extern_flags list -> string\n'
            '    = "caml_output_value_to_string"\n'
            'external to_buffer_unsafe:\n'
            '      bytes -> int -> int -> \'a -> extern_flags list -> int\n'
            '    = "caml_output_value_to_buffer"',
            "let to_channel = CamlinternalMarshal.to_channel\n"
            "let to_bytes = CamlinternalMarshal.to_bytes\n"
            "let to_string = CamlinternalMarshal.to_string\n"
            "let to_buffer_unsafe = CamlinternalMarshal.to_buffer_unsafe",
        ),
        (
            'external from_channel: in_channel -> \'a = "caml_input_value"\n'
            'external from_bytes_unsafe: bytes -> int -> \'a = "caml_input_value_from_bytes"\n'
            'external data_size_unsafe: bytes -> int -> int = "caml_marshal_data_size"',
            "let from_channel = CamlinternalMarshal.from_channel\n"
            "let from_bytes_unsafe = CamlinternalMarshal.from_bytes_unsafe\n"
            "let data_size_unsafe = CamlinternalMarshal.data_size_unsafe",
        ),
    ],
    "bytes.mli": [
        (
            'external unsafe_blit :\n'
            '  bytes -> int -> bytes -> int -> int ->\n'
            '    unit = "caml_blit_bytes" [@@noalloc]\n'
            'external unsafe_blit_string :\n'
            '  string -> int -> bytes -> int -> int -> unit\n'
            '  = "caml_blit_string" [@@noalloc]\n'
            'external unsafe_fill :\n'
            '  bytes -> int -> int -> char -> unit = "caml_fill_bytes" [@@noalloc]',
            "val unsafe_blit : bytes -> int -> bytes -> int -> int -> unit\n"
            "val unsafe_blit_string : string -> int -> bytes -> int -> int -> unit\n"
            "val unsafe_fill : bytes -> int -> int -> char -> unit",
        ),
    ],
    "bytesLabels.mli": [
        (
            'external unsafe_blit :\n'
            '  src:bytes -> src_pos:int -> dst:bytes -> dst_pos:int -> len:int ->\n'
            '    unit = "caml_blit_bytes" [@@noalloc]\n'
            'external unsafe_blit_string :\n'
            '  src:string -> src_pos:int -> dst:bytes -> dst_pos:int -> len:int -> unit\n'
            '  = "caml_blit_string" [@@noalloc]\n'
            'external unsafe_fill :\n'
            '  bytes -> pos:int -> len:int -> char -> unit = "caml_fill_bytes" [@@noalloc]',
            "val unsafe_blit : src:bytes -> src_pos:int -> dst:bytes -> dst_pos:int -> len:int -> unit\n"
            "val unsafe_blit_string : src:string -> src_pos:int -> dst:bytes -> dst_pos:int -> len:int -> unit\n"
            "val unsafe_fill : bytes -> pos:int -> len:int -> char -> unit",
        ),
    ],
    "string.mli": [
        (
            'external unsafe_blit :\n'
            '  string -> int -> bytes -> int -> int ->\n'
            '    unit = "caml_blit_string" [@@noalloc]',
            "val unsafe_blit : string -> int -> bytes -> int -> int -> unit",
        ),
    ],
    "stringLabels.mli": [
        (
            'external unsafe_blit :\n'
            '  src:string -> src_pos:int -> dst:bytes -> dst_pos:int -> len:int ->\n'
            '    unit = "caml_blit_string" [@@noalloc]',
            "val unsafe_blit : src:string -> src_pos:int -> dst:bytes -> dst_pos:int -> len:int -> unit",
        ),
    ],
    "array.mli": [
        (
            'external create_float: int -> float array = "caml_array_create_float"',
            "val create_float: int -> float array",
        ),
        (
            '  external create : int -> floatarray = "caml_floatarray_create"',
            "  val create : int -> floatarray",
        ),
    ],
    "arrayLabels.mli": [
        (
            'external create_float: int -> float array = "caml_array_create_float"',
            "val create_float: int -> float array",
        ),
        (
            '  external create : int -> floatarray = "caml_floatarray_create"',
            "  val create : int -> floatarray",
        ),
    ],
    "bytes.ml": [
        (
            'external unsafe_fill : bytes -> int -> int -> char -> unit\n'
            '                     = "caml_fill_bytes" [@@noalloc]',
            "let unsafe_fill = CamlinternalBulkOps.fill_bytes",
        ),
        (
            'external unsafe_blit : bytes -> int -> bytes -> int -> int -> unit\n'
            '                     = "caml_blit_bytes" [@@noalloc]\n'
            'external unsafe_blit_string : string -> int -> bytes -> int -> int -> unit\n'
            '                     = "caml_blit_string" [@@noalloc]',
            "let unsafe_blit = CamlinternalBulkOps.blit_bytes\n"
            "let unsafe_blit_string = CamlinternalBulkOps.blit_string",
        ),
        (
            'external equal : t -> t -> bool = "caml_bytes_equal" [@@noalloc]',
            "let equal = CamlinternalBulkOps.bytes_equal",
        ),
    ],
    "string.ml": [
        (
            'external unsafe_blit : string -> int ->  bytes -> int -> int -> unit\n'
            '                     = "caml_blit_string" [@@noalloc]',
            "let unsafe_blit = CamlinternalBulkOps.blit_string",
        ),
        (
            'external seeded_hash : int -> string -> int = "caml_string_hash" [@@noalloc]',
            "let seeded_hash = CamlinternalBulkOps.string_hash",
        ),
        (
            'external equal : string -> string -> bool = "caml_string_equal" [@@noalloc]',
            "let equal = CamlinternalBulkOps.string_equal",
        ),
    ],
    "array.ml": [
        (
            'external unsafe_sub : \'a array -> int -> int -> \'a array = "caml_array_sub"\n'
            'external append_prim : \'a array -> \'a array -> \'a array = "caml_array_append"\n'
            'external concat : \'a array list -> \'a array = "caml_array_concat"\n'
            'external unsafe_blit :\n'
            '  \'a array -> int -> \'a array -> int -> int -> unit = "caml_array_blit"\n'
            'external unsafe_fill :\n'
            '  \'a array -> int -> int -> \'a -> unit = "caml_array_fill"\n'
            'external create_float: int -> float array = "caml_array_create_float"\n\n'
            'module Floatarray = struct\n'
            '  external create : int -> floatarray = "caml_floatarray_create"',
            "let unsafe_sub = CamlinternalBulkOps.array_sub\n"
            "let append_prim = CamlinternalBulkOps.array_append\n"
            "let concat = CamlinternalBulkOps.array_concat\n"
            "let unsafe_blit = CamlinternalBulkOps.array_blit\n"
            "let unsafe_fill = CamlinternalBulkOps.array_fill\n"
            "let create_float = CamlinternalBulkOps.array_create_float\n\n"
            "module Floatarray = struct\n"
            "  let create = CamlinternalBulkOps.floatarray_create",
        ),
    ],
    "iarray.ml": [
        (
            'external concat : \'a iarray list -> \'a iarray = "caml_array_concat"\n\n'
            'external append_prim : \'a iarray -> \'a iarray -> \'a iarray = "caml_array_append"\n'
            'external unsafe_sub : \'a iarray -> int -> int -> \'a iarray = "caml_array_sub"',
            "external opaque_cast : 'a -> 'b = \"%opaque\"\n"
            "let concat (lst : 'a iarray list) : 'a iarray =\n"
            "  opaque_cast (CamlinternalBulkOps.array_concat (opaque_cast lst))\n"
            "let append_prim (a : 'a iarray) (b : 'a iarray) : 'a iarray =\n"
            "  opaque_cast (CamlinternalBulkOps.array_append (opaque_cast a) (opaque_cast b))\n"
            "let unsafe_sub (a : 'a iarray) (o : int) (l : int) : 'a iarray =\n"
            "  opaque_cast (CamlinternalBulkOps.array_sub (opaque_cast a) o l)",
        ),
    ],
    "float.ml": [
        (
            '  external create : int -> t = "caml_floatarray_create"\n'
            '  external unsafe_get : t -> int -> float = "%floatarray_unsafe_get"\n'
            '  external unsafe_set : t -> int -> float -> unit = "%floatarray_unsafe_set"\n\n'
            '  external make : (int[@untagged]) -> (float[@unboxed]) -> t =\n'
            '    "caml_floatarray_make" "caml_floatarray_make_unboxed"\n\n'
            '  external unsafe_fill\n'
            '    : t -> (int[@untagged]) -> (int[@untagged]) -> (float[@unboxed]) -> unit\n'
            '    = "caml_floatarray_fill" "caml_floatarray_fill_unboxed" [@@noalloc]\n\n'
            '  external unsafe_blit: t -> int -> t -> int -> int -> unit =\n'
            '    "caml_floatarray_blit" [@@noalloc]\n\n'
            '  external unsafe_sub : t -> int -> int -> t = "caml_floatarray_sub"\n'
            '  external append_prim : t -> t -> t = "caml_floatarray_append"\n'
            '  external concat : t list -> t = "caml_floatarray_concat"',
            '  let create = CamlinternalBulkOps.floatarray_create\n'
            '  external unsafe_get : t -> int -> float = "%floatarray_unsafe_get"\n'
            '  external unsafe_set : t -> int -> float -> unit = "%floatarray_unsafe_set"\n\n'
            '  let make = CamlinternalBulkOps.floatarray_make\n'
            '  let unsafe_fill = CamlinternalBulkOps.floatarray_fill\n'
            '  let unsafe_blit = CamlinternalBulkOps.floatarray_blit\n'
            '  let unsafe_sub = CamlinternalBulkOps.floatarray_sub\n'
            '  let append_prim = CamlinternalBulkOps.floatarray_append\n'
            '  let concat = CamlinternalBulkOps.floatarray_concat',
        ),
    ],
    "int.ml": [
        (
            'external format_int : string -> int -> string = "caml_format_int"',
            "let format_int = CamlinternalIntFmt.format_int",
        ),
    ],
    "int32.ml": [
        (
            'external format : string -> int32 -> string = "caml_int32_format"',
            "let format = CamlinternalIntFmt.format_int32",
        ),
        (
            'external of_string : string -> int32 = "caml_int32_of_string"',
            "let of_string = CamlinternalIntFmt.parse_int32",
        ),
    ],
    "int64.ml": [
        (
            'external format : string -> int64 -> string = "caml_int64_format"',
            "let format = CamlinternalIntFmt.format_int64",
        ),
        (
            'external of_string : string -> int64 = "caml_int64_of_string"',
            "let of_string = CamlinternalIntFmt.parse_int64",
        ),
    ],
    "nativeint.ml": [
        (
            'external format : string -> nativeint -> string = "caml_nativeint_format"',
            "let format = CamlinternalIntFmt.format_nativeint",
        ),
        (
            'external of_string: string -> nativeint = "caml_nativeint_of_string"',
            "let of_string = CamlinternalIntFmt.parse_nativeint",
        ),
    ],
    "uchar.ml": [
        (
            'external format_int : string -> int -> string = "caml_format_int"',
            "let format_int = CamlinternalIntFmt.format_int",
        ),
    ],
    "camlinternalFormat.ml": [
        (
            'external format_int: string -> int -> string\n  = "caml_format_int"\n'
            'external format_int32: string -> int32 -> string\n  = "caml_int32_format"\n'
            'external format_nativeint: string -> nativeint -> string\n  = "caml_nativeint_format"\n'
            'external format_int64: string -> int64 -> string\n  = "caml_int64_format"',
            "let format_int = CamlinternalIntFmt.format_int\n"
            "let format_int32 = CamlinternalIntFmt.format_int32\n"
            "let format_nativeint = CamlinternalIntFmt.format_nativeint\n"
            "let format_int64 = CamlinternalIntFmt.format_int64",
        ),
    ],
    "scanf.ml": [
        (
            'external nativeint_of_string : string -> nativeint\n  = "caml_nativeint_of_string"\n\n'
            'external int32_of_string : string -> int32\n  = "caml_int32_of_string"\n\n'
            'external int64_of_string : string -> int64\n  = "caml_int64_of_string"',
            "let nativeint_of_string = CamlinternalIntFmt.parse_nativeint\n"
            "let int32_of_string = CamlinternalIntFmt.parse_int32\n"
            "let int64_of_string = CamlinternalIntFmt.parse_int64",
        ),
    ],
}


def apply_compat_patches(filename: str, text: str) -> str:
    for old, new in _COMPAT_PATCHES.get(filename, []):
        if old not in text:
            raise RuntimeError(f"compat patch mismatch in {filename}: {old!r}")
        text = text.replace(old, new)
    return text


def materialize_sources(
    vendor_src: Path, overlay_dir: Path, work_src: Path
) -> dict[str, tuple[str, Path | None, Path | None]]:
    """Copy upstream + overlay .mli/.ml into work_src and run expand_module_aliases.awk."""
    if work_src.exists():
        shutil.rmtree(work_src)
    work_src.mkdir(parents=True, exist_ok=True)

    awk_script = vendor_src / "expand_module_aliases.awk"
    modules = parse_stdlib_modules(vendor_src / "StdlibModules")
    if "camlinternalFormatBasics" in modules and "camlinternalIntFmt" not in modules:
        idx = modules.index("camlinternalFormatBasics") + 1
        modules.insert(idx, "camlinternalIntFmt")
    if "camlinternalIntFmt" in modules and "camlinternalBulkOps" not in modules:
        idx = modules.index("camlinternalIntFmt") + 1
        modules.insert(idx, "camlinternalBulkOps")
    if "camlinternalBulkOps" in modules and "camlinternalMarshal" not in modules:
        idx = modules.index("camlinternalBulkOps") + 1
        modules.insert(idx, "camlinternalMarshal")
    if (vendor_src / "std_exit.ml").exists() or (overlay_dir / "std_exit.ml").exists():
        if "std_exit" not in modules:
            modules.append("std_exit")

    extra_file = overlay_dir / "EXTRA_MODULES"
    if extra_file.exists():
        for ln in extra_file.read_text(encoding="utf-8").splitlines():
            mod = ln.split("#", 1)[0].strip()
            if mod and mod not in modules:
                modules.append(mod)

    resolved: dict[str, tuple[str, Path | None, Path | None]] = {}
    awk_bin = shutil.which("awk") or "awk"

    def resolve_one(base: str, ext: str) -> tuple[str, Path | None]:
        ov = overlay_dir / f"{base}.{ext}"
        st = overlay_dir.parent / f"{base}.{ext}"
        up = vendor_src / f"{base}.{ext}"
        if ov.exists():
            src = ov
            layer = "overlay"
        elif base.startswith("camlinternal") and base != "camlinternalFormatBasics" and st.exists():
            src = st
            layer = "overlay"
        elif up.exists():
            src = up
            layer = "upstream"
        else:
            return ("missing", None)

        dst = work_src / f"{base}.{ext}"
        needs_awk = base == "stdlib" or (base.endswith("Labels") and ext == "mli")
        if needs_awk and awk_script.exists():
            proc = subprocess.run(
                [awk_bin, "-f", str(awk_script), f"{base}.{ext}"],
                cwd=str(src.parent),
                text=True,
                capture_output=True,
                check=True,
            )
            text = apply_compat_patches(f"{base}.{ext}", proc.stdout)
            dst.write_text(text, encoding="utf-8")
        else:
            raw = src.read_text(encoding="utf-8")
            patched = apply_compat_patches(f"{base}.{ext}", raw)
            if patched != raw:
                dst.write_text(patched, encoding="utf-8")
            else:
                shutil.copy2(src, dst)
        return (layer, dst)

    for base in modules:
        mli_layer, mli_dst = resolve_one(base, "mli")
        ml_layer, ml_dst = resolve_one(base, "ml")
        if mli_layer == "overlay" or ml_layer == "overlay":
            layer = "overlay"
        elif mli_layer == "upstream" or ml_layer == "upstream":
            layer = "upstream"
        else:
            layer = "missing"
        resolved[base] = (layer, mli_dst, ml_dst)

    return resolved


def compflags_for(base: str, ext: str) -> list[str]:
    flags: list[str] = []
    if base in ("camlinternalFormatBasics", "camlinternalIntFmt", "camlinternalBulkOps", "camlinternalMarshal", "stdlib"):
        flags.append("--nopervasives")
    if base == "stdlib" or base.endswith("Labels") or base == "float":
        flags.append("--no-alias-deps")
    if (base.endswith("Labels") and ext == "ml") or (base == "float" and ext == "ml"):
        flags.append("--nolabels")
    return flags


def parse_cmi_deps(depend_path: Path, bases: list[str]) -> list[str]:
    """Topologically order module basenames for .mli -> .cmi compilation."""
    prefix_to_base = {unit_prefix(b): b for b in bases}
    deps: dict[str, list[str]] = {b: [] for b in bases}
    if depend_path.exists():
        raw = depend_path.read_text(encoding="utf-8")
        # Join backslash-continued lines
        joined = raw.replace("\\\n", " ")
        for line in joined.splitlines():
            line = line.strip()
            if ":" not in line:
                continue
            lhs, rhs = line.split(":", 1)
            lhs = lhs.strip()
            if not lhs.endswith(".cmi"):
                continue
            target_prefix = lhs[:-4]
            target_base = prefix_to_base.get(target_prefix)
            if target_base is None:
                continue
            for tok in rhs.split():
                if tok.endswith(".cmi"):
                    dep_prefix = tok[:-4]
                    dep_base = prefix_to_base.get(dep_prefix)
                    if dep_base is not None and dep_base != target_base:
                        if dep_base not in deps[target_base]:
                            deps[target_base].append(dep_base)

    # Every module besides camlinternalFormatBasics, camlinternalIntFmt, camlinternalBulkOps, camlinternalMarshal, and stdlib implicitly opens Stdlib
    for b in bases:
        if b not in ("camlinternalFormatBasics", "camlinternalIntFmt", "camlinternalBulkOps", "camlinternalMarshal", "stdlib") and "stdlib" in deps:
            if "stdlib" not in deps[b]:
                deps[b].append("stdlib")
    if "stdlib" in deps and "camlinternalFormatBasics" in deps:
        if "camlinternalFormatBasics" not in deps["stdlib"]:
            deps["stdlib"].append("camlinternalFormatBasics")
    if "stdlib" in deps and "camlinternalIntFmt" in deps:
        if "camlinternalIntFmt" not in deps["stdlib"]:
            deps["stdlib"].append("camlinternalIntFmt")
    if "stdlib" in deps and "camlinternalBulkOps" in deps:
        if "camlinternalBulkOps" not in deps["stdlib"]:
            deps["stdlib"].append("camlinternalBulkOps")
    if "stdlib" in deps and "camlinternalMarshal" in deps:
        if "camlinternalMarshal" not in deps["stdlib"]:
            deps["stdlib"].append("camlinternalMarshal")

    order: list[str] = []
    state: dict[str, int] = {}  # 0=unseen, 1=visiting, 2=done

    def visit(u: str) -> None:
        st = state.get(u, 0)
        if st == 2 or st == 1:
            return
        state[u] = 1
        for d in deps.get(u, []):
            visit(d)
        state[u] = 2
        order.append(u)

    for b in bases:
        visit(b)
    return order


def compile_stdlib(
    root: Path,
    ocamlcc: Path,
    qbe: Path,
    qbe_target: str,
    vendor_src: Path,
    overlay_dir: Path,
    out_dir: Path,
    work_src: Path,
) -> tuple[list[ModuleResult], list[Path]]:
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    resolved = materialize_sources(vendor_src, overlay_dir, work_src)
    mli_order = parse_cmi_deps(vendor_src / ".depend", list(resolved.keys()))

    mli_status: dict[str, tuple[bool, str]] = {}
    for base in mli_order:
        _layer, mli_path, _ml_path = resolved[base]
        if mli_path is None:
            mli_status[base] = (True, "")
            continue
        cmi_prefix = out_dir / unit_prefix(base)
        cmd_mli = [
            str(ocamlcc),
            "compile-mli",
            "--nostdlib",
            "-I",
            str(out_dir),
            "--cmi-prefix",
            str(cmi_prefix),
            *compflags_for(base, "mli"),
            str(mli_path),
        ]
        p_mli = run_cmd(cmd_mli)
        if p_mli.returncode != 0:
            mli_status[base] = (False, extract_first_error(p_mli.stderr, p_mli.stdout))
        else:
            mli_status[base] = (True, "")

    results: list[ModuleResult] = []
    built_objs: list[Path] = []

    for base, (layer, mli_path, ml_path) in resolved.items():
        prefix = unit_prefix(base)
        cmi_prefix = out_dir / prefix
        ssa_path = out_dir / f"{prefix}.ssa"
        asm_path = out_dir / f"{prefix}.s"
        obj_path = out_dir / f"{prefix}.o"

        mli_ok, mli_err = mli_status.get(base, (True, ""))
        ml_ok = False
        qbe_ok = False
        as_ok = False
        stage_failed = "compile-mli" if not mli_ok else ""
        error = mli_err

        if ml_path is not None and mli_ok:
            cmd_ml = [
                str(ocamlcc),
                "compile",
                "--nostdlib",
                "-I",
                str(out_dir),
                "--mod",
                *([] if mli_path is not None else ["--emit-cmi"]),
                "--cmi-prefix",
                str(cmi_prefix),
                *compflags_for(base, "ml"),
                str(ml_path),
                "-o",
                str(ssa_path),
            ]
            p_ml = run_cmd(cmd_ml)
            if p_ml.returncode != 0:
                stage_failed = "compile-ml"
                error = extract_first_error(p_ml.stderr, p_ml.stdout)
            else:
                ml_ok = True
                p_qbe = run_cmd([str(qbe), "-t", qbe_target, str(ssa_path)])
                if p_qbe.returncode != 0:
                    stage_failed = "qbe"
                    error = extract_first_error(p_qbe.stderr, p_qbe.stdout)
                else:
                    asm_path.write_text(p_qbe.stdout, encoding="utf-8")
                    qbe_ok = True
                    p_as = run_cmd(
                        ["cc", "-c", "-fPIC", str(asm_path), "-o", str(obj_path)]
                    )
                    if p_as.returncode != 0:
                        stage_failed = "cc-as"
                        error = extract_first_error(p_as.stderr, p_as.stdout)
                    else:
                        as_ok = True
                        built_objs.append(obj_path)

        results.append(
            ModuleResult(
                base=base,
                prefix=prefix,
                source_layer=layer,
                mli_ok=mli_ok,
                ml_ok=ml_ok,
                qbe_ok=qbe_ok,
                as_ok=as_ok,
                stage_failed=stage_failed,
                error=error,
            )
        )

    archive = out_dir / "libocamlstdlib_compat.a"
    if built_objs:
        if archive.exists():
            archive.unlink()
        run_cmd(["ar", "rcs", str(archive), *[str(o) for o in built_objs]])

    return results, built_objs


@dataclass
class TestResult:
    name: str
    status: str  # PASS, SKIP_EXPECT, SKIP_MULTIFILE, SKIP_OTHER, FAIL_ML, FAIL_QBE, FAIL_LINK, FAIL_RUN, FAIL_DIFF
    detail: str


def parse_ocamltest_header(src: str) -> str | None:
    m = re.search(r"\(\*\s*TEST\b(.*?)\*\)", src, re.DOTALL)
    return m.group(1) if m else None


def find_reference_file(ml_file: Path) -> Path | None:
    cand1 = ml_file.with_suffix(".reference")
    if cand1.exists():
        return cand1
    cand2 = Path(str(ml_file) + ".reference")
    if cand2.exists():
        return cand2
    return None


def run_lib_tests(
    testsuite_dir: Path,
    ocamlcc: Path,
    qbe: Path,
    qbe_target: str,
    stdlib_out: Path,
    rt_dir: Path,
    test_build_dir: Path,
    patterns: list[str] | None = None,
) -> list[TestResult]:
    if test_build_dir.exists():
        shutil.rmtree(test_build_dir)
    test_build_dir.mkdir(parents=True, exist_ok=True)

    rt_objs = [
        rt_dir / f
        for f in [
            "pal.o",
            "pal_ctx.o",
            "arc.o",
            "closure.o",
            "fiber.o",
            "builtins.o",
            "main_entry.o",
        ]
    ]
    stdlib_archive = stdlib_out / "libocamlstdlib_compat.a"

    results: list[TestResult] = []
    for suite_dir in sorted(testsuite_dir.glob("lib-*")):
        if not suite_dir.is_dir():
            continue
        for ml_file in sorted(suite_dir.glob("*.ml")):
            rel_name = f"{suite_dir.name}/{ml_file.name}"
            if patterns and not any(fnmatch.fnmatchcase(rel_name, pattern) for pattern in patterns):
                continue
            src = ml_file.read_text(encoding="utf-8", errors="replace")
            hdr = parse_ocamltest_header(src)
            if hdr is None:
                results.append(TestResult(rel_name, "SKIP_OTHER", "helper file without (* TEST *)"))
                continue

            if re.search(r"\bexpect\b", hdr):
                results.append(TestResult(rel_name, "SKIP_EXPECT", "toplevel expect test"))
                continue

            if (
                re.search(r"\ball_modules\s*=", hdr)
                or re.search(r"\bmodules\s*=", hdr)
                or re.search(r"\binclude\s+", hdr)
                or re.search(r"\bscript\b", hdr)
                or re.search(r"\bbytecode\b", hdr)
                or re.search(r"\bC\b", hdr)
            ):
                results.append(
                    TestResult(
                        rel_name,
                        "SKIP_MULTIFILE",
                        "requires external modules/C stubs/ocamltest directive",
                    )
                )
                continue

            flags: list[str] = []
            if re.search(r"-nolabels", hdr):
                flags.append("--nolabels")

            run_args: list[str] = []
            arg_m = re.search(r'\barguments\s*=\s*"([^"]*)"', hdr)
            if arg_m:
                raw_args = arg_m.group(1).replace("${test_build_directory}", str(test_build_dir))
                run_args = shlex.split(raw_args)

            stem = f"{suite_dir.name}__{ml_file.stem}"
            ssa = test_build_dir / f"{stem}.ssa"
            asm = test_build_dir / f"{stem}.s"
            obj = test_build_dir / f"{stem}.o"
            exe = test_build_dir / stem

            run_dir = test_build_dir / (stem + "-work")
            shutil.copytree(suite_dir, run_dir)

            p_ml = run_cmd(
                [
                    str(ocamlcc),
                    "compile",
                    "--nostdlib",
                    "-I",
                    str(stdlib_out),
                    *flags,
                    str(ml_file),
                    "-o",
                    str(ssa),
                ]
            )
            if p_ml.returncode != 0:
                results.append(
                    TestResult(
                        rel_name,
                        "FAIL_ML",
                        extract_first_error(p_ml.stderr, p_ml.stdout),
                    )
                )
                continue

            p_qbe = run_cmd([str(qbe), "-t", qbe_target, str(ssa)])
            if p_qbe.returncode != 0:
                results.append(
                    TestResult(
                        rel_name,
                        "FAIL_QBE",
                        extract_first_error(p_qbe.stderr, p_qbe.stdout),
                    )
                )
                continue
            asm.write_text(p_qbe.stdout, encoding="utf-8")

            link_inputs = [str(asm)]
            if stdlib_archive.exists():
                link_inputs.append(str(stdlib_archive))
            link_inputs.extend(str(r) for r in rt_objs)
            p_link = run_cmd(["cc", *link_inputs, "-lm", "-o", str(exe)])
            if p_link.returncode != 0:
                results.append(
                    TestResult(
                        rel_name,
                        "FAIL_LINK",
                        extract_first_error(p_link.stderr, p_link.stdout),
                    )
                )
                continue

            try:
                p_run = run_cmd([str(exe), *run_args], cwd=run_dir, timeout=30, merge_stderr=True)
            except subprocess.TimeoutExpired:
                results.append(TestResult(rel_name, "FAIL_RUN", "timeout (10s)"))
                continue

            if p_run.returncode != 0:
                results.append(
                    TestResult(
                        rel_name,
                        "FAIL_RUN",
                        f"exit {p_run.returncode}: {extract_first_error(p_run.stderr, p_run.stdout)}",
                    )
                )
                continue

            ref_file = find_reference_file(ml_file)
            if ref_file is not None:
                expected = ref_file.read_text(encoding="utf-8", errors="replace")
                if p_run.stdout != expected:
                    results.append(
                        TestResult(
                            rel_name,
                            "FAIL_DIFF",
                            f"stdout mismatch vs {ref_file.name}",
                        )
                    )
                    continue

            results.append(TestResult(rel_name, "PASS", ""))

    return results


def write_report(
    report_path: Path,
    mod_results: list[ModuleResult],
    test_results: list[TestResult] | None,
) -> None:
    lines: list[str] = []
    total_mods = len(mod_results)
    mli_pass = sum(1 for r in mod_results if r.mli_ok)
    full_pass = sum(1 for r in mod_results if r.as_ok)
    overlaid = sum(1 for r in mod_results if r.source_layer == "overlay")

    lines.append("# Upstream OCaml Stdlib Compatibility Report")
    lines.append("")
    lines.append(f"- Modules checked: `{total_mods}` (overlaid: `{overlaid}`)")
    lines.append(f"- `.mli` -> `.cmi` passed: `{mli_pass}/{total_mods}`")
    lines.append(f"- Full `.ml` -> `.ssa` -> `.s` -> `.o` passed: `{full_pass}/{total_mods}`")
    lines.append("")
    lines.append("## Module Matrix")
    lines.append("")
    lines.append("| Module | Unit | Source | `.mli` | `.ml` -> `.o` | First Failure |")
    lines.append("|---|---|---|---|---|---|")
    for r in mod_results:
        mli_s = "PASS" if r.mli_ok else "FAIL"
        obj_s = "PASS" if r.as_ok else f"FAIL ({r.stage_failed})"
        err_s = r.error.replace("|", "\\|") if r.error else ""
        lines.append(
            f"| `{r.base}` | `{r.prefix}` | {r.source_layer} | {mli_s} | {obj_s} | {err_s} |"
        )

    if test_results is not None:
        counts: dict[str, int] = {}
        for tr in test_results:
            counts[tr.status] = counts.get(tr.status, 0) + 1
        runnable = [tr for tr in test_results if not tr.status.startswith("SKIP_")]
        passed = counts.get("PASS", 0)
        lines.append("")
        lines.append("## Upstream `lib-*` Test Suite")
        lines.append("")
        lines.append(
            f"- Standalone `.ml` tests passed: `{passed}/{len(runnable)}` "
            f"(skipped: `SKIP_EXPECT={counts.get('SKIP_EXPECT', 0)}`, "
            f"`SKIP_MULTIFILE={counts.get('SKIP_MULTIFILE', 0)}`, "
            f"`SKIP_OTHER={counts.get('SKIP_OTHER', 0)}`)"
        )
        lines.append("")
        lines.append("| Test | Status | Detail |")
        lines.append("|---|---|---|")
        for tr in test_results:
            det = tr.detail.replace("|", "\\|")
            lines.append(f"| `{tr.name}` | {tr.status} | {det} |")

    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Build & test upstream OCaml stdlib with overlay")
    parser.add_argument("--tests", nargs="+", help="Select upstream paths by glob, e.g. 'lib-bigarray/*'")
    parser.add_argument("--reuse-stdlib", action="store_true", help="Reuse the last stdlib build and module receipt")
    parser.add_argument("--skip-tests", action="store_true", help="Only compile stdlib modules")
    parser.add_argument("--report", default="build/stdlib_compat/report.md")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    ocamlcc = root / "build/bin/ocamlcc"
    qbe = root / "build/qbe/qbe"
    rt_dir = root / "build/rt"
    vendor_src = root / "vendor/ocaml-stdlib/src"
    testsuite_dir = root / "vendor/ocaml-stdlib/testsuite/tests"
    overlay_dir = root / "stdlib/overlay"
    compat_dir = root / "build/stdlib_compat"
    work_src = compat_dir / "src"
    out_dir = compat_dir / "out"
    test_build_dir = compat_dir / "tests"
    report_path = root / args.report

    for req in (ocamlcc, qbe, vendor_src / "StdlibModules"):
        if not req.exists():
            print(f"error: missing required path {req} (run ninja first?)", file=sys.stderr)
            return 2

    global COMMAND_LOG_DIR
    COMMAND_LOG_DIR = compat_dir / "logs" / time.strftime("%Y%m%d-%H%M%S")
    qbe_target = detect_host_qbe_target()
    module_receipt = compat_dir / "modules.json"
    if args.reuse_stdlib:
        mod_results = [ModuleResult(**result) for result in json.loads(module_receipt.read_text())]
    else:
        mod_results, _ = compile_stdlib(
            root, ocamlcc, qbe, qbe_target, vendor_src, overlay_dir, out_dir, work_src
        )
        module_receipt.write_text(json.dumps([asdict(result) for result in mod_results], indent=2))

    test_results: list[TestResult] | None = None
    if not args.skip_tests and testsuite_dir.exists():
        test_results = run_lib_tests(
            testsuite_dir, ocamlcc, qbe, qbe_target, out_dir, rt_dir, test_build_dir, args.tests
        )

    write_report(report_path, mod_results, test_results)

    total_mods = len(mod_results)
    mli_pass = sum(1 for r in mod_results if r.mli_ok)
    full_pass = sum(1 for r in mod_results if r.as_ok)
    print(f"Stdlib modules: mli {mli_pass}/{total_mods}, full .o {full_pass}/{total_mods}")

    if test_results is not None:
        runnable = [tr for tr in test_results if not tr.status.startswith("SKIP_")]
        passed = sum(1 for tr in test_results if tr.status == "PASS")
        print(f"Upstream lib-* standalone tests: {passed}/{len(runnable)} passed (total scanned: {len(test_results)})")
    print(f"Report written to {report_path}")
    print(f"Command logs: {COMMAND_LOG_DIR}")
    (report_path.with_suffix(".json")).write_text(json.dumps(dict(
        modules=[asdict(result) for result in mod_results],
        tests=[asdict(result) for result in test_results] if test_results is not None else None,
        command_logs=str(COMMAND_LOG_DIR)), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
