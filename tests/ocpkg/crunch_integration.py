#!/usr/bin/env python3
"""Exercise an ocamlcc-built crunch binary and save bounded command receipts."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import ocpkg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default=str(ROOT / "build/crunch"))
    args = parser.parse_args()
    build = Path(args.build_dir).resolve()
    binary = build / "ocaml-crunch"
    upstream = build / "vendor/crunch/test"
    artifacts = build / "integration"
    artifacts.mkdir(parents=True, exist_ok=True)
    receipt = dict(status="running", binary=str(binary), binary_sha256=ocpkg.file_hash(binary),
                   plan_sha256=ocpkg.file_hash(build / "ocpkg-plan.json"), checks=[], commands=[],
                   coverage_excluded=["Lwt/Mirage generated-code consumer suite", "upstream Cmdliner and Ptime suites"])
    env = dict(os.environ, SOURCE_DATE_EPOCH="0", TERM="dumb")

    def save():
        ocpkg.write_json(artifacts / "receipt.json", receipt)

    def run(name, command, *, expected=0, timeout=60, environment=env):
        log = artifacts / (name + ".log")
        started = time.monotonic()
        with log.open("w") as out:
            proc = subprocess.Popen(list(map(str, command)), cwd=artifacts, env=environment,
                                    stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
            timed_out = False
            try:
                code = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                code = 124
        receipt["commands"].append(dict(name=name, command=list(map(str, command)),
                                        exit_code=code, timed_out=timed_out,
                                        seconds=time.monotonic()-started, log=str(log)))
        save()
        if code != expected:
            raise RuntimeError(f"{name}: exit {code}, expected {expected}; see {log}")
        return log.read_text(errors="replace")

    def check(name, ok):
        receipt["checks"].append(dict(name=name, passed=bool(ok)))
        save()
        if not ok:
            raise RuntimeError(f"check failed: {name}")

    save()
    try:
        check("version", run("version", [binary, "--version"]).strip() == "v4.1.0")
        check("help", "DIRECTORIES" in run("help", [binary, "--help=plain"]))
        run("invalid-option", [binary, "--not-an-option"], expected=124)
        for name, flags, expected_files in [
            ("plain", ["--mode=plain"], [("t1_plain.ml", "t1_plain.expected.ml")]),
            ("extension", ["--mode=plain", "-e", "ext"], [("t1_plain_ext.ml", "t1_plain_ext.expected.ml")]),
            ("lwt", ["--mode=lwt"], [("t1.ml", "t1.expected.ml"), ("t1.mli", "t1.expected.mli")]),
        ]:
            output = artifacts / expected_files[0][0]
            run(name, [binary, *flags, "-o", output, upstream / "t1"])
            for actual, expected_file in expected_files:
                check(actual + " matches upstream", (artifacts / actual).read_bytes() == (upstream / expected_file).read_bytes())
        data = artifacts / "data"
        (data / "nested").mkdir(parents=True, exist_ok=True)
        payloads = {"empty": b"", "nested/all-bytes.bin": bytes(range(256)) * 33,
                    "quotes\".txt": b'hello\x00world\n"\\', "repeated": b"abcd" * 3000}
        for name, content in payloads.items():
            (data / name).write_bytes(content)
        for block in (0, 17):
            run(f"roundtrip-generate-{block}", [binary, "--mode=plain", "--silent", "-b", block,
                                               "-o", artifacts / "embedded.ml", data])
            assertions = []
            for name, content in payloads.items():
                literal = json.dumps(name)
                assertions += [f"assert (Embedded.size {literal} = Some {len(content)});",
                               f"assert (Embedded.hash {literal} = Some \"{hashlib.md5(content).hexdigest()}\");",
                               f"assert (Embedded.read {literal} = Some (In_channel.with_open_bin {json.dumps(str(data / name))} In_channel.input_all));"]
            (artifacts / "consumer.ml").write_text("let () =\n" + "\n".join(assertions) +
                                                    '\nassert (Embedded.read "missing" = None);\nprint_endline "roundtrip: ok"\n')
            run(f"roundtrip-compile-{block}", [ROOT / "build/bin/occ", "build", "--stdlib-dir", ROOT / "build/stdlib",
                                              "--runtime-dir", ROOT / "runtime", "--qbe", ROOT / "build/qbe/qbe",
                                              "--runtime-objects-dir", build / "no-prebuilt-runtime",
                                              "--work-dir", artifacts / f"consumer-work-{block}", artifacts / "embedded.ml",
                                              artifacts / "consumer.ml", "-o", artifacts / f"consumer-{block}"], timeout=180)
            check(f"roundtrip-{block}", run(f"roundtrip-run-{block}", [artifacts / f"consumer-{block}"]).strip() == "roundtrip: ok")
        live_env = dict(env)
        del live_env["SOURCE_DATE_EPOCH"]
        run("live-clock", [binary, "--mode=plain", "--silent", "-o", artifacts / "live.ml", data], environment=live_env)
        check("live clock output", (artifacts / "live.ml").read_text().startswith("(* Generated by: ocaml-crunch"))
        receipt["status"] = "passed"
        return 0
    except (RuntimeError, OSError) as error:
        receipt["status"] = "failed"
        receipt["error"] = str(error)
        print(error, file=sys.stderr)
        return 1
    finally:
        save()
        print(json.dumps(dict(status=receipt["status"], checks=len(receipt["checks"]), receipt=str(artifacts / "receipt.json"))))


if __name__ == "__main__":
    sys.exit(main())
