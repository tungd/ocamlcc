"""Exercise the single-threaded runtime and reject a second native entrant."""

import resource
import signal
import subprocess
import sys


def main() -> None:
    binary = sys.argv[1]
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    subprocess.run([binary], check=True, timeout=15)
    result = subprocess.run([binary, "foreign"], capture_output=True, timeout=15)
    if (result.returncode != -signal.SIGABRT
            or b"single-thread ARC runtime entered from another thread" not in result.stderr):
        raise SystemExit(
            f"expected the single-thread ARC diagnostic and SIGABRT, "
            f"got {result.returncode}: {result.stderr!r}"
        )
    print("PASS single_thread_rc")


if __name__ == "__main__":
    main()
