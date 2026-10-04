#!/usr/bin/env python3
"""Verify attribution on synthetic page snapshots and disposable local media."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = [root / "Sources" / name for name in (
    "dydl.swift", "rndl.swift", "dwdl.swift", "DewuLogStore.swift", "DownloaderHTTPCompatibility.swift", "UIModels.swift"
)]
# Collection-view resource actions are exercised by test_native_media.py.
sources += [path for path in sorted((root / "Sources/Utilities").glob("*.swift"))
            if path.name != "NativeMediaResources.swift"]
sources.append(root / "Tests/MediaAttributionRegression/main.swift")
with tempfile.TemporaryDirectory(prefix="hermes-attribution-test-") as directory:
    binary = Path(directory) / "regression"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    *map(str, sources), "-o", str(binary), "-lsqlite3"], check=True)
    subprocess.run([str(binary)], check=True, timeout=45)
