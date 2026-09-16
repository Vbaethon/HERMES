#!/usr/bin/env python3
"""Exercise build scripts with a fake compiler/process lookup, never the installed app."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="hermes-build-safety-") as folder:
    root = Path(folder)
    shutil.copy2(source / "build.sh", root / "build.sh")
    shutil.copytree(source / "script", root / "script")
    shutil.copytree(source / "HERMES.xcodeproj", root / "HERMES.xcodeproj")
    (root / "Build").mkdir()
    fake_bin = root / "bin"
    fake_bin.mkdir()
    developer_bin = root / "Developer/usr/bin"
    developer_bin.mkdir(parents=True)
    compiler = developer_bin / "xcodebuild"
    compiler.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
out = next(a.split("=", 1)[1] for a in sys.argv if a.startswith("CONFIGURATION_BUILD_DIR="))
pathlib.Path(out, "HERMES.app").mkdir(parents=True, exist_ok=True)
with open(os.environ["HERMES_TEST_CALLS"], "a") as f: f.write(out + "\\n")
''')
    compiler.chmod(0o755)
    for name, text in {
        "pgrep": "#!/bin/sh\nexit 0\n",
        "pkill": '#!/bin/sh\ntouch "$HERMES_TEST_KILLED"\nexit 0\n',
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
    })
    env.pop("HERMES_PRODUCTS_DIR", None)
    env.pop("HERMES_BUILD_CONFIGURATION", None)
    installed = root / "Applications/HERMES.app"
    installed.mkdir(parents=True)
    (installed / "existing").write_text("keep")
    old_debug = root / "DerivedData/Build/Products/Debug/HERMES.app"
    old_debug.mkdir(parents=True)
    (old_debug / "existing").write_text("keep")

    def run(args, expected=0):
        result = subprocess.run(["bash", *args], cwd=root, env=env, capture_output=True, text=True)
        assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
        assert not (root / "killed").exists(), "A script attempted to kill HERMES"
        assert (installed / "existing").read_text() == "keep"
        assert (old_debug / "existing").read_text() == "keep"

    run(["build.sh", "--release", "--no-run"])
    product = Path((root / "calls").read_text().splitlines()[-1])
    assert product.name.startswith("Release."), product
    run(["build.sh"])
    run(["script/build_and_run.sh", "run"])
    run(["script/build_and_run.sh", "--verify"], expected=1)
    run(["script/package_app.sh", "--no-open", "--no-version-bump"], expected=1)
    calls_before = (root / "calls").read_text()
    run(["build.sh", "--clean", "--no-run"], expected=1)
    assert (root / "calls").read_text() == calls_before
    print("PASS: 6 build/run/package/clean safety scenarios; existing app and products preserved")
