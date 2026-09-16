#!/usr/bin/env python3
"""Compile the current App sources and run offline model regressions in an isolated executable."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="hermes-model-safety-") as directory:
    temp = Path(directory)
    app = temp / "HermesApp.swift"
    # Keep all App declarations; only replace its entry point with the test main.
    app.write_text((root / "Sources/HermesApp.swift").read_text().replace("@main\n", "@MainActor\n", 1))
    sources = [str(p) for p in sorted((root / "Sources").rglob("*.swift")) if p.name not in {"tool.swift", "HermesApp.swift"}]
    binary = temp / "HermesModelSafetyRegression"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-target", "arm64-apple-macos27.0", *sources, str(app), str(root / "Tests/HermesModelRegression/RegressionMain.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(temp / "fixtures")], check=True, timeout=60)
