"""Offline package acquisition and build-manifest contracts."""
import copy
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import shutil
import subprocess
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import ocpkg


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.root_patch = patch.object(ocpkg, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.sources = self.root / "sources"
        self.sources.mkdir()
        (self.sources / "main.ml").write_text('print_endline "hello"\n')
        self.package = dict(name="hello", version="1", dependencies=[],
                            source=dict(local="sources", tree_sha256=ocpkg.tree_hash(self.sources)),
                            files=[dict(source="main.ml", name="main.ml")], executable="hello")
        self.snapshot = self.root / "snapshot.json"
        self.lock_path = self.root / "lock.json"
        self.vendor = self.root / "vendor"
        self.cache = self.root / "cache"

    def lock(self, packages=None):
        ocpkg.write_json(self.snapshot, dict(schema=1, packages=packages or [self.package]))
        return ocpkg.lock_snapshot(self.snapshot, "hello", self.lock_path)

    def archive(self, entries):
        archive = self.root / "source.tar"
        with tarfile.open(archive, "w") as tf:
            for name, kind, data in entries:
                member = tarfile.TarInfo(name)
                member.type = kind
                member.size = len(data) if kind == tarfile.REGTYPE else 0
                member.linkname = "../../escape" if kind == tarfile.SYMTYPE else ""
                tf.addfile(member, io.BytesIO(data) if member.isfile() else None)
        return archive

    def test_lock_deterministic_and_query_offline(self):
        self.lock()
        original = self.lock_path.read_bytes()
        self.lock()
        self.assertEqual(original, self.lock_path.read_bytes())
        with patch("urllib.request.urlopen", side_effect=AssertionError("network")):
            self.assertEqual(ocpkg.load_lock(self.lock_path)["target"], "hello")

    def test_dependency_closure_and_cycle(self):
        dep = dict(self.package, name="dep", dependencies=[])
        self.package["dependencies"] = ["dep"]
        lock = self.lock([self.package, dep])
        self.assertEqual([p["name"] for p in lock["packages"]], ["dep", "hello"])
        dep["dependencies"] = ["hello"]
        with self.assertRaisesRegex(ocpkg.PackageError, "cycle"):
            self.lock([self.package, dep])

    def test_missing_and_duplicate_packages(self):
        self.package["dependencies"] = ["missing"]
        with self.assertRaisesRegex(ocpkg.PackageError, "missing package"):
            self.lock()
        with self.assertRaisesRegex(ocpkg.PackageError, "duplicate package"):
            self.lock([self.package, self.package])

    def test_changed_recipe_and_tampered_lock(self):
        self.lock()
        value = ocpkg.read_json(self.lock_path)
        value["packages"][0]["files"][0]["source"] = "other.ml"
        ocpkg.write_json(self.lock_path, value)
        with self.assertRaisesRegex(ocpkg.PackageError, "do not match"):
            ocpkg.load_lock(self.lock_path)
        self.lock()
        self.snapshot.write_text(self.snapshot.read_text() + "\n")
        with self.assertRaisesRegex(ocpkg.PackageError, "recipes changed"):
            ocpkg.load_lock(self.lock_path)

    def test_vendor_keeps_edits_and_detects_added_files(self):
        lock = self.lock()
        ocpkg.vendor(lock, self.vendor, self.cache, offline=True)
        edited = self.vendor / "hello/main.ml"
        edited.write_text("local edit")
        with self.assertRaisesRegex(ocpkg.PackageError, "refusing to overwrite"):
            ocpkg.vendor(lock, self.vendor, self.cache, offline=True)
        self.assertEqual(edited.read_text(), "local edit")
        edited.write_bytes((self.sources / "main.ml").read_bytes())
        (self.vendor / "hello/extra.ml").write_text("unexpected")
        with self.assertRaisesRegex(ocpkg.PackageError, "changed"):
            ocpkg.verify_vendor(lock, self.vendor)

    def test_local_symlinks_rejected(self):
        (self.sources / "link").symlink_to(self.root / "outside")
        with self.assertRaisesRegex(ocpkg.PackageError, "unsupported source entry"):
            ocpkg.tree_hash(self.sources)

    def test_path_traversal_links_and_duplicate_archive_members(self):
        for entries in [
            [("pkg/../../escape", tarfile.REGTYPE, b"bad")],
            [("/absolute", tarfile.REGTYPE, b"bad")],
            [("pkg/link", tarfile.SYMTYPE, b"")],
            [("pkg/hard", tarfile.LNKTYPE, b"")],
            [("pkg/file", tarfile.REGTYPE, b"a"), ("pkg/file", tarfile.REGTYPE, b"b")],
        ]:
            with self.subTest(entries=entries), tempfile.TemporaryDirectory() as dest:
                with self.assertRaises(ocpkg.PackageError):
                    ocpkg.extract_archive(self.archive(entries), dest, "pkg")
        self.assertFalse((self.root / "escape").exists())

    def test_cached_archive_digest_is_checked_offline(self):
        self.cache.mkdir()
        key = "0" * 64
        (self.cache / key).write_bytes(b"wrong")
        with self.assertRaisesRegex(ocpkg.PackageError, "digest mismatch"):
            ocpkg.archive_for(dict(sha256=key), self.cache, offline=True)

    def test_fetch_verifies_bytes_before_publishing_cache(self):
        response = io.BytesIO(b"wrong bytes")
        response.geturl = lambda: "https://example.test/package"
        source = dict(sha256="0" * 64, url=response.geturl())
        with patch("urllib.request.urlopen", return_value=response):
            with self.assertRaisesRegex(ocpkg.PackageError, "digest mismatch"):
                ocpkg.archive_for(source, self.cache)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_archive_vendor_roundtrip_and_offline_cache_miss(self):
        archive = self.archive([("pkg/main.ml", tarfile.REGTYPE, b"let x = 1\n")])
        self.cache.mkdir()
        key = ocpkg.file_hash(archive)
        (self.cache / key).write_bytes(archive.read_bytes())
        with tempfile.TemporaryDirectory() as dest:
            ocpkg.extract_archive(archive, dest, "pkg")
            tree = ocpkg.tree_hash(Path(dest) / "pkg")
        self.package["source"] = dict(url="https://example.test/pkg.tar", sha256=key,
                                      root="pkg", tree_sha256=tree)
        lock = self.lock()
        with patch("urllib.request.urlopen", side_effect=AssertionError("network")):
            ocpkg.vendor(lock, self.vendor, self.cache, offline=True)
            ocpkg.verify_vendor(lock, self.vendor)
            with self.assertRaisesRegex(ocpkg.PackageError, "offline cache"):
                ocpkg.archive_for(dict(sha256="1" * 64), self.cache, offline=True)

    def test_tree_hash_tracks_executable_bit_and_contents(self):
        before = ocpkg.tree_hash(self.sources)
        p = self.sources / "main.ml"
        p.chmod(0o755)
        self.assertNotEqual(before, ocpkg.tree_hash(self.sources))

    def test_unsafe_recipe_paths(self):
        for value in ("../outside.ml", "/tmp/main.ml", "a\nmain.ml"):
            with self.subTest(value=value):
                package = copy.deepcopy(self.package)
                package["files"][0]["source"] = value
                with self.assertRaises(ocpkg.PackageError):
                    self.lock([package])

    def test_ninja_path_escaping(self):
        self.assertEqual(ocpkg.ninja_path("/a b/$x:y"), "/a$ b/$$x$:y")
        self.assertIn("$$HOME", ocpkg.ninja_command(["echo", "$HOME"]))
        with self.assertRaises(ocpkg.PackageError):
            ocpkg.ninja_path("a\nb")

    def test_plan_detects_toolchain_changes(self):
        lock = self.lock()
        ocpkg.vendor(lock, self.vendor, self.cache, offline=True)
        stdlib, runtime = self.root / "stdlib", self.root / "runtime"
        stdlib.mkdir(); runtime.mkdir()
        (stdlib / "stdlib.cmi").write_bytes(b"cmi")
        (stdlib / "stdlib.o").write_bytes(b"obj")
        (runtime / "arc.h").write_bytes(b"header")
        output = self.root / "build dir/build.ninja"
        ocpkg.emit_ninja(self.lock_path, self.vendor, output, sys.executable,
                        sys.executable, stdlib, runtime)
        plan, stamp = output.parent / "ocpkg-plan.json", output.parent / "verified.stamp"
        ocpkg.verify_plan(plan, stamp)
        before = stamp.stat().st_mtime_ns
        ocpkg.verify_plan(plan, stamp)
        self.assertEqual(before, stamp.stat().st_mtime_ns)
        (stdlib / "extra.o").write_bytes(b"new")
        with self.assertRaisesRegex(ocpkg.PackageError, "directory changed"):
            ocpkg.verify_plan(plan, stamp)
        (stdlib / "extra.o").unlink()
        unexpected = output.parent / "no-prebuilt-runtime/arc.o"
        unexpected.write_bytes(b"unrecorded runtime")
        with self.assertRaisesRegex(ocpkg.PackageError, "unexpected prebuilt runtime"):
            ocpkg.verify_plan(plan, stamp)

    @unittest.skipUnless(shutil.which("ninja"), "Ninja is not installed")
    def test_generated_rules_incremental_and_tamper_check(self):
        # Exercise actual Ninja parsing/shell quoting with a tiny fake compiler.
        # This tests the executor contract without a compiler workload.
        lock = self.lock()
        ocpkg.vendor(lock, self.vendor, self.cache, offline=True)
        stdlib, runtime = self.root / "stdlib", self.root / "runtime"
        stdlib.mkdir(); runtime.mkdir()
        (stdlib / "stdlib.cmi").write_bytes(b"cmi")
        (stdlib / "stdlib.o").write_bytes(b"obj")
        (runtime / "arc.h").write_bytes(b"header")
        compiler = self.root / "fake compiler"
        compiler.write_text("#!" + sys.executable + "\nimport sys\nfrom pathlib import Path\n"
                            "p=Path(sys.argv[sys.argv.index('-o')+1])\n"
                            "p.write_text('built')\n"
                            "with p.with_suffix('.count').open('a') as f: f.write('1')\n")
        compiler.chmod(0o755)
        output = self.root / "build space/build.ninja"
        # The real CLI needs a real repository-relative snapshot in this test.
        tool = self.root / "tools/ocpkg.py"
        tool.parent.mkdir()
        shutil.copyfile(ocpkg.__file__, tool)
        with patch.object(ocpkg, "__file__", str(tool)):
            ocpkg.emit_ninja(self.lock_path, self.vendor, output, str(compiler),
                            sys.executable, stdlib, runtime)
        command = ["ninja", "-j1", "-f", str(output)]
        for _ in range(2):
            result = subprocess.run(command, cwd=self.root, text=True, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((output.parent / "hello.count").read_text(), "1")
        source = self.vendor / "hello/main.ml"
        before = source.stat()
        source.write_text("tampered")
        os.utime(source, ns=(before.st_atime_ns, before.st_mtime_ns))
        result = subprocess.run(command, cwd=self.root, text=True, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("vendored source changed", result.stdout)
        self.assertEqual((output.parent / "hello.count").read_text(), "1")


if __name__ == "__main__":
    unittest.main()
