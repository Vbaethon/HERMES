#!/usr/bin/env python3
"""Exercise native media inspection and complete-resource transfers in isolation."""
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
cache = Path.home() / "Library/Caches/HERMESRegression"
cache.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="hermes-native-media-", dir=cache) as directory:
    temp = Path(directory)
    app = temp / "HermesApp.swift"
    app.write_text(
        (root / "Sources/HermesApp.swift").read_text().replace("@main\n", "@MainActor\n", 1)
    )
    sources = [
        str(path)
        for path in sorted((root / "Sources").rglob("*.swift"))
        if path.name not in {"tool.swift", "HermesApp.swift"}
    ]
    # An unbundled executable uses its process name as the standard defaults
    # domain. Give each invocation a unique domain, never the installed app's.
    binary = temp / f"HermesNativeMediaRegression-{uuid.uuid4().hex}"
    subprocess.run(
        [
            "xcrun", "swiftc", "-j", "4", "-swift-version", "6", "-parse-as-library",
            "-target", "arm64-apple-macos27.0", *sources, str(app),
            str(root / "Tests/HermesNativeMediaRegression/RegressionMain.swift"),
            "-o", str(binary),
        ],
        check=True,
    )
    subprocess.run([str(binary), str(temp / "fixtures"), *sys.argv[1:]], check=True, timeout=90)
