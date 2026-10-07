#!/usr/bin/env python3
"""Exercise build/install failures in a copied project, never the installed app."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time

source = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="hermes build safety-", dir="/tmp") as folder:
    root = Path(folder).resolve()
    shutil.copy2(source / "build.sh", root / "build.sh")
    shutil.copytree(source / "script", root / "script")
    shutil.copytree(source / "HERMES.xcodeproj", root / "HERMES.xcodeproj")
    project = root / "HERMES.xcodeproj/project.pbxproj"
    original_project = project.read_bytes()
    (root / "Build").mkdir()
    fake_bin = root / "bin"
    fake_bin.mkdir()
    developer_bin = root / "Developer/usr/bin"
    developer_bin.mkdir(parents=True)
    compiler = developer_bin / "xcodebuild"
    compiler.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, time
out = next(a.split("=", 1)[1] for a in sys.argv if a.startswith("CONFIGURATION_BUILD_DIR="))
with open(os.environ["HERMES_TEST_CALLS"], "a") as f:
    f.write(json.dumps({"output": out, "args": sys.argv[1:]}) + "\\n")
mode = os.environ.get("HERMES_TEST_BUILD_MODE", "success")
if mode == "fail": sys.exit(73)
if mode != "missing":
    app = pathlib.Path(out, "HERMES.app")
    app.mkdir(parents=True, exist_ok=True)
    (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.codex.Hermes</string></dict></plist>')
    (app / "compiled").write_text("new build")
if mode == "block":
    pathlib.Path(os.environ["HERMES_TEST_BLOCK_READY"]).write_text(out)
    gate = pathlib.Path(os.environ["HERMES_TEST_BLOCK_GATE"])
    deadline = time.monotonic() + 20
    while not gate.exists():
        if time.monotonic() > deadline: sys.exit(77)
        time.sleep(0.01)
''')
    compiler.chmod(0o755)
    for name, text in {
        "pgrep": '''#!/usr/bin/env python3
import os, pathlib, sys
state = os.environ.get("HERMES_TEST_RUNNING", "yes")
if state in {"late", "staging"}:
    counter = pathlib.Path(os.environ["HERMES_TEST_ROOT"], "pgrep-count")
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    threshold = 2 if state == "late" else 3
    if count >= threshold: print("424242")
    sys.exit(0 if count >= threshold else 1)
if state == "yes": print("424242")
sys.exit(0 if state == "yes" else 1)
''',
        "ps": '''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
if sys.argv[-1] == "lstart=":
    sys.exit(subprocess.call(["/bin/ps", *sys.argv[1:]]))
print(os.environ.get("HERMES_TEST_PROCESS_PATH", str(pathlib.Path(os.environ["HERMES_TEST_ROOT"], "Running/HERMES.app/Contents/MacOS/HERMES"))))
''',
        "pkill": '#!/bin/sh\ntouch "$HERMES_TEST_KILLED"\nexit 0\n',
        "mv": '''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
source, destination = map(pathlib.Path, sys.argv[-2:])
mode = os.environ.get("HERMES_TEST_MOVE_FAILURE", "")
install = source.name.startswith(".HERMES.installing.")
backup = destination.name.startswith(".HERMES.previous.")
restore = source.name.startswith(".HERMES.previous.")
if (install and mode in {"install", "install-and-restore"}) or (backup and mode == "backup"):
    sys.exit(74)
if restore and mode == "install-and-restore": sys.exit(75)
sys.exit(subprocess.call([os.environ["HERMES_TEST_REAL_MV"], *sys.argv[1:]]))
''',
        "ditto": '''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
destination = pathlib.Path(sys.argv[-1])
if destination.name.startswith(".HERMES.installing.") and os.environ.get("HERMES_TEST_COPY_FAILURE"):
    destination.mkdir(parents=True)
    (destination / "partial").write_text("incomplete copy")
    sys.exit(76)
sys.exit(subprocess.call(["/usr/bin/ditto", *sys.argv[1:]]))
''',
    }.items():
        path = fake_bin / name
        path.write_text(text)
        path.chmod(0o755)
    env = dict(os.environ)
    env.update({
        "PATH": str(fake_bin) + ":" + env["PATH"],
        "DEVELOPER_DIR": str(root / "Developer"),
        "HERMES_DERIVED_DATA_DIR": str(root / "DerivedData"),
        "HERMES_INSTALL_DIR": str(root / "Applications"),
        "HERMES_TEST_CALLS": str(root / "calls"),
        "HERMES_TEST_KILLED": str(root / "killed"),
        "HERMES_TEST_ROOT": str(root),
        "HERMES_TEST_REAL_MV": shutil.which("mv", path="/usr/bin:/bin"),
    })
    env.pop("HERMES_PRODUCTS_DIR", None)
    env.pop("HERMES_MANAGED_PRODUCTS_DIR", None)
    env.pop("HERMES_BUILD_CONFIGURATION", None)
    env.pop("HERMES_TEST_UNSET_VALUE", None)
    installed = root / "Applications/HERMES.app"
    old_debug = root / "DerivedData/Build/Products/Debug/HERMES.app"
    old_debug.mkdir(parents=True)
    (old_debug / "existing").write_text("keep")
    (root / "Running/HERMES.app/Contents/MacOS").mkdir(parents=True)
    checks = []

    def reset_installation(existing=True):
        project.write_bytes(original_project)
        installed.parent.mkdir(exist_ok=True)
        for app in installed.parent.glob("*.app"):
            shutil.rmtree(app)
        if existing:
            installed.mkdir()
            (installed / "existing").write_text("keep")

    def calls():
        path = root / "calls"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def run(args, expected=0, *, running="yes", build_mode="success", move_failure="",
            copy_failure="", old_app=True, version_changed=False, retained_backup=False,
            products_override=None, process_path=None, retained_staging=False):
        before = project.read_bytes()
        calls_before = len(calls())
        managed_before = set((root / "DerivedData/Build/Products").glob("*/.hermes-managed-products"))
        (root / "pgrep-count").unlink(missing_ok=True)
        test_env = dict(env)
        test_env.update({"HERMES_TEST_RUNNING": running, "HERMES_TEST_BUILD_MODE": build_mode,
                         "HERMES_TEST_MOVE_FAILURE": move_failure, "HERMES_TEST_COPY_FAILURE": copy_failure})
        if products_override is not None:
            test_env["HERMES_PRODUCTS_DIR"] = str(products_override)
        if process_path is not None:
            test_env["HERMES_TEST_PROCESS_PATH"] = str(process_path)
        result = subprocess.run(["/bin/bash", *args], cwd=root, env=test_env,
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        assert not (root / "killed").exists(), "A script attempted to kill HERMES"
        assert (old_debug / "existing").read_text() == "keep"
        assert (project.read_bytes() != before) == version_changed, "Wrong project-version transaction"
        if old_app:
            assert (installed / "existing").read_text() == "keep", "Previous installation was lost"
        backups = list(installed.parent.glob(".HERMES.previous.*.app"))
        assert bool(backups) == retained_backup, backups
        assert not list(installed.parent.glob(".HERMES.installing.*.app"))
        assert not list((root / "Build").glob("project.pbxproj.prebuild.*"))
        assert (root / "Build/HERMES.app").exists() == retained_staging, "Wrong legacy staging retention"
        if products_override is None:
            if args[0] == "script/package_app.sh" or expected != 0:
                if len(calls()) > calls_before:
                    assert not Path(calls()[-1]["output"]).exists(), "Failed or installed build products were retained"
                managed_after = set((root / "DerivedData/Build/Products").glob("*/.hermes-managed-products"))
                assert not managed_after - managed_before, "An early failure retained a product directory"
        checks.append(args)
        return result

    reset_installation()
    run(["build.sh", "--release", "--no-run"])
    product = Path(calls()[-1]["output"])
    assert product.name.startswith("Release."), product
    assert "-xcconfig" not in calls()[-1]["args"]
    run(["build.sh"])
    assert not product.exists(), "A previous build was retained while the installed app was running"
    run(["script/build_and_run.sh", "run"])
    run(["script/build_and_run.sh", "--verify"], expected=1)
    calls_before = calls()
    run(["script/package_app.sh", "--no-open", "--no-version-bump"], expected=1)
    run(["script/package_app.sh", "--no-open"], expected=1)
    assert calls() == calls_before, "Packaging compiled despite a running app"
    calls_before = calls()
    run(["build.sh", "--clean", "--no-run"], expected=1)
    assert calls() == calls_before
    run(["script/package_app.sh", "--help"])
    run(["script/package_app.sh", "--invalid"], expected=2)

    def concurrent_build(args, label):
        ready = root / f"{label}-ready"
        gate = root / f"{label}-gate"
        concurrent_env = dict(env)
        concurrent_env.update({"HERMES_TEST_RUNNING": "yes", "HERMES_TEST_BUILD_MODE": "block",
                               "HERMES_TEST_BLOCK_READY": str(ready), "HERMES_TEST_BLOCK_GATE": str(gate)})
        process = subprocess.Popen(["/bin/bash", *args], cwd=root, env=concurrent_env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists():
                assert process.poll() is None, "Concurrent compiler exited before blocking"
                assert time.monotonic() < deadline, "Concurrent compiler did not become ready"
                time.sleep(0.01)
            active_products = Path(ready.read_text())
            run(["build.sh", "--no-run"])
            assert active_products.exists(), "A concurrent successful build removed active compiler output"
            run(["build.sh", "--clean", "--no-run"], expected=1, running="no")
            assert active_products.exists(), "Clean removed a concurrent compiler output"
            gate.write_text("finish")
            stdout, stderr = process.communicate(timeout=30)
            assert process.returncode == 0, (args, process.returncode, stdout, stderr)
            assert active_products.exists(), "The completed build lost its current output"
            run(["build.sh", "--no-run"])
            assert not active_products.exists(), "A completed obsolete build was retained"
            checks.append(args)
        finally:
            if process.poll() is None:
                gate.write_text("finish")
                process.communicate(timeout=30)

    concurrent_build(["build.sh", "--no-run"], "direct")
    concurrent_build(["script/build_and_run.sh", "run"], "wrapper")

    def old_product(name, bundle_id="com.codex.Hermes"):
        directory = root / "DerivedData/Build/Products" / name
        contents = directory / "HERMES.app/Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle_id}))
        (directory / "existing").write_text("keep")
        return directory

    running_product = old_product("Debug.abc123")
    obsolete_product = old_product("Release.abc124")
    unrelated_product = old_product("Release.abc125", "com.example.Other")
    linked_product = root / "DerivedData/Build/Products/Debug.abc126"
    linked_product.symlink_to(running_product, target_is_directory=True)
    run(["build.sh", "--no-run"], process_path=running_product / "HERMES.app/Contents/MacOS/HERMES")
    assert running_product.exists(), "A running test app was removed"
    assert not obsolete_product.exists(), "Legacy default products were not removed"
    assert unrelated_product.exists(), "An unrelated app directory was removed"
    assert linked_product.is_symlink(), "A user symlink was removed"

    unresolved_product = old_product("Release.xyz123")
    run(["build.sh", "--no-run"], process_path="unresolved")
    assert unresolved_product.exists(), "An unresolved running app path was not protected"
    run(["build.sh", "--no-run"])
    assert not unresolved_product.exists(), "Known installed-app paths prevented old-product cleanup"

    custom_product = old_product("Release.custom")
    run(["build.sh", "--no-run"], products_override=custom_product)
    assert custom_product.exists(), "A custom products directory was removed"
    run(["build.sh", "--no-run"])
    assert custom_product.exists(), "A previous custom products directory was pruned"
    nested_parent = old_product("Debug.nest12")
    nested_custom = nested_parent / "User Output"
    run(["build.sh", "--no-run"], products_override=nested_custom)
    run(["build.sh", "--no-run"])
    assert nested_custom.exists(), "Pruning removed a parent containing custom products"
    run(["build.sh", "--no-run"], expected=73, build_mode="fail", products_override=custom_product)
    assert custom_product.exists(), "A failed build removed its custom products directory"
    run(["script/build_and_run.sh", "run"], expected=73, build_mode="fail")
    run(["build.sh", "--clean", "--no-run"], expected=1, running="no")
    assert custom_product.exists(), "Clean removed a custom products directory"

    signing = root / "Signing.local.xcconfig"
    signing.write_text("CODE_SIGNING_ALLOWED = NO\n")
    run(["build.sh", "--release", "--no-run"])
    args = calls()[-1]["args"]
    assert args[args.index("-xcconfig") + 1] == str(signing), "Signing path lost spaces"
    run(["script/package_app.sh", "--no-open"], expected=1, running="no", build_mode="missing")
    args = calls()[-1]["args"]
    assert args[args.index("-xcconfig") + 1] == str(signing)
    signing.unlink()

    run(["script/package_app.sh", "--no-open"], expected=73, running="no", build_mode="fail")
    run(["script/package_app.sh", "--no-open"], expected=1, running="no", build_mode="missing")
    run(["script/package_app.sh", "--no-open"], expected=76, running="no", copy_failure="yes")
    run(["script/package_app.sh", "--no-open"], expected=74, running="no", move_failure="backup")
    run(["script/package_app.sh", "--no-open"], expected=74, running="no", move_failure="install")
    run(["script/package_app.sh", "--no-open"], expected=1, running="late")
    run(["script/package_app.sh", "--no-open"], expected=1, running="staging")

    # Inject the same class of real shell expansion fault after the version bump.
    # A compiler returning nonzero cannot reproduce Bash 3.2's EXIT status of 0 here.
    package = root / "script/package_app.sh"
    package_source = package.read_text()
    compiler_command = 'DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" "$XCODEBUILD" '
    assert package_source.count(compiler_command) == 1
    package.write_text(package_source.replace(compiler_command,
                       ': "${HERMES_TEST_UNSET_VALUE}"\n' + compiler_command, 1))
    try:
        result = run(["script/package_app.sh", "--no-open"], expected=1, running="no")
        assert "unbound variable" in result.stderr
    finally:
        package.write_text(package_source)

    run(["script/package_app.sh", "--no-open"], running="no", old_app=False, version_changed=True)
    assert (installed / "compiled").read_text() == "new build"
    assert not (installed / "existing").exists()
    shutil.copytree(installed, root / "Build/HERMES.app")
    reset_installation()
    run(["script/package_app.sh", "--no-open", "--no-version-bump"], running="no", old_app=False)
    assert (installed / "compiled").is_file()
    assert not list((root / "DerivedData/Build/Products").glob("*/.hermes-managed-products")), "Installed builds retained intermediate products"

    reset_installation()
    run(["script/package_app.sh", "--no-open", "--no-version-bump"], running="no", old_app=False,
        products_override=custom_product)
    assert (custom_product / "HERMES.app/compiled").is_file(), "Packaging removed custom build products"

    reset_installation(existing=False)
    run(["script/package_app.sh", "--no-open"], expected=74, running="no",
        move_failure="install", old_app=False)
    assert not installed.exists()
    run(["script/package_app.sh", "--no-open"], running="no", old_app=False, version_changed=True)
    assert (installed / "compiled").is_file()

    reset_installation()
    run(["script/package_app.sh", "--no-open"], expected=1, running="no",
        move_failure="install-and-restore", old_app=False, retained_backup=True)
    backup = next(installed.parent.glob(".HERMES.previous.*.app"))
    assert (backup / "existing").read_text() == "keep"

    reset_installation()
    run(["script/package_app.sh", "--no-open", "--no-version-bump"], running="no", old_app=False,
        products_override=root / "Build", retained_staging=True)
    assert (root / "Build/HERMES.app/compiled").is_file(), "Legacy staging cleanup removed custom products"
    print(f"PASS: {len(checks)} isolated build/install scenarios; Bash 3.2, version rollback, recovery, retention, concurrent-build and running-app protection")
