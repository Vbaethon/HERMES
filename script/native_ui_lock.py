#!/usr/bin/env python3
"""Serialize HERMES native-window checks across entry points and worktrees."""
import argparse
from contextlib import contextmanager
import fcntl
from pathlib import Path
import subprocess
import sys
import time


LOCK_PATH = Path.home() / "Library/Caches/HERMESRegression/native-ui.lock"


@contextmanager
def native_ui_lock(path=None):
    path = Path(path) if path is not None else LOCK_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            started = time.monotonic()
            print("WAIT: another HERMES native-window check is running", flush=True)
            fcntl.flock(lock, fcntl.LOCK_EX)
            print(f"READY: native-window check slot ({time.monotonic() - started:.2f}s wait)", flush=True)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def main(argv=None):
    # Imported here so app_regression can use the lock without a circular import.
    from app_regression import catch_interruptions, run_process

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("provide a native-window test command")
    try:
        with catch_interruptions(), native_ui_lock():
            started = time.monotonic()
            run_process(command)
            print(f"PASS: native-window command ({time.monotonic() - started:.2f}s)", flush=True)
        return 0
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode > 0 else 128 - error.returncode
    except OSError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
