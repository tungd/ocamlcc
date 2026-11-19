#!/usr/bin/env python3
"""TDD unit tests for tools/fetch-ocaml-compiler-libs.py."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tools" / "fetch-ocaml-compiler-libs.py"
EXPECTED_SHA256 = "c018052c8264a3791a8f54f84179e6bcc78ed82eb889bacc2773df445259aed3"


class FetchCompilerLibsTests(unittest.TestCase):
    def test_rejects_corrupt_tarball_sha256(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ocamlcc_fetch_bad_") as tmp:
            bad_tar = Path(tmp) / "bad.tar.gz"
            bad_tar.write_bytes(b"not a valid ocaml tarball")
            out_dir = Path(tmp) / "out"
            res = subprocess.run(
                [sys.executable, str(SCRIPT), "--tarball", str(bad_tar), "--out", str(out_dir)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("sha-256", (res.stderr + res.stdout).lower())
            self.assertFalse((out_dir / "MANIFEST.json").exists())

    def test_extracts_all_104_modules_and_4_mli_only(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ocamlcc_fetch_ok_") as tmp:
            out_dir = Path(tmp) / "src"
            res = subprocess.run(
                [sys.executable, str(SCRIPT), "--out", str(out_dir)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(res.returncode, 0, msg=res.stdout + res.stderr)

            manifest_path = out_dir / "MANIFEST.json"
            self.assertTrue(manifest_path.is_file())
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["version"], "5.5.0")
            self.assertEqual(manifest["sha256"], EXPECTED_SHA256)
            self.assertEqual(len(manifest["modules"]), 104)
            self.assertEqual(len(manifest["mli_only"]), 4)
            self.assertEqual(len(manifest["mli_order"]), 108)

            comp_dir = out_dir / "compiler-libs"
            for mod in manifest["modules"]:
                base = mod[0].lower() + mod[1:]
                self.assertTrue((comp_dir / f"{base}.ml").is_file(), f"missing {base}.ml")
                self.assertTrue((comp_dir / f"{base}.mli").is_file(), f"missing {base}.mli")
            for mod in manifest["mli_only"]:
                base = mod[0].lower() + mod[1:]
                self.assertTrue((comp_dir / f"{base}.mli").is_file(), f"missing {base}.mli")

            # Generated config.ml must have no unsubstituted @...@ placeholders.
            cfg = (comp_dir / "config.ml").read_text(encoding="utf-8")
            self.assertIn("Caml1999I037", cfg)
            self.assertNotIn("@CMI_MAGIC_NUMBER@", cfg)
            self.assertNotIn("@EXEC_MAGIC_NUMBER@", cfg)

            # Generated lexer.ml and pre-generated parser.ml must be non-empty.
            self.assertGreater((comp_dir / "lexer.ml").stat().st_size, 10000)
            self.assertGreater((comp_dir / "parser.ml").stat().st_size, 100000)

            # boot/menhir/parser.{ml,mli} must rewrite MenhirLib -> CamlinternalMenhirLib.
            parser_mli = (comp_dir / "parser.mli").read_text(encoding="utf-8")
            self.assertIn("CamlinternalMenhirLib", parser_mli)
            self.assertNotIn(" MenhirLib.", parser_mli)
            self.assertNotIn(": MenhirLib.", parser_mli)


if __name__ == "__main__":
    unittest.main()
