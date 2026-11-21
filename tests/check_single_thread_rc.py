"""Exercise the single-threaded runtime and reject a second native entrant."""

import resource
import signal
import subprocess
import sys
from pathlib import Path


def main() -> None:
    binary, cycle_fixture, expected = sys.argv[1:]
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    subprocess.run([binary], check=True, timeout=15)
    for action in ("foreign", "collect"):
        result = subprocess.run([binary, action], capture_output=True, timeout=15)
        if (result.returncode != -signal.SIGABRT
                or b"single-thread ARC runtime entered from another thread" not in result.stderr):
            raise SystemExit(
                f"{action}: expected the single-thread ARC diagnostic and SIGABRT, "
                f"got {result.returncode}: {result.stderr!r}"
            )
    stdout = subprocess.check_output([cycle_fixture], timeout=15)
    if stdout != Path(expected).read_bytes():
        raise SystemExit("inline reference counting changed cycle collection output")
    print("PASS single_thread_rc")


if __name__ == "__main__":
    main()
