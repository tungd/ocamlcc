#!/usr/bin/env python3
"""Pinned package metadata, source vendoring, and Ninja rules (no build scheduler)."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import stat
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


class PackageError(Exception):
    pass


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def write_if_changed(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() == content:
        return
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as f:
        f.write(content)
        tmp = Path(f.name)
    tmp.replace(path)


def write_json(path, value):
    write_if_changed(path, json.dumps(value, indent=2, sort_keys=True) + "\n")


def relative_path(value):
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        raise PackageError(f"invalid relative path: {value!r}")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value:
        raise PackageError(f"unsafe relative path: {value!r}")
    return path


def within(root, value):
    path = Path(root) / relative_path(value)
    if not path.resolve().is_relative_to(Path(root).resolve()):
        raise PackageError(f"path escapes its root: {value}")
    return path


def tree_files(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise PackageError(f"not a source directory: {root}")
    entries = []
    for path in sorted(root.rglob("*")):
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode) or not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise PackageError(f"unsupported source entry: {path}")
        if path.is_file():
            entries.append([path.relative_to(root).as_posix(),
                            bool(mode & 0o111), file_hash(path)])
    return entries


def tree_hash(root):
    return digest(canonical(tree_files(root)))


def extract_archive(archive, destination, prefix):
    """Extract regular files only, without trusting archive paths or permissions."""
    relative_path(prefix)
    seen = set()
    total = 0
    with tarfile.open(archive) as tf:
        for member in tf:
            path = relative_path(member.name)
            if not path.parts or path.parts[0] != prefix:
                raise PackageError(f"unexpected archive root: {member.name}")
            if not (member.isdir() or member.isfile()):
                raise PackageError(f"unsupported archive entry: {member.name}")
            if path in seen:
                raise PackageError(f"duplicate archive entry: {member.name}")
            seen.add(path)
            target = within(destination, path.as_posix())
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                total += member.size
                if total > 256 * 1024 * 1024:
                    raise PackageError("archive exceeds the 256 MiB extraction limit")
                target.parent.mkdir(parents=True, exist_ok=True)
                with tf.extractfile(member) as source, target.open("xb") as out:
                    shutil.copyfileobj(source, out)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)


def archive_for(source, cache, offline=False):
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / source["sha256"]
    if path.exists():
        if file_hash(path) != source["sha256"]:
            raise PackageError(f"cached archive digest mismatch: {path}")
        return path
    if offline:
        raise PackageError(f"archive absent from offline cache: {source['sha256']}")
    if not source["url"].startswith("https://"):
        raise PackageError("source archives require HTTPS")
    tmp = None
    try:
        with urllib.request.urlopen(source["url"], timeout=30) as response:
            if not response.geturl().startswith("https://"):
                raise PackageError("source redirected away from HTTPS")
            with tempfile.NamedTemporaryFile(dir=cache, delete=False) as out:
                tmp = Path(out.name)
                total = 0
                while block := response.read(1024 * 1024):
                    total += len(block)
                    if total > 64 * 1024 * 1024:
                        raise PackageError("archive exceeds the 64 MiB download limit")
                    out.write(block)
        if file_hash(tmp) != source["sha256"]:
            raise PackageError(f"source digest mismatch: {source['url']}")
        tmp.replace(path)
        return path
    finally:
        if tmp is not None:
            tmp.unlink(missing_ok=True)


def validate_package(package):
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", package["name"]):
        raise PackageError("invalid package name")
    source = package["source"]
    for key in ("sha256", "tree_sha256") if "url" in source else ("tree_sha256",):
        if not re.fullmatch(r"[0-9a-f]{64}", source[key]):
            raise PackageError(f"invalid {key} for {package['name']}")
    if "url" in source:
        if not source["url"].startswith("https://"):
            raise PackageError("source archives require HTTPS")
        if len(relative_path(source["root"]).parts) != 1:
            raise PackageError("archive root must be one directory")
    else:
        relative_path(source["local"])
    for item in package["files"]:
        relative_path(item["source"])
        name = str(relative_path(item["name"]))
        if not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_]*\.(ml|mli|c|h)", name):
            raise PackageError(f"invalid compilation input name: {name}")
    if "executable" in package and not re.fullmatch(r"[a-zA-Z0-9_-]+", package["executable"]):
        raise PackageError("invalid executable name")


def closure(snapshot, target):
    packages = {}
    for package in snapshot["packages"]:
        validate_package(package)
        name = package["name"]
        if name in packages:
            raise PackageError(f"duplicate package: {name}")
        packages[name] = package
    ordered, active, done = [], set(), set()

    def visit(name):
        if name in active:
            raise PackageError(f"package dependency cycle: {name}")
        if name in done:
            return
        if name not in packages:
            raise PackageError(f"missing package: {name}")
        active.add(name)
        for dep in packages[name]["dependencies"]:
            visit(dep)
        active.remove(name)
        done.add(name)
        ordered.append(packages[name])

    visit(target)
    return ordered


def lock_snapshot(snapshot_path, target, output):
    snapshot_path = Path(snapshot_path).resolve()
    snapshot = read_json(snapshot_path)
    if snapshot.get("schema") != 1:
        raise PackageError("unsupported snapshot schema")
    packages = closure(snapshot, target)
    for package in packages:
        source = package["source"]
        if "local" in source and tree_hash(within(ROOT, source["local"])) != source["tree_sha256"]:
            raise PackageError(f"local recipe source changed: {package['name']}")
    if not snapshot_path.is_relative_to(ROOT):
        raise PackageError("snapshot must live in the companion repository")
    value = dict(schema=1, snapshot=snapshot_path.relative_to(ROOT).as_posix(),
                 snapshot_sha256=file_hash(snapshot_path), target=target, packages=packages)
    write_json(output, value)
    return value


def load_lock(path):
    value = read_json(path)
    if value.get("schema") != 1:
        raise PackageError("unsupported lock schema")
    snapshot_path = within(ROOT, value["snapshot"])
    if file_hash(snapshot_path) != value["snapshot_sha256"]:
        raise PackageError("snapshot/recipes changed; regenerate the lock explicitly")
    if closure(read_json(snapshot_path), value["target"]) != value["packages"]:
        raise PackageError("locked packages do not match the snapshot")
    return value


def verify_vendor(lock, directory):
    paths = []
    for package in lock["packages"]:
        path = Path(directory) / package["name"]
        if tree_hash(path) != package["source"]["tree_sha256"]:
            raise PackageError(f"vendored source changed: {path}")
        paths.append(path)
    return paths


def vendor(lock, directory, cache, offline=False):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    for package in lock["packages"]:
        target = directory / package["name"]
        source = package["source"]
        if target.exists() or target.is_symlink():
            if tree_hash(target) != source["tree_sha256"]:
                raise PackageError(f"refusing to overwrite changed vendor directory: {target}")
            continue
        with tempfile.TemporaryDirectory(dir=directory) as scratch:
            if "local" in source:
                original = within(ROOT, source["local"])
                if tree_hash(original) != source["tree_sha256"]:
                    raise PackageError(f"local recipe source changed: {original}")
                staged = Path(scratch) / "source"
                shutil.copytree(original, staged)
            else:
                archive = archive_for(source, cache, offline)
                extract_archive(archive, scratch, source["root"])
                staged = Path(scratch) / source["root"]
            if tree_hash(staged) != source["tree_sha256"]:
                raise PackageError(f"extracted source tree mismatch: {package['name']}")
            staged.rename(target)
    verify_vendor(lock, directory)


def ninja_path(path):
    value = str(path)
    if any(c in value for c in "\r\n|#"):
        raise PackageError(f"unsupported Ninja path: {value!r}")
    return value.replace("$", "$$").replace(" ", "$ ").replace(":", "$:")


def ninja_command(args):
    return shlex.join(map(str, args)).replace("$", "$$")


def tool_file(value):
    resolved = shutil.which(value)
    path = Path(resolved or value).resolve()
    if not path.is_file():
        raise PackageError(f"tool not found: {value}")
    return path


def fingerprint_files(paths):
    return {str(path): file_hash(path) for path in sorted(set(paths))}


def emit_ninja(lock_path, vendor_dir, output, compiler, qbe, stdlib, runtime):
    lock_path, vendor_dir, output = map(lambda p: Path(p).resolve(), (lock_path, vendor_dir, output))
    lock = load_lock(lock_path)
    vendor_paths = verify_vendor(lock, vendor_dir)
    compiler, qbe, cc = map(tool_file, (compiler, qbe, "cc"))
    stdlib, runtime = Path(stdlib).resolve(), Path(runtime).resolve()
    for required in (stdlib / "stdlib.cmi", runtime / "arc.h"):
        if not required.is_file():
            raise PackageError(f"missing toolchain input: {required}")
    if not list(stdlib.glob("*.o")):
        raise PackageError("stdlib directory must contain ocamlcc-built .o files")
    tool_inputs = [compiler, qbe, cc, Path(__file__).resolve()]
    tool_inputs += [p for p in stdlib.iterdir() if p.suffix in (".cmi", ".o")]
    tool_inputs += [p for p in runtime.rglob("*") if p.is_file()]
    target = next(p for p in lock["packages"] if p["name"] == lock["target"])
    if "executable" not in target:
        raise PackageError("MVP Ninja emitter requires an executable target")
    build = output.parent
    # Suppress the driver's implicit search for prebuilt runtime objects. An
    # explicit empty directory makes it compile the fingerprinted runtime source.
    runtime_objects = build / "no-prebuilt-runtime"
    runtime_objects.mkdir(parents=True, exist_ok=True)
    if list(runtime_objects.iterdir()):
        raise PackageError(f"expected empty runtime object directory: {runtime_objects}")
    executable = build / target["executable"]
    plan_path = build / "ocpkg-plan.json"
    stamp = build / "verified.stamp"
    python, tool = Path(sys.executable).resolve(), Path(__file__).resolve()
    plan = dict(schema=1, lock=str(lock_path), lock_sha256=file_hash(lock_path),
                vendor=str(vendor_dir), files=fingerprint_files(tool_inputs),
                stdlib=str(stdlib), stdlib_files=sorted(p.name for p in stdlib.iterdir() if p.suffix in (".cmi", ".o")),
                runtime=str(runtime), runtime_sha256=tree_hash(runtime),
                runtime_objects=str(runtime_objects),
                cc=str(cc), target=lock["target"], executable=str(executable))
    inputs, copied, names = [], [], set()
    lines = ["# Generated by ocpkg. Source fetching is a separate operation.",
             "ninja_required_version = 1.7", "builddir = " + ninja_path(build), "", "rule ocpkg_verify",
             "  command = " + ninja_command([python, tool, "verify", "--plan", plan_path, "--stamp", stamp]),
             "  description = VERIFY locked sources and toolchain", "  restat = 1",
             "rule ocpkg_copy", "  command = " + ninja_command([python, tool, "stage"]) + " --source $in --output $out",
             "  description = STAGE $out", "  restat = 1",
             "build ocpkg_always: phony",
             f"build {ninja_path(stamp)}: ocpkg_verify ocpkg_always", ""]
    for package, package_dir in zip(lock["packages"], vendor_paths):
        for item in package["files"]:
            name = item["name"]
            if name in names:
                raise PackageError(f"duplicate compilation input: {name}")
            names.add(name)
            source = within(package_dir, item["source"])
            if not source.is_file():
                raise PackageError(f"missing recipe input: {source}")
            dest = build / "src" / name
            lines.append(f"build {ninja_path(dest)}: ocpkg_copy {ninja_path(source)} | {ninja_path(stamp)}")
            copied.append(dest)
            if dest.suffix != ".h":
                inputs.append(dest)
    command = [compiler, "build", "--stdlib-dir", stdlib, "--runtime-dir", runtime,
               "--runtime-objects-dir", runtime_objects,
               "--qbe", qbe, "--work-dir", build / "work",
               "--cflags", "-I" + str(runtime), *inputs, "-o", executable]
    plan["command"] = list(map(str, command))
    write_json(plan_path, plan)
    lines += ["", "rule ocpkg_build", "  command = " + ninja_command(command),
              "  description = OCAMLCC " + target["executable"], "  pool = console",
              f"build {ninja_path(executable)}: ocpkg_build " + " ".join(map(ninja_path, copied))
              + " | " + " ".join(map(ninja_path, [stamp, lock_path, plan_path, output, *tool_inputs])),
              "default " + ninja_path(executable), ""]
    write_if_changed(output, "\n".join(lines))
    return plan


def verify_plan(path, stamp):
    plan = read_json(path)
    if str(tool_file("cc")) != plan["cc"]:
        raise PackageError("host C compiler resolution changed; regenerate rules")
    if list(Path(plan["runtime_objects"]).iterdir()):
        raise PackageError("unexpected prebuilt runtime objects; expected an empty directory")
    if file_hash(plan["lock"]) != plan["lock_sha256"]:
        raise PackageError("lock changed; regenerate Ninja rules explicitly")
    lock = load_lock(plan["lock"])
    verify_vendor(lock, plan["vendor"])
    for source, expected in plan["files"].items():
        if file_hash(source) != expected:
            raise PackageError(f"toolchain input changed; regenerate rules: {source}")
    actual = sorted(p.name for p in Path(plan["stdlib"]).iterdir() if p.suffix in (".cmi", ".o"))
    if actual != plan["stdlib_files"] or tree_hash(plan["runtime"]) != plan["runtime_sha256"]:
        raise PackageError("toolchain directory changed; regenerate rules")
    write_if_changed(stamp, digest(canonical(plan)) + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    lock = sub.add_parser("lock", help="select an exact closure from a local snapshot")
    lock.add_argument("--snapshot", required=True)
    lock.add_argument("--package", required=True)
    lock.add_argument("--output", required=True)
    for action in ("vendor", "status", "query"):
        p = sub.add_parser(action)
        p.add_argument("--lock", required=True)
        if action != "query":
            p.add_argument("--directory", required=True)
        if action == "vendor":
            p.add_argument("--cache", default=str(ROOT / "build/ocpkg-cache"))
            p.add_argument("--offline", action="store_true")
    emit = sub.add_parser("emit", help="emit offline build rules")
    emit.add_argument("format", choices=["ninja"])
    for key in ("lock", "vendor", "output", "compiler", "qbe", "stdlib", "runtime"):
        emit.add_argument("--" + key, required=True)
    verify = sub.add_parser("verify", help=argparse.SUPPRESS)
    verify.add_argument("--plan", required=True)
    verify.add_argument("--stamp", required=True)
    stage = sub.add_parser("stage", help=argparse.SUPPRESS)
    stage.add_argument("--source", required=True)
    stage.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        if args.action == "lock":
            lock_snapshot(args.snapshot, args.package, args.output)
        elif args.action == "query":
            print(json.dumps(load_lock(args.lock), indent=2, sort_keys=True))
        elif args.action == "vendor":
            vendor(load_lock(args.lock), args.directory, args.cache, args.offline)
        elif args.action == "status":
            verify_vendor(load_lock(args.lock), args.directory)
            print("All vendored sources match the lock.")
        elif args.action == "emit":
            emit_ninja(args.lock, args.vendor, args.output, args.compiler,
                       args.qbe, args.stdlib, args.runtime)
        elif args.action == "verify":
            verify_plan(args.plan, args.stamp)
        elif args.action == "stage":
            src, dest = Path(args.source), Path(args.output)
            dest.parent.mkdir(parents=True, exist_ok=True)
            if not dest.exists() or src.read_bytes() != dest.read_bytes():
                shutil.copyfile(src, dest)
        return 0
    except (PackageError, OSError, ValueError, KeyError, TypeError, tarfile.TarError) as exc:
        print(f"ocpkg: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
