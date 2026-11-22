#!/usr/bin/env python3
"""Run pinned upstream non-Lwt checks serially with per-command receipts."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]

def file_hash(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["all", "crunch", "cmdliner", "ptime", "harness"], default="all")
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/crunch")
    args = parser.parse_args()
    base = args.build_dir.resolve()
    vendor = base / "vendor"
    out = base / "non-lwt"
    out.mkdir(parents=True, exist_ok=True)
    receipt_path = out / (args.suite + "-receipt.json")
    receipt = dict(status="running", pid=os.getpid(), commands=[], checks=[],
                   compiler_sha256=file_hash(ROOT / "build/bin/occ"),
                   snapshot_sha256=file_hash(ROOT / "packages/snapshots/default.snap"),
                   harness={p.name:file_hash(p) for p in (ROOT / "tests/ocpkg/ptime_harness").iterdir() if p.is_file()},
                   notes=["Upstream package/test sources are unchanged.",
                          "Ptime uses a test-only B0 assertion adapter with fixed seed 20261118; loop counts remain upstream defaults.",
                          "Ptime gmtime oracle is libc gmtime_r for ARC and stock Unix.gmtime for stock OCaml."],
                   exclusions=["Crunch's Lwt/Mirage consumer", "Ptime test_gmtime_all and min_clock (upstream run:false)"])
    env = dict(os.environ, SOURCE_DATE_EPOCH="0", TERM="dumb", LC_ALL="C", OCAMLRUNPARAM="b=0")

    def save():
        temporary = receipt_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        temporary.replace(receipt_path)

    def run(name, command, *, cwd=out, executable=None, timeout=240):
        deadline = time.monotonic() + 900
        while True:
            pattern = (r"(^|/)(dune|ninja|occ|ocpkg|ocamlopt|llmopt|qbe|bootstrap[.]py|stdlib_compat[.]py)( |$)"
                       r"| build-probe[.]py( |$)")
            active = subprocess.run(["pgrep", "-f", pattern], text=True, capture_output=True)
            if not active.stdout.strip(): break
            if time.monotonic() > deadline:
                raise RuntimeError(f"{name}: waiting deadline; command not launched")
            time.sleep(5)
        number = len(receipt["commands"])
        stdout, stderr = out / f"{number:03}-{name}.stdout", out / f"{number:03}-{name}.stderr"
        started = time.monotonic()
        with stdout.open("wb") as sout, stderr.open("wb") as serr:
            proc = subprocess.Popen(list(map(str, command)), executable=executable,
                                    cwd=cwd, env=env, stdout=sout, stderr=serr, start_new_session=True)
            timed_out = False
            try: code = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(proc.pid, signal.SIGTERM)
                try: proc.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(proc.pid, signal.SIGKILL); proc.wait()
                code = 124
        receipt["commands"].append(dict(name=name, command=list(map(str, command)), executable=str(executable) if executable else None,
                                        exit_code=code, timed_out=timed_out, seconds=time.monotonic()-started,
                                        stdout=str(stdout), stderr=str(stderr)))
        save()
        return code, stdout.read_bytes(), stderr.read_bytes()

    def check(name, ok, detail=""):
        receipt["checks"].append(dict(name=name, passed=bool(ok), detail=detail))
        print(("PASS " if ok else "FAIL ") + name + (": " + detail if detail else ""), flush=True)
        save()

    def require(name, result):
        if result[0]:
            raise RuntimeError(f"{name}: exit {result[0]}; {result[2].decode(errors='replace')[-1200:]}")
        return result

    def arc_build(name, sources):
        binary = out / "arc" / name
        binary.parent.mkdir(exist_ok=True)
        command = [ROOT / "build/bin/occ", "build", "--stdlib-dir", ROOT / "build/stdlib",
                   "--runtime-dir", ROOT / "runtime", "--runtime-objects-dir", base / "no-prebuilt-runtime",
                   "--qbe", ROOT / "build/qbe/qbe", "--cflags", "-I" + str(ROOT / "runtime"),
                   "--work-dir", out / "work" / name, *sources, "-o", binary]
        require(name + " build", run(name + "-build", command))
        return binary

    def stock_units(name, sources):
        directory = out / "stock" / name
        directory.mkdir(parents=True, exist_ok=True)
        local = []
        for source in sources:
            destination = directory / source.name
            shutil.copyfile(source, destination)
            local.append(destination.name)
        order = require(name + " dependencies", run(name + "-deps", ["ocamldep", "-sort", *local], cwd=directory))[1].decode().split()
        for filename in order:
            require(filename, run(name + "-" + filename, ["ocamlopt", "-I", "+unix", "-w", "-a", "-alert", "-all", "-c", filename], cwd=directory))
        return directory, [str(Path(filename).with_suffix(".cmx")) for filename in order if filename.endswith(".ml")]

    def crunch():
        binary = base / "ocaml-crunch"
        for name, flags, expected in [
            ("plain", ["--mode=plain"], "t1_plain.expected.ml"),
            ("plain-extension", ["--mode=plain", "-e", "ext"], "t1_plain_ext.expected.ml"),
        ]:
            generated = out / (name + ".ml")
            result = run("crunch-" + name, [binary, *flags, "-o", generated, vendor / "crunch/test/t1"])
            check("Crunch " + name + " upstream golden", result[0] == 0 and generated.read_bytes() == (vendor / "crunch/test" / expected).read_bytes())

    def cmdliner():
        sources = sorted((vendor / "cmdliner/src").glob("*.ml")) + sorted((vendor / "cmdliner/src").glob("*.mli"))
        stock, objects = stock_units("cmdliner", sources)
        cases = {
            "test_pos": [[], ["a", "b", "c", "d"]], "test_pos_rev": [[], ["a", "b", "c", "d"]],
            "test_pos_all": [[], ["a", "b", "c"]], "test_pos_left": [[], ["a", "b", "c", "d"]],
            "test_pos_req": [[], ["a", "b", "c", "d"]], "test_opt_req": [[], ["--req", "value"]],
            "test_term_dups": [["value", "--flag"]], "test_with_used_args": [["-a", "-b", "value", "x", "--other"]],
            "test_nest": [["birds", "fly", "eagle", "--speed", "5"], ["camels", "--bactrian"], ["unknown"]],
            "test_dupe_stdopts": [["old", "--help=plain"], ["new", "--help=plain"], ["old", "sub"], ["new", "sub"]],
            "test_man": [[]], "test_man_utf8": [[]], "chorus": [[], ["--count", "2", "hello"]],
            "revolt": [[]], "rm_ex": [["--force", "a", "b"]], "tail_ex": [["-n", "3", "a"]],
            "cp_ex": [["a", "b"]], "darcs_ex": [["initialize"], ["record", "--all"]],
        }
        for source in sorted((vendor / "cmdliner/test").glob("*.ml")):
            name = source.stem
            arc = arc_build(name, [*sources, source])
            copied = stock / source.name
            shutil.copyfile(source, copied)
            reference = stock / name
            require(name + " stock build", run(name + "-stock-build", ["ocamlopt", "-w", "-a", "-alert", "-all", *objects, copied.name, "-o", reference], cwd=stock))
            invocations = cases[name]
            if name != "test_dupe_stdopts": invocations = [["--help=plain"], ["--ocpkg-invalid"], *invocations]
            for index, arguments in enumerate(invocations):
                actual = run(f"{name}-{index}-arc", [name, *arguments], executable=str(arc), timeout=30)
                expected = run(f"{name}-{index}-stock", [name, *arguments], executable=str(reference), timeout=30)
                check(f"Cmdliner {name} {' '.join(arguments) or '(default)'}", actual == expected,
                      f"exit={actual[0]}, stock={expected[0]}; stdout/stderr compared")

    def ptime():
        harness = ROOT / "tests/ocpkg/ptime_harness"
        library = [vendor / "ptime/src/ptime.mli", vendor / "ptime/src/ptime.ml"]
        adapter = [harness / "b0_std.ml", harness / "b0_testing.ml"]
        common = [*library, *adapter, vendor / "ptime/test/testing_ptime.ml"]
        stock, objects = stock_units("ptime", common)
        oracle = [harness / "unix.ml", harness / "gmtime_stubs.c"]
        modules = [vendor / "ptime/test" / (name + ".ml") for name in
                   ["test_span", "test_base", "test_date", "test_date_time", "test_rfc3339"]]
        for name, test_sources in [("assertions", [harness / "assertions.ml"]),
                                    ("test_ptime", modules + [vendor / "ptime/test/test_ptime.ml"]),
                                    ("test_gmtime", [vendor / "ptime/test/test_gmtime.ml"]),
                                    ("examples", [vendor / "ptime/test/examples.ml"])]:
            if args.suite == "harness" and name != "assertions":
                continue
            arc = arc_build(name, [*common, *oracle, *test_sources])
            for source in test_sources: shutil.copyfile(source, stock / source.name)
            reference = stock / name
            require(name + " stock build", run(name + "-stock-build", ["ocamlopt", "-I", "+unix", "-w", "-a", "unix.cmxa", *objects,
                                                                         *[p.name for p in test_sources], "-o", reference], cwd=stock))
            actual = run(name + "-arc", [name], executable=str(arc), timeout=180)
            expected = run(name + "-stock", [name], executable=str(reference), timeout=180)
            ok = actual[0] == expected[0] == 0
            if name == "assertions":
                ok = ok and all(b"negative controls: 9/9 detected" in result[1] for result in (actual, expected))
            check("Ptime " + name, ok, f"exit={actual[0]}, stock={expected[0]}")
            for line in actual[1].decode(errors="replace").splitlines():
                if line.startswith(("PASS ", "FAIL ", "RESULT ")): print("  " + line, flush=True)

    try:
        save()
        require("vendor integrity", run("vendor-integrity", [ROOT / "build/bin/ocpkg", "verify"], cwd=base))
        for name, function in [("crunch", crunch), ("cmdliner", cmdliner), ("ptime", ptime)]:
            if args.suite in ("all", name) or (args.suite == "harness" and name == "ptime"):
                try: function()
                except (RuntimeError, OSError) as error:
                    check(name + " suite execution", False, str(error))
        receipt["status"] = "passed" if all(c["passed"] for c in receipt["checks"]) else "failed"
    except (RuntimeError, OSError) as error:
        check("vendor integrity", False, str(error))
        receipt["status"] = "failed"
    finally:
        save()
        print(json.dumps(dict(status=receipt["status"], passed=sum(c["passed"] for c in receipt["checks"]),
                              total=len(receipt["checks"]), receipt=str(receipt_path))), flush=True)
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
