#!/usr/bin/env python3
"""Exercise build/install failures in a copied project, never the installed app."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

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
import json, os, pathlib, sys
out = next(a.split("=", 1)[1] for a in sys.argv if a.startswith("CONFIGURATION_BUILD_DIR="))
with open(os.environ["HERMES_TEST_CALLS"], "a") as f:
    f.write(json.dumps({"output": out, "args": sys.argv[1:]}) + "\\n")
mode = os.environ.get("HERMES_TEST_BUILD_MODE", "success")
if mode == "fail": sys.exit(73)
if mode != "missing":
    app = pathlib.Path(out, "HERMES.app")
    app.mkdir(parents=True, exist_ok=True)
    (app / "compiled").write_text("new build")
''')
    compiler.chmod(0o755)
    for name, text in {
        "pgrep": '''#!/usr/bin/env python3
import os, pathlib, sys
state = os.environ.get("HERMES_TEST_RUNNING", "yes")
if state == "late":
    counter = pathlib.Path(os.environ["HERMES_TEST_ROOT"], "pgrep-count")
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    sys.exit(0 if count >= 2 else 1)
sys.exit(0 if state == "yes" else 1)
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
    env.pop("HERMES_BUILD_CONFIGURATION", None)
    env.pop("HERMES_TEST_UNSET_VALUE", None)
    installed = root / "Applications/HERMES.app"
    old_debug = root / "DerivedData/Build/Products/Debug/HERMES.app"
    old_debug.mkdir(parents=True)
    (old_debug / "existing").write_text("keep")
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
            copy_failure="", old_app=True, version_changed=False, retained_backup=False):
        before = project.read_bytes()
        (root / "pgrep-count").unlink(missing_ok=True)
        test_env = dict(env)
        test_env.update({"HERMES_TEST_RUNNING": running, "HERMES_TEST_BUILD_MODE": build_mode,
                         "HERMES_TEST_MOVE_FAILURE": move_failure, "HERMES_TEST_COPY_FAILURE": copy_failure})
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
        checks.append(args)
        return result

    reset_installation()
    run(["build.sh", "--release", "--no-run"])
    product = Path(calls()[-1]["output"])
    assert product.name.startswith("Release."), product
    assert "-xcconfig" not in calls()[-1]["args"]
    run(["build.sh"])
    run(["script/build_and_run.sh", "run"])
    run(["script/build_and_run.sh", "--verify"], expected=1)
    run(["script/package_app.sh", "--no-open", "--no-version-bump"], expected=1)
    calls_before = calls()
    run(["build.sh", "--clean", "--no-run"], expected=1)
    assert calls() == calls_before

    signing = root / "Signing.local.xcconfig"
    signing.write_text("CODE_SIGNING_ALLOWED = NO\n")
    run(["build.sh", "--release", "--no-run"])
    args = calls()[-1]["args"]
    assert args[args.index("-xcconfig") + 1] == str(signing), "Signing path lost spaces"
    run(["script/package_app.sh", "--no-open"], expected=1)
    args = calls()[-1]["args"]
    assert args[args.index("-xcconfig") + 1] == str(signing)
    signing.unlink()

    run(["script/package_app.sh", "--no-open"], expected=73, running="no", build_mode="fail")
    run(["script/package_app.sh", "--no-open"], expected=1, running="no", build_mode="missing")
    run(["script/package_app.sh", "--no-open"], expected=76, running="no", copy_failure="yes")
    run(["script/package_app.sh", "--no-open"], expected=74, running="no", move_failure="backup")
    run(["script/package_app.sh", "--no-open"], expected=74, running="no", move_failure="install")
    run(["script/package_app.sh", "--no-open"], expected=1, running="late")

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
    reset_installation()
    run(["script/package_app.sh", "--no-open", "--no-version-bump"], running="no", old_app=False)
    assert (installed / "compiled").is_file()

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
    print(f"PASS: {len(checks)} isolated build/install scenarios; Bash 3.2, version rollback, old-app recovery, running-app protection")
