#!/usr/bin/env python3
"""Verify cache invalidation, concurrency and fixture lifecycle without Xcode builds."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
from dataclasses import replace
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from app_regression import Compiler, ROOT, SUITES, run_suites

FAKE_PROGRAM = '''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
record = {"suite": os.environ["HERMES_REGRESSION_SUITE"], "args": sys.argv[1:],
          "executable": sys.argv[0], "tmp": os.environ["TMPDIR"], "pid": os.getpid()}
with open(os.environ["HERMES_CACHE_TEST_LOG"], "a") as stream:
    stream.write(json.dumps(record) + "\\n")
if "--fail" in sys.argv: sys.exit(9)
if "--hang" in sys.argv:
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    pathlib.Path(sys.argv[-1]).write_text(str(child.pid))
    time.sleep(30)
'''


class AppRegressionCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hermes cache safety ")
        self.addCleanup(temporary.cleanup)
        self.workspace = Path(temporary.name).resolve()
        self.root = self.workspace / "project with spaces"
        self.cache = self.workspace / "cache"
        (self.root / "Sources").mkdir(parents=True)
        self.app = self.root / "Sources/HermesApp.swift"
        self.app.write_text("@main\nenum HermesApp {}\n")
        for folder, entry, _, _ in SUITES.values():
            path = self.root / "Tests" / folder / "RegressionMain.swift"
            path.parent.mkdir(parents=True)
            path.write_text(f"@main enum {entry} {{}}\n")
        (self.root / "script").mkdir()
        (self.root / "script/AppRegressionMain.swift").write_bytes(
            (ROOT / "script/AppRegressionMain.swift").read_bytes())
        fake = self.workspace / "fake compiler.py"
        fake.write_text('''import json, pathlib, sys, time
args = sys.argv[1:]
with pathlib.Path(__file__).with_suffix(".calls").open("a") as stream:
    stream.write(json.dumps(args) + "\\n")
if any("FAIL" in pathlib.Path(a).read_text() for a in args if a.endswith(".swift")):
    print("fixture compiler failure")
    sys.exit(73)
time.sleep(0.05)
if "-c" in args:
    mapping = json.loads(pathlib.Path(args[args.index("-output-file-map") + 1]).read_text())
    for source, outputs in mapping.items():
        if source:
            pathlib.Path(outputs["object"]).write_text(pathlib.Path(source).read_text())
else:
    pathlib.Path(args[args.index("-o") + 1]).write_text(''' + repr(FAKE_PROGRAM) + ")\n")
        self.compiler = Compiler((sys.executable, str(fake)), "fixture Swift 1", "fixture SDK", "arm64-apple-macos27.0")
        self.calls = fake.with_suffix(".calls")
        self.runs = self.workspace / "runs.jsonl"
        environment = patch.dict(os.environ, {"HERMES_CACHE_TEST_LOG": str(self.runs)})
        environment.start()
        self.addCleanup(environment.stop)
        output = redirect_stdout(io.StringIO())
        output.__enter__()
        self.addCleanup(output.__exit__, None, None, None)

    def verify(self, suites=("model",), **kwargs):
        return run_suites(suites, root=kwargs.pop("root", self.root), cache=self.cache,
                          compiler=kwargs.pop("compiler", self.compiler), **kwargs)

    def compilation_count(self):
        return sum("-c" in json.loads(line) for line in self.calls.read_text().splitlines()) if self.calls.exists() else 0

    def assert_no_temporaries(self):
        self.assertFalse(list(self.cache.glob("hermes-app-regressions-*")))
        self.assertFalse(list((self.cache / "app-regression-build").glob(".compile-*")))

    def test_three_suites_share_one_build_and_each_run_is_isolated(self):
        result = self.verify(tuple(SUITES), arguments=("argument with spaces",))
        self.assertFalse(result["reused"])
        self.assertTrue(self.verify(("native",))["reused"])
        self.assertEqual(self.compilation_count(), 1)
        records = [json.loads(line) for line in self.runs.read_text().splitlines()]
        self.assertEqual([r["suite"] for r in records], ["model", "uiux", "native", "native"])
        self.assertEqual(len({r["executable"] for r in records}), 4)
        self.assertTrue(all(r["args"][1:] == ["argument with spaces"] for r in records[:3]))
        self.assertTrue(all(not Path(r["tmp"]).exists() and not Path(r["executable"]).exists() for r in records))
        self.assert_no_temporaries()

    def test_content_tests_source_set_flags_and_toolchain_invalidate_cache(self):
        self.verify(build_only=True)
        original_stat = self.app.stat()
        self.app.write_text(self.app.read_text().replace("HermesApp", "HermesNew"))
        os.utime(self.app, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        self.assertFalse(self.verify(build_only=True)["reused"])
        test = self.root / "Tests/HermesUIUXRegression/RegressionMain.swift"
        test.write_text(test.read_text() + "// changed check\n")
        self.assertFalse(self.verify(build_only=True)["reused"])
        added = self.root / "Sources/NewSource.swift"
        added.write_text("enum AdditionalSource {}\n")
        self.assertFalse(self.verify(build_only=True)["reused"])
        added.unlink()
        self.assertFalse(self.verify(build_only=True)["reused"])
        compiler = replace(self.compiler, target="x86_64-apple-macos27.0")
        self.assertFalse(self.verify(compiler=compiler, build_only=True)["reused"])
        compiler = replace(compiler, identity="fixture Swift 2")
        self.assertFalse(self.verify(compiler=compiler, build_only=True)["reused"])
        with patch.dict(os.environ, {"CPATH": "changed include path"}):
            self.assertFalse(self.verify(compiler=compiler, build_only=True)["reused"])
        self.assertEqual(self.compilation_count(), 8)
        self.assert_no_temporaries()

    def test_failed_compile_preserves_previous_cache_and_exit_status(self):
        self.verify(build_only=True)
        build = self.cache / "app-regression-build"
        before = {name: (build / name).read_bytes() for name in ("regression", "manifest.json")}
        original = self.app.read_text()
        self.app.write_text(original + "// FAIL\n")
        with self.assertRaises(subprocess.CalledProcessError) as failed:
            self.verify(build_only=True)
        self.assertEqual(failed.exception.returncode, 73)
        self.assertEqual(before, {name: (build / name).read_bytes() for name in before})
        self.assertFalse((build / "incremental").exists())
        self.app.write_text(original)
        self.assertTrue(self.verify(build_only=True)["reused"])
        self.assertEqual(self.compilation_count(), 2)
        self.assert_no_temporaries()

    def test_small_change_keeps_unchanged_snapshot_paths_and_timestamps(self):
        extra = self.root / "Sources/Other.swift"
        extra.write_text("enum Other {}\n")
        self.verify(build_only=True)
        snapshot = self.cache / "app-regression-build/incremental/sources/Sources/Other.swift"
        before = snapshot.stat().st_mtime_ns
        self.app.write_text(self.app.read_text() + "// changed entry\n")
        self.assertFalse(self.verify(build_only=True)["reused"])
        self.assertEqual(snapshot.stat().st_mtime_ns, before)
        self.assertEqual(snapshot.read_bytes(), extra.read_bytes())

    def test_source_set_and_toolchain_changes_remove_obsolete_intermediates(self):
        extra = self.root / "Sources/Old.swift"
        extra.write_text("enum Old {}\n")
        self.verify(build_only=True)
        workspace = self.cache / "app-regression-build/incremental"
        old = workspace / "objects/Sources/Old.swift.o"
        self.assertTrue(old.exists())
        extra.unlink()
        self.verify(build_only=True)
        self.assertFalse(old.exists())
        unrelated = workspace / "obsolete.o"
        unrelated.write_text("previous toolchain")
        self.verify(compiler=replace(self.compiler, identity="different compiler"), build_only=True)
        self.assertFalse(unrelated.exists())

    def test_corrupt_intermediate_is_discarded_before_a_changed_source_build(self):
        self.verify(build_only=True)
        workspace = self.cache / "app-regression-build/incremental"
        obj = workspace / "objects/Sources/HermesApp.swift.o"
        obj.write_text("corrupt intermediate")
        marker = workspace / "must-not-survive"
        marker.write_text("previous state")
        self.app.write_text(self.app.read_text() + "// new source bytes\n")
        self.verify(build_only=True)
        self.assertFalse(marker.exists())
        self.assertNotEqual(obj.read_text(), "corrupt intermediate")

    def test_linked_snapshot_is_discarded_without_overwriting_its_external_target(self):
        self.verify(build_only=True)
        outside = self.workspace / "outside.swift"
        outside.write_text("preserve external file\n")
        snapshot = self.cache / "app-regression-build/incremental/sources/Sources/HermesApp.swift"
        snapshot.unlink()
        snapshot.symlink_to(outside)
        self.app.write_text(self.app.read_text() + "// changed source\n")
        self.verify(build_only=True)
        self.assertEqual(outside.read_text(), "preserve external file\n")
        self.assertFalse(snapshot.is_symlink())

    def test_identical_sources_in_another_worktree_reuse_the_same_build(self):
        original = self.verify(build_only=True)
        other = self.workspace / "another worktree"
        shutil.copytree(self.root, other)
        reused = self.verify(root=other, build_only=True)
        self.assertTrue(reused["reused"])
        self.assertEqual(original["key"], reused["key"])
        self.assertEqual(self.compilation_count(), 1)

    def test_corrupt_or_missing_binary_is_recompiled(self):
        self.verify(build_only=True)
        binary = self.cache / "app-regression-build/regression"
        binary.write_text("damaged")
        self.assertFalse(self.verify(build_only=True)["reused"])
        binary.unlink()
        self.assertFalse(self.verify(build_only=True)["reused"])
        self.assertEqual(self.compilation_count(), 3)

    def test_concurrent_requests_compile_once(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(self.verify, build_only=True) for _ in range(2)]
            results = [future.result(timeout=10) for future in futures]
        self.assertEqual(sorted(result["reused"] for result in results), [False, True])
        self.assertEqual(self.compilation_count(), 1)
        self.assert_no_temporaries()

    def test_suite_failure_preserves_status_and_cleans_its_files(self):
        with self.assertRaises(subprocess.CalledProcessError) as failed:
            self.verify(arguments=("--fail",))
        self.assertEqual(failed.exception.returncode, 9)
        self.assert_no_temporaries()

    def test_preview_keeps_unique_bundle_and_arguments(self):
        self.verify(("native",), arguments=("--inspector-location-preview",))
        record = json.loads(self.runs.read_text().splitlines()[0])
        self.assertIn("HERMES Location Preview.app/Contents/MacOS/HermesNativeMediaRegression-", record["executable"])
        self.assertEqual(record["args"][1:], ["--inspector-location-preview"])
        self.verify(("uiux",), arguments=("--arrangement-preview",))
        record = json.loads(self.runs.read_text().splitlines()[1])
        self.assertIn("HERMES Arrangement Preview.app/Contents/MacOS/HermesUIUXRegression-", record["executable"])
        self.assertEqual(record["args"][1:], ["--arrangement-preview"])
        self.assert_no_temporaries()

    def test_timeout_stops_fixture_children_and_removes_temporaries(self):
        marker = self.workspace / "fixture child.pid"
        model = SUITES["model"]
        with patch.dict(SUITES, {"model": (*model[:3], 0.5)}):
            with self.assertRaises(subprocess.TimeoutExpired):
                self.verify(arguments=("--hang", str(marker)))
        pid = int(marker.read_text())
        state = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
        self.assertTrue(not state.stdout.strip() or state.stdout.strip().startswith("Z"), state.stdout)
        self.assert_no_temporaries()

    def test_interruption_cleans_the_running_suite_and_preserves_cache(self):
        marker = self.workspace / "interrupted child.pid"
        program = '''import sys
from pathlib import Path
from app_regression import Compiler, catch_interruptions, run_suites
compiler = Compiler((sys.executable, sys.argv[3]), "fixture Swift 1", "fixture SDK", "arm64-apple-macos27.0")
with catch_interruptions():
    run_suites(("model",), root=Path(sys.argv[1]), cache=Path(sys.argv[2]),
               compiler=compiler, arguments=("--hang", sys.argv[4]))
'''
        process = subprocess.Popen([sys.executable, "-c", program, str(self.root), str(self.cache),
                                    self.compiler.command[1], str(marker)], cwd=ROOT / "script",
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists(), "fixture did not start")
            process.terminate()
            _, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143, stderr)
            pid = int(marker.read_text())
            state = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
            self.assertTrue(not state.stdout.strip() or state.stdout.strip().startswith("Z"), state.stdout)
            self.assertTrue(self.verify(build_only=True)["reused"])
            self.assert_no_temporaries()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
