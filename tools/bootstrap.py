#!/usr/bin/env python3
"""
Multi-stage self-hosting bootstrap orchestrator for ocamlcc.

  Stage 0: host Dune / ocamlopt -> build/bin/ocamlcc
  Stage 1: stage0 compiles stdlib_compat (72) + compiler-libs subset (104+4)
           + bootstrap/unix + ocamlcc (16) -> build/bootstrap/stage1/ocamlcc
  Stage 2: stage1 compiles the exact same ~193 modules -> build/bootstrap/stage2/ocamlcc
  Verify:  bit-for-bit .ssa and .s diff between stage1 and stage2 + smoke tests.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import stdlib_compat  # noqa: E402


OCAMLCC_MODULES: list[tuple[str, bool, bool]] = [
    # (basename, has_mli, is_mod)
    ("bigarray_header", False, True),
    ("qbe_il", True, True),
    ("ccalls", True, True),
    ("builtins", True, True),
    ("frontend", True, True),
    ("anf", True, True),
    ("arc_pass", True, True),
    ("codegen_ctx", False, True),
    ("codegen_analysis", False, True),
    ("codegen_expr", False, True),
    ("codegen_fn", False, True),
    ("codegen", True, True),
    ("pipeline", True, True),
    ("c_bindgen", True, True),
    ("driver", True, True),
    ("main", False, False),
]


@dataclasses.dataclass
class UnitStatus:
    layer: str
    module: str
    mli_ok: bool
    ml_ok: bool
    qbe_ok: bool
    as_ok: bool
    stage_failed: str
    error: str
    seconds: float


def detect_zstd_flags() -> tuple[list[str], list[str]]:
    def try_pkg_config(flag: str) -> list[str] | None:
        if not shutil.which("pkg-config"):
            return None
        p = subprocess.run(
            ["pkg-config", flag, "libzstd"], capture_output=True, text=True
        )
        if p.returncode == 0 and p.stdout.strip():
            return shlex.split(p.stdout.strip())
        return None

    cflags = try_pkg_config("--cflags")
    libs = try_pkg_config("--libs")
    if cflags is not None and libs is not None:
        return cflags, libs

    # Fallback: check common prefixes on macOS/Linux.
    for prefix in ("/opt/local", "/opt/homebrew", "/usr/local", "/usr"):
        inc = Path(prefix) / "include" / "zstd.h"
        if inc.is_file():
            return [f"-I{prefix}/include"], [f"-L{prefix}/lib", "-lzstd"]
    return [], ["-lzstd"]


class CommandRunner:
    def __init__(self, log_dir: Path, timeout: int) -> None:
        self.log_dir = log_dir
        self.timeout = timeout
        self.counter = 0
        self.log_dir.mkdir(parents=True, exist_ok=True)

    def run(
        self, cmd: list[str], cwd: Path | None = None, timeout: int | None = None
    ) -> subprocess.CompletedProcess[str]:
        self.counter += 1
        t_lim = timeout if timeout is not None else self.timeout
        started = time.monotonic()
        try:
            res = subprocess.run(
                cmd,
                cwd=str(cwd) if cwd else None,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=t_lim,
            )
        except subprocess.TimeoutExpired as exc:
            def dec(v: object) -> str:
                if isinstance(v, bytes):
                    return v.decode(errors="replace")
                return str(v or "")

            res = subprocess.CompletedProcess(
                cmd, 124, dec(exc.stdout), dec(exc.stderr) + f"\ntimeout ({t_lim}s)"
            )
        elapsed = time.monotonic() - started
        log_path = self.log_dir / f"{self.counter:05d}.log"
        log_path.write_text(
            "$ " + shlex.join(cmd) + "\n" + (res.stdout or "") + (res.stderr or ""),
            encoding="utf-8",
        )
        with (self.log_dir / "commands.jsonl").open("a", encoding="utf-8") as f:
            f.write(
                json.dumps(
                    {
                        "command": cmd,
                        "exit_code": res.returncode,
                        "seconds": round(elapsed, 4),
                        "log": str(log_path),
                    }
                )
                + "\n"
            )
        return res


def first_err(res: subprocess.CompletedProcess[str]) -> str:
    return stdlib_compat.extract_first_error(res.stderr, res.stdout)


def generate_bigarray_header_ml(out_path: Path) -> None:
    hdr = (ROOT / "runtime" / "ocamlcc_bigarray_types.h").read_text(encoding="utf-8")
    out_path.write_text(f"let contents = {{|{hdr}|}}\n", encoding="utf-8")


def compile_ocaml_unit(
    runner: CommandRunner,
    compiler: Path,
    qbe: Path,
    qbe_target: str,
    layer: str,
    modname: str,
    ml_path: Path,
    out_dir: Path,
    include_dirs: list[Path],
    is_mod: bool,
    emit_cmi: bool,
    extra_flags: list[str] | None = None,
) -> tuple[UnitStatus, Path | None]:
    t0 = time.monotonic()
    base = ml_path.stem
    ssa_path = out_dir / f"{base}.ssa"
    asm_path = out_dir / f"{base}.s"
    obj_path = out_dir / f"{base}.o"

    cmd = [str(compiler), "compile", "--nostdlib"]
    for inc in include_dirs:
        cmd += ["-I", str(inc)]
    if is_mod:
        cmd.append("--mod")
    if emit_cmi:
        cmd += ["--cmi-prefix", str(out_dir / base)]
    if extra_flags:
        cmd += extra_flags
    cmd += [str(ml_path), "-o", str(ssa_path)]

    p_ml = runner.run(cmd)
    if p_ml.returncode != 0:
        return (
            UnitStatus(
                layer, modname, True, False, False, False, "compile-ml",
                first_err(p_ml), time.monotonic() - t0,
            ),
            None,
        )

    p_qbe = runner.run([str(qbe), "-t", qbe_target, str(ssa_path)])
    if p_qbe.returncode != 0:
        return (
            UnitStatus(
                layer, modname, True, True, False, False, "qbe",
                first_err(p_qbe), time.monotonic() - t0,
            ),
            None,
        )
    asm_path.write_text(p_qbe.stdout, encoding="utf-8")

    p_as = runner.run(["cc", "-c", "-fPIC", str(asm_path), "-o", str(obj_path)])
    if p_as.returncode != 0:
        return (
            UnitStatus(
                layer, modname, True, True, True, False, "cc-as",
                first_err(p_as), time.monotonic() - t0,
            ),
            None,
        )

    return (
        UnitStatus(
            layer, modname, True, True, True, True, "", "", time.monotonic() - t0
        ),
        obj_path,
    )


def ensure_fetched(src_dir: Path, tarball: Path | None) -> dict:
    cmd = [sys.executable, str(ROOT / "tools" / "fetch-ocaml-compiler-libs.py"), "--out", str(src_dir)]
    if tarball is not None:
        cmd += ["--tarball", str(tarball)]
    p = subprocess.run(cmd, text=True)
    if p.returncode != 0:
        raise RuntimeError("fetch-ocaml-compiler-libs.py failed")
    return json.loads((src_dir / "MANIFEST.json").read_text(encoding="utf-8"))


def build_stage(
    stage_name: str,
    compiler: Path,
    qbe: Path,
    qbe_target: str,
    rt_archive: Path,
    src_dir: Path,
    manifest: dict,
    stage_dir: Path,
    timeout: int,
    reuse_stdlib: Path | None = None,
    stop_on_error: bool = False,
    only_compiler_libs: bool = False,
) -> tuple[bool, list[UnitStatus], Path | None]:
    print(f"\n=== {stage_name}: compiler={compiler} ===", flush=True)
    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    stage_dir.mkdir(parents=True, exist_ok=True)
    runner = CommandRunner(stage_dir / "logs", timeout=timeout)

    statuses: list[UnitStatus] = []

    # 1. stdlib_compat (72 modules)
    stdlib_dir = stage_dir / "stdlib"
    stdlib_work_src = stage_dir / "stdlib_src"
    if reuse_stdlib is not None and (reuse_stdlib / "libocamlstdlib_compat.a").is_file():
        print(f"[{stage_name}] Reusing stdlib_compat from {reuse_stdlib}", flush=True)
        shutil.copytree(reuse_stdlib, stdlib_dir)
        stdlib_archive = stdlib_dir / "libocamlstdlib_compat.a"
    else:
        print(f"[{stage_name}] Compiling stdlib_compat (72 modules)...", flush=True)
        stdlib_compat.COMMAND_LOG_DIR = stage_dir / "logs" / "stdlib"
        stdlib_compat.COMMAND_NUMBER = 0
        t0 = time.monotonic()
        mod_results, _objs = stdlib_compat.compile_stdlib(
            root=ROOT,
            ocamlcc=compiler,
            qbe=qbe,
            qbe_target=qbe_target,
            vendor_src=ROOT / "vendor" / "ocaml-stdlib" / "src",
            overlay_dir=ROOT / "stdlib" / "overlay",
            out_dir=stdlib_dir,
            work_src=stdlib_work_src,
        )
        stdlib_dt = time.monotonic() - t0
        stdlib_ok = sum(1 for r in mod_results if r.as_ok)
        print(
            f"[{stage_name}] stdlib_compat: {stdlib_ok}/{len(mod_results)} passed ({stdlib_dt:.1f}s)",
            flush=True,
        )
        for r in mod_results:
            statuses.append(
                UnitStatus(
                    "stdlib", r.prefix, r.mli_ok, r.ml_ok, r.qbe_ok, r.as_ok,
                    r.stage_failed, r.error, 0.0,
                )
            )
            if not r.as_ok:
                print(f"  FAIL stdlib/{r.prefix} ({r.stage_failed}): {r.error}", flush=True)
                if stop_on_error:
                    write_stage_report(stage_dir, stage_name, statuses, None)
                    return False, statuses, None
        stdlib_archive = stdlib_dir / "libocamlstdlib_compat.a"
        if stdlib_ok != len(mod_results):
            write_stage_report(stage_dir, stage_name, statuses, None)
            return False, statuses, None

    # 2. compiler-libs.common (108 .mli + 104 .ml)
    comp_src = src_dir / "compiler-libs"
    comp_out = stage_dir / "compiler-libs"
    comp_out.mkdir(parents=True, exist_ok=True)
    mli_order: list[str] = manifest["mli_order"]
    comp_modules: list[str] = manifest["modules"]

    print(
        f"[{stage_name}] Compiling compiler-libs .mli ({len(mli_order)} interfaces)...",
        flush=True,
    )
    mli_failed: dict[str, str] = {}
    t_mli = time.monotonic()
    for mod in mli_order:
        base = mod[0].lower() + mod[1:]
        mli_path = comp_src / f"{base}.mli"
        p = runner.run(
            [
                str(compiler),
                "compile-mli",
                "--nostdlib",
                "-I",
                str(stdlib_dir),
                "-I",
                str(comp_out),
                "--cmi-prefix",
                str(comp_out / base),
                str(mli_path),
            ]
        )
        if p.returncode != 0:
            err = first_err(p)
            mli_failed[mod] = err
            print(f"  FAIL mli {mod}: {err}", flush=True)
            if stop_on_error:
                statuses.append(
                    UnitStatus("compiler-libs", mod, False, False, False, False, "compile-mli", err, 0.0)
                )
                write_stage_report(stage_dir, stage_name, statuses, None)
                return False, statuses, None
    print(
        f"[{stage_name}] compiler-libs .mli: {len(mli_order) - len(mli_failed)}/{len(mli_order)} passed ({time.monotonic() - t_mli:.1f}s)",
        flush=True,
    )

    print(
        f"[{stage_name}] Compiling compiler-libs .ml ({len(comp_modules)} modules)...",
        flush=True,
    )
    comp_objs: list[Path] = []
    comp_pass = 0
    t_ml = time.monotonic()
    for idx, mod in enumerate(comp_modules, 1):
        base = mod[0].lower() + mod[1:]
        if mod in mli_failed:
            statuses.append(
                UnitStatus(
                    "compiler-libs", mod, False, False, False, False,
                    "compile-mli", mli_failed[mod], 0.0,
                )
            )
            continue
        ml_path = comp_src / f"{base}.ml"
        st, obj = compile_ocaml_unit(
            runner=runner,
            compiler=compiler,
            qbe=qbe,
            qbe_target=qbe_target,
            layer="compiler-libs",
            modname=mod,
            ml_path=ml_path,
            out_dir=comp_out,
            include_dirs=[stdlib_dir, comp_out],
            is_mod=True,
            emit_cmi=False,
        )
        statuses.append(st)
        if st.as_ok and obj is not None:
            comp_objs.append(obj)
            comp_pass += 1
            if idx % 20 == 0 or idx == len(comp_modules) or st.seconds >= 2.0:
                print(
                    f"  [{idx:3d}/{len(comp_modules)}] PASS {mod} ({st.seconds:.2f}s)",
                    flush=True,
                )
        else:
            print(
                f"  [{idx:3d}/{len(comp_modules)}] FAIL {mod} ({st.stage_failed}, {st.seconds:.2f}s): {st.error}",
                flush=True,
            )
            if stop_on_error:
                write_stage_report(stage_dir, stage_name, statuses, None)
                return False, statuses, None

    print(
        f"[{stage_name}] compiler-libs .ml: {comp_pass}/{len(comp_modules)} passed ({time.monotonic() - t_ml:.1f}s)",
        flush=True,
    )
    comp_archive = comp_out / "libocamlcommon.a"
    if comp_objs:
        runner.run(["ar", "rcs", str(comp_archive), *[str(o) for o in comp_objs]])

    if only_compiler_libs or comp_pass != len(comp_modules) or mli_failed:
        ok = (comp_pass == len(comp_modules)) and not mli_failed
        write_stage_report(stage_dir, stage_name, statuses, None)
        return ok, statuses, None

    # 3. bootstrap/unix + bootstrap/stubs/compiler_stubs.c
    unix_out = stage_dir / "unix"
    unix_out.mkdir(parents=True, exist_ok=True)
    p_umli = runner.run(
        [
            str(compiler),
            "compile-mli",
            "--nostdlib",
            "-I",
            str(stdlib_dir),
            "--cmi-prefix",
            str(unix_out / "unix"),
            str(ROOT / "bootstrap" / "unix" / "unix.mli"),
        ]
    )
    if p_umli.returncode != 0:
        err = first_err(p_umli)
        statuses.append(UnitStatus("unix", "Unix", False, False, False, False, "compile-mli", err, 0.0))
        write_stage_report(stage_dir, stage_name, statuses, None)
        return False, statuses, None
    st_unix, unix_obj = compile_ocaml_unit(
        runner=runner,
        compiler=compiler,
        qbe=qbe,
        qbe_target=qbe_target,
        layer="unix",
        modname="Unix",
        ml_path=ROOT / "bootstrap" / "unix" / "unix.ml",
        out_dir=unix_out,
        include_dirs=[stdlib_dir, unix_out],
        is_mod=True,
        emit_cmi=False,
    )
    statuses.append(st_unix)
    if not st_unix.as_ok or unix_obj is None:
        print(f"  FAIL unix/Unix ({st_unix.stage_failed}): {st_unix.error}", flush=True)
        write_stage_report(stage_dir, stage_name, statuses, None)
        return False, statuses, None

    zstd_cflags, zstd_libs = detect_zstd_flags()
    unix_stubs_obj = unix_out / "unix_stubs.o"
    p_us = runner.run(
        [
            "cc", "-std=c11", "-O2", "-g", "-fPIC", "-Wall", "-Wextra", "-Werror",
            f"-I{ROOT / 'runtime'}", "-c",
            str(ROOT / "bootstrap" / "unix" / "unix_stubs.c"),
            "-o", str(unix_stubs_obj),
        ]
    )
    if p_us.returncode != 0:
        print(f"  FAIL unix_stubs.c: {first_err(p_us)}", flush=True)
        write_stage_report(stage_dir, stage_name, statuses, None)
        return False, statuses, None

    stubs_obj = stage_dir / "compiler_stubs.o"
    p_cs = runner.run(
        [
            "cc", "-std=c11", "-O2", "-g", "-fPIC", "-Wall", "-Wextra", "-Werror",
            f"-I{ROOT / 'runtime'}", *zstd_cflags, "-c",
            str(ROOT / "bootstrap" / "stubs" / "compiler_stubs.c"),
            "-o", str(stubs_obj),
        ]
    )
    if p_cs.returncode != 0:
        print(f"  FAIL compiler_stubs.c: {first_err(p_cs)}", flush=True)
        write_stage_report(stage_dir, stage_name, statuses, None)
        return False, statuses, None

    # 4. ocamlcc itself (16 modules)
    occ_out = stage_dir / "ocamlcc_objs"
    occ_out.mkdir(parents=True, exist_ok=True)
    gen_ba = occ_out / "bigarray_header.ml"
    generate_bigarray_header_ml(gen_ba)

    print(f"[{stage_name}] Compiling ocamlcc ({len(OCAMLCC_MODULES)} modules)...", flush=True)
    occ_objs: list[Path] = []
    occ_pass = 0
    for base, has_mli, is_mod in OCAMLCC_MODULES:
        mod = base[0].upper() + base[1:]
        if base == "bigarray_header":
            ml_path = gen_ba
            mli_path = None
        elif base == "main":
            ml_path = ROOT / "bin" / "main.ml"
            mli_path = None
        else:
            ml_path = ROOT / "lib" / f"{base}.ml"
            mli_path = ROOT / "lib" / f"{base}.mli" if has_mli else None

        if mli_path is not None:
            p_m = runner.run(
                [
                    str(compiler),
                    "compile-mli",
                    "--nostdlib",
                    "-I", str(stdlib_dir),
                    "-I", str(comp_out),
                    "-I", str(unix_out),
                    "-I", str(occ_out),
                    "--cmi-prefix", str(occ_out / base),
                    str(mli_path),
                ]
            )
            if p_m.returncode != 0:
                err = first_err(p_m)
                statuses.append(UnitStatus("ocamlcc", mod, False, False, False, False, "compile-mli", err, 0.0))
                print(f"  FAIL ocamlcc mli {mod}: {err}", flush=True)
                if stop_on_error:
                    write_stage_report(stage_dir, stage_name, statuses, None)
                    return False, statuses, None
                continue

        st, obj = compile_ocaml_unit(
            runner=runner,
            compiler=compiler,
            qbe=qbe,
            qbe_target=qbe_target,
            layer="ocamlcc",
            modname=mod,
            ml_path=ml_path,
            out_dir=occ_out,
            include_dirs=[stdlib_dir, comp_out, unix_out, occ_out],
            is_mod=is_mod,
            emit_cmi=(mli_path is None and is_mod),
        )
        statuses.append(st)
        if st.as_ok and obj is not None:
            occ_objs.append(obj)
            occ_pass += 1
            print(f"  PASS ocamlcc/{mod} ({st.seconds:.2f}s)", flush=True)
        else:
            print(f"  FAIL ocamlcc/{mod} ({st.stage_failed}): {st.error}", flush=True)
            if stop_on_error:
                write_stage_report(stage_dir, stage_name, statuses, None)
                return False, statuses, None

    if occ_pass != len(OCAMLCC_MODULES):
        write_stage_report(stage_dir, stage_name, statuses, None)
        return False, statuses, None

    # 5. Link the compiler executable
    bin_path = stage_dir / "ocamlcc"
    sys_libs = ["-lm", "-pthread"]
    link_cmd = [
        "cc",
        *[str(o) for o in occ_objs],
        str(unix_obj),
        str(unix_stubs_obj),
        str(stubs_obj),
        str(comp_archive),
        str(stdlib_archive),
        str(rt_archive),
        *zstd_libs,
        *sys_libs,
        "-o",
        str(bin_path),
    ]
    print(f"[{stage_name}] Linking {bin_path}...", flush=True)
    p_link = runner.run(link_cmd)
    if p_link.returncode != 0:
        print(f"  FAIL link {bin_path}: {first_err(p_link)}", flush=True)
        write_stage_report(stage_dir, stage_name, statuses, None)
        return False, statuses, None

    size_kb = bin_path.stat().st_size / 1024.0
    print(f"[{stage_name}] Linked {bin_path} ({size_kb:.1f} KiB)", flush=True)
    write_stage_report(stage_dir, stage_name, statuses, bin_path)
    return True, statuses, bin_path


def write_stage_report(
    stage_dir: Path, stage_name: str, statuses: list[UnitStatus], bin_path: Path | None
) -> None:
    passed = sum(1 for s in statuses if s.as_ok)
    total = len(statuses)
    data = {
        "stage": stage_name,
        "binary": str(bin_path) if bin_path else None,
        "passed": passed,
        "total": total,
        "units": [dataclasses.asdict(s) for s in statuses],
    }
    (stage_dir / "report.json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    lines = [
        f"# Bootstrap Report ({stage_name})",
        "",
        f"- Units passed: `{passed}/{total}`",
        f"- Binary: `{bin_path}`" if bin_path else "- Binary: *(not linked)*",
        "",
        "| Layer | Module | `.mli` | `.ml` | `qbe` | `as` | Seconds | Error |",
        "|---|---|---:|---:|---:|---:|---:|---|",
    ]
    for s in statuses:
        if not s.as_ok:
            lines.append(
                f"| `{s.layer}` | `{s.module}` | {'PASS' if s.mli_ok else 'FAIL'} | "
                f"{'PASS' if s.ml_ok else 'FAIL'} | {'PASS' if s.qbe_ok else 'FAIL'} | "
                f"{'PASS' if s.as_ok else 'FAIL'} | {s.seconds:.2f} | {s.error} |"
            )
    if passed == total:
        lines.append("| *all* | *all* | PASS | PASS | PASS | PASS | — | *(0 failures)* |")
    (stage_dir / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def verify_fixed_point(stage1_dir: Path, stage2_dir: Path) -> tuple[bool, list[str]]:
    diffs: list[str] = []
    checked = 0
    for subdir in ("stdlib", "compiler-libs", "unix", "ocamlcc_objs"):
        d1 = stage1_dir / subdir
        d2 = stage2_dir / subdir
        for ext in ("*.ssa", "*.s"):
            f1s = sorted(d1.glob(ext))
            f2s = sorted(d2.glob(ext))
            names1 = [p.name for p in f1s]
            names2 = [p.name for p in f2s]
            if names1 != names2:
                diffs.append(f"{subdir}/{ext}: file set mismatch ({len(names1)} vs {len(names2)})")
                continue
            for p1, p2 in zip(f1s, f2s):
                checked += 1
                if p1.read_bytes() != p2.read_bytes():
                    diffs.append(f"{subdir}/{p1.name}")
    print(
        f"[verify] Fixed-point comparison: {checked} files checked, {len(diffs)} differences",
        flush=True,
    )
    for d in diffs[:20]:
        print(f"  DIFF: {d}", flush=True)
    return len(diffs) == 0, diffs


def smoke_test_compiler(compiler: Path, stage_dir: Path, qbe: Path, qbe_target: str) -> bool:
    smoke_dir = stage_dir / "smoke"
    if smoke_dir.exists():
        shutil.rmtree(smoke_dir)
    smoke_dir.mkdir(parents=True, exist_ok=True)

    # 1. Compile and run examples/hello.ml using stage compiler's own stdlib.
    ssa = smoke_dir / "hello.ssa"
    asm = smoke_dir / "hello.s"
    exe = smoke_dir / "hello"
    stdlib_dir = stage_dir / "stdlib"
    p1 = subprocess.run(
        [
            str(compiler), "compile", "--nostdlib",
            "-I", str(stdlib_dir),
            str(ROOT / "examples" / "hello.ml"), "-o", str(ssa),
        ],
        capture_output=True, text=True,
    )
    if p1.returncode != 0:
        print(f"[smoke] FAIL compile hello.ml: {p1.stderr}{p1.stdout}", flush=True)
        return False
    p2 = subprocess.run([str(qbe), "-t", qbe_target, str(ssa)], capture_output=True, text=True)
    if p2.returncode != 0:
        print(f"[smoke] FAIL qbe hello.ssa: {p2.stderr}", flush=True)
        return False
    asm.write_text(p2.stdout, encoding="utf-8")
    p3 = subprocess.run(
        ["cc", str(asm), str(stdlib_dir / "libocamlstdlib_compat.a"),
         str(ROOT / "build" / "rt" / "libocamlrt.a"), "-lm", "-pthread", "-o", str(exe)],
        capture_output=True, text=True,
    )
    if p3.returncode != 0:
        print(f"[smoke] FAIL link hello: {p3.stderr}", flush=True)
        return False
    p4 = subprocess.run([str(exe)], capture_output=True, text=True)
    expected = (ROOT / "tests" / "hello.expected").read_text(encoding="utf-8")
    if p4.returncode != 0 or p4.stdout != expected:
        print(f"[smoke] FAIL run hello: rc={p4.returncode} out={p4.stdout!r}", flush=True)
        return False

    # 2. Full `ocamlcc build` multi-module driver test (exercises bootstrap/unix + QBE + cc!).
    mod_exe = smoke_dir / "mod_app"
    p5 = subprocess.run(
        [
            str(compiler), "build",
            "--qbe", str(qbe),
            "--runtime-objects-dir", str(ROOT / "build" / "rt"),
            "--stdlib-dir", str(ROOT / "build" / "stdlib"),
            str(ROOT / "examples" / "mod_lib.mli"),
            str(ROOT / "examples" / "mod_lib.ml"),
            str(ROOT / "examples" / "mod_main.ml"),
            "-o", str(mod_exe),
        ],
        capture_output=True, text=True,
    )
    if p5.returncode != 0:
        print(f"[smoke] FAIL driver build mod_app: {p5.stderr}{p5.stdout}", flush=True)
        return False
    p6 = subprocess.run([str(mod_exe)], capture_output=True, text=True)
    mod_expected = (ROOT / "tests" / "mod_main.expected").read_text(encoding="utf-8")
    if p6.returncode != 0 or p6.stdout != mod_expected:
        print(f"[smoke] FAIL run mod_app: rc={p6.returncode} out={p6.stdout!r}", flush=True)
        return False

    # 3. Direct host zstd-compressed .cmi interop check (reading host OCaml 5.5 stdlib.cmi).
    host_stdlib = subprocess.check_output(["ocamlopt", "-where"], text=True).strip()
    p7 = subprocess.run(
        [
            str(compiler), "compile", "--nostdlib",
            "-I", host_stdlib,
            str(ROOT / "examples" / "hello.ml"), "-o", str(smoke_dir / "hello_hostcmi.ssa"),
        ],
        capture_output=True, text=True,
    )
    if p7.returncode != 0:
        print(f"[smoke] FAIL host zstd .cmi interop: {p7.stderr}{p7.stdout}", flush=True)
        return False

    print("[smoke] PASS (hello, multi-module driver build, host zstd .cmi interop)", flush=True)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Self-hosted bootstrap runner for ocamlcc.")
    parser.add_argument(
        "--stage",
        choices=["fetch", "stage1", "stage2", "verify", "all"],
        default="all",
    )
    parser.add_argument("--tarball", type=Path, default=None)
    parser.add_argument("--reuse-stage1-stdlib", action="store_true")
    parser.add_argument("--stop-on-error", action="store_true")
    parser.add_argument("--only-compiler-libs", action="store_true")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()

    boot_dir = ROOT / "build" / "bootstrap"
    src_dir = boot_dir / "src"
    stage1_dir = boot_dir / "stage1"
    stage2_dir = boot_dir / "stage2"

    stage0 = ROOT / "build" / "bin" / "ocamlcc"
    qbe = ROOT / "build" / "qbe" / "qbe"
    rt_archive = ROOT / "build" / "rt" / "libocamlrt.a"
    qbe_target = stdlib_compat.detect_host_qbe_target()

    manifest = ensure_fetched(src_dir, args.tarball)
    if args.stage == "fetch":
        return 0

    for req in (stage0, qbe, rt_archive):
        if not req.is_file():
            print(f"error: required build artifact missing: {req} (run `ninja -j1` first)", file=sys.stderr)
            return 1

    if args.stage in ("stage1", "all"):
        reuse = (ROOT / "build" / "stdlib_compat" / "out") if args.reuse_stage1_stdlib else None
        ok1, _st1, bin1 = build_stage(
            stage_name="stage1",
            compiler=stage0,
            qbe=qbe,
            qbe_target=qbe_target,
            rt_archive=rt_archive,
            src_dir=src_dir,
            manifest=manifest,
            stage_dir=stage1_dir,
            timeout=args.timeout,
            reuse_stdlib=reuse,
            stop_on_error=args.stop_on_error,
            only_compiler_libs=args.only_compiler_libs,
        )
        if not ok1:
            return 1
        if bin1 is not None and not smoke_test_compiler(bin1, stage1_dir, qbe, qbe_target):
            return 1
        if args.stage == "stage1":
            return 0

    stage1_bin = stage1_dir / "ocamlcc"
    if args.stage in ("stage2", "all"):
        if not stage1_bin.is_file():
            print(f"error: stage1 binary not found at {stage1_bin}", file=sys.stderr)
            return 1
        ok2, _st2, bin2 = build_stage(
            stage_name="stage2",
            compiler=stage1_bin,
            qbe=qbe,
            qbe_target=qbe_target,
            rt_archive=rt_archive,
            src_dir=src_dir,
            manifest=manifest,
            stage_dir=stage2_dir,
            timeout=args.timeout,
            reuse_stdlib=None,
            stop_on_error=args.stop_on_error,
            only_compiler_libs=args.only_compiler_libs,
        )
        if not ok2:
            return 1
        if bin2 is not None and not smoke_test_compiler(bin2, stage2_dir, qbe, qbe_target):
            return 1

    if args.stage in ("verify", "all"):
        fp_ok, _diffs = verify_fixed_point(stage1_dir, stage2_dir)
        if not fp_ok:
            return 1
        if not smoke_test_compiler(stage2_dir / "ocamlcc", stage2_dir, qbe, qbe_target):
            return 1

    print("\n=== BOOTSTRAP COMPLETE: Stage 1 == Stage 2 FIXED POINT VERIFIED ===", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
