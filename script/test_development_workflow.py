#!/usr/bin/env python3
"""Exercise change selection and Debug output protection in disposable projects."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import check_change
from change_checks import ALL, APP, LAYOUT_CASES, commands, make_plan
import dev_build


class CheckSelectionTests(unittest.TestCase):
    def test_local_thumbnail_change_has_quick_layout_and_final_ui_integration(self):
        source = "Sources/Views/CollectionViews/ThumbnailGridZoomController.swift"
        quick = make_plan((source,))
        self.assertEqual(quick.checks, {"zoom"})
        self.assertEqual(quick.final_extra, {"layout", "uiux"})
        final = make_plan((source,), final=True)
        self.assertEqual(final.checks, {"layout", "uiux"})
        self.assertFalse(final.final_extra)

    def test_filtered_layout_cases_exist_and_final_complement_skips_the_passed_cases(self):
        for case in LAYOUT_CASES:
            text = (check_change.ROOT / "Tests/HermesLayoutTests" / f"{case}.swift").read_text()
            self.assertIn(f"class {case}: XCTestCase", text)
        quick = commands({"zoom"}, sys.executable)[0][1]
        self.assertIn("ThumbnailZoomTests", quick[-1])
        self.assertNotIn("ThumbnailAccessibilityTests", quick[-1])
        final = commands({"layout", "uiux"}, sys.executable, previously_checked={"zoom"})[0][1]
        self.assertIn("--skip", final)
        self.assertIn("ThumbnailZoomTests", final[-1])
        self.assertNotIn("ThumbnailAccessibilityTests", final[-1])

    def test_shared_model_and_media_changes_expand_but_prose_stays_small(self):
        model = make_plan(("Sources/Models/ImporterModel.swift",))
        self.assertEqual(model.checks, set(APP))
        self.assertEqual(model.final_extra, {"download", "tool", "composition", "metadata"})
        media = make_plan(("Sources/Utilities/FileSystemUtilities.swift",))
        self.assertTrue({"layout", "network", "model", "native", "download", "attribution"}.issubset(media.checks))
        documentation = make_plan(("AGENTS.md", "DEVELOPMENT.md", "Demos/ThumbnailZoom/NativePhotosFindings.txt"))
        self.assertFalse(documentation.checks)
        self.assertFalse(documentation.final_extra)

    def test_unknown_code_selects_full_offline_coverage(self):
        plan = make_plan(("Sources/NewResponsibility.swift", "script/new_pipeline.py"))
        self.assertEqual(plan.checks, set(ALL))
        self.assertEqual(len(plan.unknown), 2)

    def test_new_thumbnail_file_cannot_skip_compilation_outside_the_package_target(self):
        plan = make_plan(("Sources/Views/Thumbnail/NewComponent.swift",))
        self.assertEqual(plan.checks, set(ALL))
        self.assertEqual(plan.unknown, ("Sources/Views/Thumbnail/NewComponent.swift",))

    def test_demo_changes_build_the_actual_demo_in_addition_to_shared_component_tests(self):
        plan = make_plan(("Demos/LocationCard/LocationCardDemo.swift",))
        selected = commands(plan.checks, sys.executable)
        self.assertIn(("demo-location", ("/bin/zsh", "Demos/LocationCard/build.command", "--test")), selected)

    def test_all_existing_application_sources_have_a_known_responsibility(self):
        paths = [path.relative_to(check_change.ROOT).as_posix() for path in (check_change.ROOT / "Sources").rglob("*.swift")]
        self.assertFalse(make_plan(paths).unknown)

    def test_app_suites_compile_together_and_helper_precedes_composition(self):
        selected = commands({"model", "uiux", "native", "composition", "layout", "location", "network"}, sys.executable)
        apps = [command for name, command in selected if name == "app"]
        self.assertEqual(len(apps), 1)
        self.assertEqual(apps[0][-3:], APP)
        swift = [command for name, command in selected if name == "swift"]
        self.assertEqual(swift, [("xcrun", "swift", "test", "--filter", "HermesLayoutTests|HermesNetworkingTests")])
        names = [name for name, _ in selected]
        self.assertLess(names.index("tool"), names.index("composition"))


class GitSelectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hermes change checks ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.git("init", "-q")
        self.git("config", "user.name", "HERMES test")
        self.git("config", "user.email", "hermes-test@example.invalid")
        self.write(".gitignore", "ignored.swift\n.build/\n")
        self.write("Sources/Views/CollectionViews/ThumbnailZoomGeometry.swift", "enum Geometry {}\n")
        self.write("Sources/Models/ImporterModel.swift", "enum Model {}\n")
        self.write("说明 文件.md", "原文\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.base = check_change.resolve_base(self.root, "HEAD")
        output = redirect_stdout(io.StringIO())
        output.__enter__()
        self.addCleanup(output.__exit__, None, None, None)

    def git(self, *args):
        return check_change.git(self.root, *args)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def test_staged_unstaged_deleted_new_and_ignored_paths(self):
        self.write("说明 文件.md", "已暂存\n")
        self.git("add", "说明 文件.md")
        self.write("Sources/Models/ImporterModel.swift", "enum ChangedModel {}\n")
        (self.root / "Sources/Views/CollectionViews/ThumbnailZoomGeometry.swift").unlink()
        self.write("Sources/新 功能.swift", "enum Additional {}\n")
        self.write("ignored.swift", "ignored\n")
        paths = check_change.changed_paths(self.root, self.base)
        self.assertEqual(set(paths), {"说明 文件.md", "Sources/Models/ImporterModel.swift",
                                     "Sources/Views/CollectionViews/ThumbnailZoomGeometry.swift", "Sources/新 功能.swift"})

    def test_rename_considers_both_original_and_new_responsibilities(self):
        old = "Sources/Views/CollectionViews/ThumbnailZoomGeometry.swift"
        new = "迁移 后的代码.swift"
        self.git("mv", old, new)
        paths = check_change.changed_paths(self.root, self.base)
        self.assertEqual(set(paths), {old, new})
        self.assertEqual(make_plan(paths).checks, set(ALL))

    def test_base_includes_committed_branch_changes_and_current_edits(self):
        self.write("Sources/Models/ImporterModel.swift", "enum Committed {}\n")
        self.git("add", ".")
        self.git("commit", "-qm", "change")
        self.write("说明 文件.md", "工作区\n")
        self.assertEqual(set(check_change.changed_paths(self.root, self.base)),
                         {"Sources/Models/ImporterModel.swift", "说明 文件.md"})

    def test_paths_outside_workspace_are_rejected(self):
        for value in ("../elsewhere.swift", str(self.root.parent / "elsewhere.swift"), ".git/config"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                check_change.normalize_paths(self.root, (value,))

    def test_format_covers_untracked_text_without_reading_binary_as_text(self):
        self.write("新的 文档.md", "行末空白 \n")
        binary = self.root / "binary.bin"
        binary.write_bytes(b"\0\xff")
        with self.assertRaisesRegex(ValueError, "行末空白"):
            check_change.check_format(self.root, self.base, ("新的 文档.md", "binary.bin"))
        self.write("新的 文档.md", "修复\n")
        check_change.check_format(self.root, self.base, ("新的 文档.md", "binary.bin"))

    def test_default_cli_is_read_only_and_empty_worktree_runs_nothing(self):
        with patch.object(check_change, "ROOT", self.root), patch.object(check_change, "run_plan") as execute:
            self.assertEqual(check_change.main(["--run"]), 0)
            execute.assert_not_called()
            self.write("说明 文件.md", "修改\n")
            self.assertEqual(check_change.main([]), 0)
            execute.assert_not_called()

    def test_final_only_adds_integration_without_repeating_previous_specialist_checks(self):
        source = "Sources/Views/CollectionViews/ThumbnailZoomGeometry.swift"
        with patch.object(check_change, "ROOT", self.root), patch.object(check_change, "run_plan") as execute:
            self.assertEqual(check_change.main([source, "--final-only", "--run"]), 0)
        self.assertEqual(execute.call_args.args[2].checks, {"layout", "uiux"})
        self.assertEqual(execute.call_args.args[2].previously_checked, {"geometry"})

    def test_unknown_code_cannot_use_final_only_to_skip_full_coverage(self):
        with patch.object(check_change, "ROOT", self.root), patch.object(check_change, "run_plan") as execute:
            self.assertEqual(check_change.main(["Sources/NewCode.swift", "--final-only", "--run"]), 1)
            execute.assert_not_called()

    def test_failure_status_is_preserved_and_later_checks_do_not_run(self):
        marker = self.root / "should-not-run"
        selected = (("fail", (sys.executable, "-c", "raise SystemExit(7)")),
                    ("later", (sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", str(marker))))
        with patch.object(check_change, "ROOT", self.root), patch.object(check_change, "commands", return_value=selected):
            self.assertEqual(check_change.main(["说明 文件.md", "--run"]), 7)
        self.assertFalse(marker.exists())

    def test_source_changes_during_checks_invalidate_the_pass(self):
        source = self.root / "Sources/Models/ImporterModel.swift"
        command = (sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('enum New {}\\n')", str(source))
        with patch.object(check_change, "commands", return_value=(("fixture", command),)):
            with self.assertRaisesRegex(ValueError, "检查期间"):
                check_change.run_plan(self.root, self.base, make_plan(("说明 文件.md",)))


class DebugBuildTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hermes Debug workflow ")
        self.addCleanup(temporary.cleanup)
        self.workspace = Path(temporary.name).resolve()
        self.root = self.workspace / "first worktree"
        self.root.mkdir()
        self.calls = self.workspace / "calls.jsonl"
        builder = self.workspace / "fixture builder.py"
        builder.write_text('''import json, os, pathlib, subprocess, sys, time
products = pathlib.Path(os.environ["HERMES_PRODUCTS_DIR"])
record = {"products": str(products), "derived": os.environ["HERMES_DERIVED_DATA_DIR"],
          "configuration": os.environ["HERMES_BUILD_CONFIGURATION"], "arguments": sys.argv[1:],
          "started": time.monotonic(), "managed": os.environ.get("HERMES_MANAGED_PRODUCTS_DIR")}
record["active_protected"] = subprocess.run(
    ("/bin/bash", "-c", 'source "$HERMES_DEV_TEST_CONFIG_SOURCE"; managed_products_are_active "$HERMES_PRODUCTS_DIR"'),
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
time.sleep(0.05)
if os.environ.get("HERMES_DEV_TEST_FAIL"): sys.exit(73)
executable = products / "HERMES.app/Contents/MacOS/HERMES"
executable.parent.mkdir(parents=True, exist_ok=True)
executable.write_text("current Debug product")
record["finished"] = time.monotonic()
with pathlib.Path(os.environ["HERMES_DEV_TEST_LOG"]).open("a") as stream:
    stream.write(json.dumps(record) + "\\n")
''')
        self.environment = dict(os.environ, HERMES_DEV_TEST_PYTHON=sys.executable,
                                HERMES_DEV_TEST_BUILDER=str(builder), HERMES_DEV_TEST_LOG=str(self.calls),
                                HERMES_DEV_TEST_CONFIG_SOURCE=str(check_change.ROOT / "script/project_config.sh"),
                                ROOT_DIR=str(self.root),
                                HERMES_BUILD_CONFIGURATION="Release")
        for name in ("HERMES_PRODUCTS_DIR", "HERMES_MANAGED_PRODUCTS_DIR", "HERMES_DERIVED_DATA_DIR"):
            self.environment.pop(name, None)
        self.prepare_root(self.root)
        processes = patch.object(dev_build, "running_executables", return_value=())
        self.processes = processes.start()
        self.addCleanup(processes.stop)
        output = redirect_stdout(io.StringIO())
        output.__enter__()
        self.addCleanup(output.__exit__, None, None, None)

    def prepare_root(self, root):
        root.mkdir(parents=True, exist_ok=True)
        (root / "build.sh").write_text('#!/bin/bash\nset -eu\n"$HERMES_DEV_TEST_PYTHON" "$HERMES_DEV_TEST_BUILDER" "$@"\n')

    def build(self, root=None, **kwargs):
        return dev_build.build(root or self.root, environment=kwargs.pop("environment", self.environment), **kwargs)

    def records(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_same_worktree_reuses_debug_paths_and_other_worktree_is_independent(self):
        first = self.build(timing=True)
        self.assertEqual(first, self.build())
        other = self.workspace / "second worktree"
        self.prepare_root(other)
        self.assertNotEqual(first, self.build(other))
        records = self.records()
        self.assertEqual(records[0]["derived"], records[1]["derived"])
        self.assertNotEqual(records[0]["derived"], records[2]["derived"])
        self.assertTrue(all(record["configuration"] == "Debug" for record in records))
        self.assertEqual(records[0]["arguments"], ["--no-run", "--timing"])
        self.assertTrue(all(record["managed"] == record["products"] for record in records))
        self.assertTrue(all(record["active_protected"] for record in records))
        self.assertFalse(list(self.root.rglob(".hermes-active-build")))

    def test_running_candidate_is_not_overwritten(self):
        app = self.build()
        executable = app / "Contents/MacOS/HERMES"
        before = executable.read_bytes()
        self.processes.return_value = (executable,)
        with self.assertRaisesRegex(ValueError, "仍在运行"):
            self.build()
        self.assertEqual(executable.read_bytes(), before)
        self.assertEqual(len(self.records()), 1)

    def test_existing_installed_app_can_keep_running_while_debug_builds(self):
        self.processes.return_value = (Path("/Applications/HERMES.app/Contents/MacOS/HERMES"),)
        with patch.object(dev_build.subprocess, "run", wraps=subprocess.run) as execute:
            self.build(launch=True)
        self.assertFalse(any(call.args[0][0] == "/usr/bin/open" for call in execute.call_args_list))

    def test_custom_output_and_cache_paths_are_preserved(self):
        products = self.workspace / "custom output"
        products.mkdir()
        preserved = products / "user-owned.txt"
        preserved.write_text("retain")
        env = dict(self.environment, HERMES_PRODUCTS_DIR=str(products),
                   HERMES_DERIVED_DATA_DIR=str(self.workspace / "custom cache"), HERMES_MANAGED_PRODUCTS_DIR=str(products))
        self.build(environment=env)
        record = self.records()[0]
        self.assertEqual(record["products"], str(products))
        self.assertEqual(record["derived"], env["HERMES_DERIVED_DATA_DIR"])
        self.assertIsNone(record["managed"])
        self.assertEqual(preserved.read_text(), "retain")

    def test_unknown_product_ownership_is_rejected(self):
        products = self.build().parent
        (products / dev_build.MANAGED_MARKER).unlink()
        with self.assertRaisesRegex(ValueError, "归属"):
            self.build()
        self.assertEqual(len(self.records()), 1)

    def test_failed_build_preserves_status_cleans_marker_and_releases_lock(self):
        with self.assertRaises(subprocess.CalledProcessError) as failed:
            self.build(environment=dict(self.environment, HERMES_DEV_TEST_FAIL="yes"))
        self.assertEqual(failed.exception.returncode, 73)
        self.assertFalse(list(self.root.rglob(".hermes-active-build")))
        self.build()
        self.assertEqual(len(self.records()), 1)

    def test_simultaneous_builds_of_same_output_are_serialized(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            builds = [pool.submit(self.build) for _ in range(2)]
            self.assertEqual(builds[0].result(timeout=10), builds[1].result(timeout=10))
        first, second = self.records()
        self.assertLessEqual(first["finished"], second["started"])


if __name__ == "__main__":
    unittest.main()
