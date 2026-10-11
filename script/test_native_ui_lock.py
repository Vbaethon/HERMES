#!/usr/bin/env python3
"""Exercise desktop-test contention and cancellation with disposable processes."""
import fcntl
import json
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
ENTRY = """import sys
from pathlib import Path
import native_ui_lock
native_ui_lock.LOCK_PATH = Path(sys.argv[1])
raise SystemExit(native_ui_lock.main(sys.argv[2:]))
"""


class NativeUILockTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hermes native lock ")
        self.addCleanup(temporary.cleanup)
        self.lock = Path(temporary.name) / "native-ui.lock"

    def start(self, program, *arguments):
        process = subprocess.Popen((sys.executable, "-c", program, *map(str, arguments)),
                                   cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        def cleanup():
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()
        self.addCleanup(cleanup)
        return process

    def line(self, process):
        self.assertTrue(select.select([process.stdout], [], [], 5)[0], "fixture produced no output")
        return process.stdout.readline().strip()

    def assert_unlocked(self):
        with self.lock.open("a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(stream, fcntl.LOCK_UN)

    def test_separate_entry_points_wait_then_enter_after_owner_releases(self):
        program = """from pathlib import Path
import sys
from native_ui_lock import native_ui_lock
with native_ui_lock(Path(sys.argv[1])):
    print('entered', flush=True)
    if len(sys.argv) > 2: input()
"""
        owner = self.start(program, self.lock, "hold")
        self.assertEqual(self.line(owner), "entered")
        contender = self.start(program, self.lock)
        self.assertTrue(self.line(contender).startswith("WAIT:"))
        self.assertIsNone(contender.poll())
        owner.stdin.write("release\n")
        owner.stdin.flush()
        self.assertEqual(owner.wait(timeout=5), 0)
        output, _ = contender.communicate(timeout=5)
        self.assertEqual(contender.returncode, 0)
        self.assertIn("entered", output)
        self.assert_unlocked()

    def test_failure_preserves_arguments_status_and_releases_slot(self):
        command = "import sys; print(sys.argv[1], flush=True); raise SystemExit(7)"
        process = self.start(ENTRY, self.lock, sys.executable, "-c", command, "literal spaces $() `text`")
        output, _ = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 7)
        self.assertIn("literal spaces $() `text`", output)
        self.assertNotIn("PASS:", output)
        self.assert_unlocked()

    def test_interrupt_stops_test_descendants_and_releases_slot(self):
        command = """import json, os, subprocess, sys, time
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
print(json.dumps([os.getpid(), child.pid]), flush=True)
time.sleep(30)
"""
        process = self.start(ENTRY, self.lock, sys.executable, "-c", command)
        descendants = json.loads(self.line(process))
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
        for pid in descendants:
            result = subprocess.run(("/bin/ps", "-p", str(pid), "-o", "stat="),
                                    capture_output=True, text=True)
            self.assertTrue(result.returncode != 0 or result.stdout.strip().startswith("Z"),
                            f"test descendant {pid} survived cancellation")
        self.assert_unlocked()


if __name__ == "__main__":
    unittest.main()
