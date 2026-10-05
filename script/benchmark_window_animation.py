#!/usr/bin/env python3
"""Benchmark the full production HERMES window with read-only media.

Example:
  python3 script/benchmark_window_animation.py MEDIA_DIRECTORY --baseline HEAD \
      --output /tmp/hermes-window-animation.json

Both versions use the same 70-file manifest and all production Swift sources,
compiled with -O. Each run has a unique unbundled defaults domain. No downloader,
composer, importer, folder watcher, media write, or cache purge is invoked.
The first/revisit distinction is the process thumbnail cache, not a cleared OS
Quick Look cache. Callback gaps are responsiveness telemetry, never display FPS.
--wait-file SIGNAL compiles first, then waits for the caller's quiet-window signal.
--source-override Sources/FILE.swift=GIT_REF restores a file in the temporary
current source tree for controlled ablation, without editing production files.
Temporary sources, executables, manifests and child processes are always cleaned.
--output retains the report including every sampled pane/CA presentation width.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
MEDIA_EXTENSIONS = {"jpg", "jpeg", "jfif", "heic", "heif", "webp", "png", "mov", "mp4", "m4v"}


def run_process(command, *, cwd=None, timeout=180, capture=False):
    process = subprocess.Popen(command, cwd=cwd, start_new_session=True,
                               stdout=subprocess.PIPE if capture else None,
                               stderr=subprocess.PIPE if capture else None, text=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise
    if process.returncode:
        if capture:
            print(stdout or "", end="")
            print(stderr or "", end="", file=__import__("sys").stderr)
        raise subprocess.CalledProcessError(process.returncode, command)
    return stdout or ""


def closing_brace(source, opening):
    """Find a Swift function boundary, ignoring comments and quoted strings."""
    depth = 0
    index = opening
    state = None
    while index < len(source):
        pair = source[index:index + 2]
        character = source[index]
        if state == "line":
            if character == "\n":
                state = None
        elif state == "comment":
            if pair == "*/":
                state = None
                index += 1
        elif state == "string":
            if character == "\\":
                index += 1
            elif character == '"':
                state = None
        elif pair == "//":
            state = "line"
            index += 1
        elif pair == "/*":
            state = "comment"
            index += 1
        elif character == '"':
            state = "string"
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise ValueError("Unbalanced Swift function in instrumented source")


def instrument(relative, source):
    if relative.name == "ThumbnailService.swift":
        declaration = re.search(r"(?:private\s+)?(?:final\s+)?class ThumbnailFlowLayout: NSCollectionViewFlowLayout\s*\{", source)
        if declaration is None:
            raise ValueError("Expected production ThumbnailFlowLayout was not found")
        declaration_end = closing_brace(source, declaration.end() - 1)
        existing_prepare = re.search(r"override func prepare\(\)\s*\{", source[declaration.end():declaration_end])
        if existing_prepare:
            start = declaration.end() + existing_prepare.end()
            source = source[:start] + """
        let probeStarted = ProcessInfo.processInfo.systemUptime
        defer { WindowProbeCounters.recordPrepare(collectionView,
            milliseconds: (ProcessInfo.processInfo.systemUptime - probeStarted) * 1000) }
""" + source[start:]
        else:
            source = source[:declaration.end()] + """
    override func prepare() {
        let probeStarted = ProcessInfo.processInfo.systemUptime
        super.prepare()
        WindowProbeCounters.recordPrepare(collectionView,
            milliseconds: (ProcessInfo.processInfo.systemUptime - probeStarted) * 1000)
    }
""" + source[declaration.end():]
        function = source.index("override func shouldInvalidateLayout(forBoundsChange")
        opening = source.index("{", function)
        ending = closing_brace(source, opening)
        body = source[opening + 1:ending]
        source = source[:opening + 1] + "\n        return WindowProbeCounters.measureInvalidation(collectionView) {" + body + "\n        }\n    " + source[ending:]
    elif relative.name == "DownloadViews.swift":
        source = source.replace("glassSurface.cornerRadius = radius",
                                "WindowProbeCounters.measureGlassUpdate { glassSurface.cornerRadius = radius }")
        signature = "func reload() {\n        let rawLineCount = bounds.width > 0"
        source = source.replace(signature, """func reload() {
        let probeStarted = ProcessInfo.processInfo.systemUptime
        defer { WindowProbeCounters.record("download_input_reload",
            milliseconds: (ProcessInfo.processInfo.systemUptime - probeStarted) * 1000) }
        let rawLineCount = bounds.width > 0""", 1)
    elif relative.name == "SystemWindowBackgroundController.swift":
        for method in ["draw", "updateLayer"]:
            match = re.search(r"override func " + method + r"\([^\n]*\)\s*\{", source)
            if match:
                source = source[:match.end()] + f"""
        let probeStarted = ProcessInfo.processInfo.systemUptime
        defer {{ WindowProbeCounters.record("page_background_{method}",
            milliseconds: (ProcessInfo.processInfo.systemUptime - probeStarted) * 1000) }}
""" + source[match.end():]
    elif relative.name == "MainWindowController.swift":
        for pane in ["Inspector", "Sidebar"]:
            signature = f"override func toggle{pane}(_ sender: Any?) {{"
            source = source.replace(signature, signature + f'\n        WindowProbeCounters.recordPaneAction("{pane.lower()}", sender: sender)', 1)
    return source


def snapshot_sources(destination, revision=None, overrides=None):
    if revision is None:
        sources = [(path.relative_to(ROOT), path.read_text()) for path in sorted((ROOT / "Sources").rglob("*.swift"))]
    else:
        commit = subprocess.check_output(["git", "rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], cwd=ROOT, text=True).strip()
        names = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", commit, "Sources"], cwd=ROOT, text=True).splitlines()
        sources = [(Path(name), subprocess.check_output(["git", "show", f"{commit}:{name}"], cwd=ROOT, text=True))
                   for name in names if name.endswith(".swift")]
    paths = []
    digests = {}
    for relative, source in sources:
        if relative.name == "tool.swift":
            continue
        if revision is None and overrides and str(relative) in overrides:
            commit = overrides[str(relative)]
            source = subprocess.check_output(["git", "show", f"{commit}:{relative}"], cwd=ROOT, text=True)
        digests[str(relative)] = hashlib.sha256(source.encode()).hexdigest()
        if relative.name == "HermesApp.swift":
            source = source.replace("@main\n", "@MainActor\n", 1)
        source = instrument(relative, source)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)
        paths.append(target)
    return paths, digests


def media_revision(path):
    status = path.stat()
    return [status.st_dev, status.st_ino, status.st_size, status.st_mtime_ns, status.st_ctime_ns]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--baseline", help="Git revision to compare with the current working tree")
    parser.add_argument("--source-override", action="append", default=[], metavar="SOURCE=GIT_REF",
                        help="Restore a production file from Git in the temporary current tree only")
    parser.add_argument("--label", default="current", help="Label the current/ablated fixture variant")
    parser.add_argument("--limit", type=int, default=70)
    parser.add_argument("--widths", type=float, nargs="+", default=[1200, 1440])
    parser.add_argument("--toggle-count", type=int, default=6)
    parser.add_argument("--scroll-seconds", type=float, default=2)
    parser.add_argument("--startup-delay", type=float, default=0, help="Allow a profiler to attach after the fixture window opens")
    parser.add_argument("--wait-file", type=Path, help="Wait for this new signal file after compiling both versions")
    parser.add_argument("--output", type=Path, help="Retain full JSON including each callback's pane width samples")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.label) or (args.baseline and args.label == "baseline"):
        parser.error("--label must be a distinct name using letters, digits, underscores or hyphens")
    directory = args.directory.resolve()
    if not directory.is_dir() or args.limit < 1 or args.toggle_count < 2 or args.toggle_count % 2:
        parser.error("Use an existing media directory, a positive limit, and a positive even toggle count")
    if any(width < 1000 for width in args.widths) or args.scroll_seconds <= 0 or args.startup_delay < 0:
        parser.error("Widths must be at least 1000; scroll duration positive and startup delay nonnegative")
    files = sorted(path for path in directory.iterdir()
                   if path.is_file() and path.suffix.lower().lstrip(".") in MEDIA_EXTENSIONS)[:args.limit]
    if len(files) < args.limit:
        parser.error(f"Expected {args.limit} read-only media files, found {len(files)}; use --limit to choose a smaller fixture")
    if args.wait_file and args.wait_file.exists():
        parser.error("--wait-file must name a new signal file")
    overrides = {}
    for value in args.source_override:
        relative, separator, revision = value.partition("=")
        path = Path(relative)
        if not separator or not revision or not path.parts or path.is_absolute() or ".." in path.parts or path.parts[0] != "Sources" or path.suffix != ".swift":
            parser.error("--source-override requires a repository Sources/*.swift path and Git revision")
        overrides[str(path)] = subprocess.check_output(["git", "rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], cwd=ROOT, text=True).strip()
    revisions = {str(path): media_revision(path) for path in files}
    baseline_commit = subprocess.check_output(["git", "rev-parse", "--verify", "--end-of-options", args.baseline + "^{commit}"],
                                              cwd=ROOT, text=True).strip() if args.baseline else None
    report = {"schema": 1, "measurement": "Callback gaps and CPU work, not display FPS",
              "media_directory": str(directory), "source_files": list(revisions),
              "optimized": True, "baseline": args.baseline, "baseline_commit": baseline_commit, "runs": []}
    report["source_overrides"] = overrides
    variants = [("baseline", baseline_commit)] if args.baseline else []
    variants.append((args.label, None))
    with tempfile.TemporaryDirectory(prefix="hermes-window-animation-") as temporary:
        temporary = Path(temporary)
        # Freeze the harness and both source trees before any compiler starts.
        # An edit in the shared checkout cannot change one half of an A/B run.
        harness = temporary / "WindowAnimationBenchmark.swift"
        harness.write_text((ROOT / "script/benchmark_window_animation.swift").read_text())
        report["harness_sha256"] = hashlib.sha256(harness.read_bytes()).hexdigest()
        builds = []
        snapshots = []
        for label, revision in variants:
            build = temporary / label
            sources, digests = snapshot_sources(build, revision, overrides)
            binary = build / f"HermesWindowAnimationProbe-{uuid.uuid4().hex}"
            manifest = build / "fixture.json"
            manifest.write_text(json.dumps({"directory": str(directory), "files": list(revisions),
                                           "widths": args.widths, "toggleCount": args.toggle_count,
                                           "scrollSeconds": args.scroll_seconds, "startupDelay": args.startup_delay,
                                           "label": label}))
            builds.append((label, binary, manifest))
            snapshots.append((label, sources, binary, digests))
        report["builds"] = [{"label": label, "production_source_sha256": digests}
                            for label, _, _, digests in snapshots]
        for label, sources, binary, _ in snapshots:
            run_process(["xcrun", "swiftc", "-j", "4", "-O", "-g", "-suppress-warnings",
                         "-swift-version", "6", "-parse-as-library",
                         "-target", f"{platform.machine()}-apple-macos27.0", *map(str, sources),
                         str(harness), "-o", str(binary)])
            print(f"COMPILED {label}: {binary}", flush=True)
        if args.wait_file:
            print(f"READY: waiting for {args.wait_file}", flush=True)
            deadline = time.monotonic() + 600
            while not args.wait_file.exists():
                if time.monotonic() > deadline:
                    raise TimeoutError("Quiet-window signal did not arrive within ten minutes")
                time.sleep(0.1)
        for label, binary, manifest in builds:
            stdout = run_process([str(binary), str(manifest)], timeout=180, capture=True)
            records = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
            phases = [record for record in records if record.get("event") == "phase"]
            valid = bool(phases) and all(record.get("valid") for record in phases)
            report["runs"].append({"label": label, "records": records, "valid": valid})
            for record in records:
                print(json.dumps({key: value for key, value in record.items() if key != "width_samples"}, sort_keys=True), flush=True)
            changed = [str(path) for path in files if media_revision(path) != revisions[str(path)]]
            if changed:
                raise RuntimeError("Read-only media revisions changed during the probe: " + ", ".join(changed))
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(f"REPORT {args.output.resolve()}", flush=True)
    else:
        print("Use --output to retain individual width/presentation samples.", flush=True)
    if any(not result["valid"] for result in report["runs"]):
        raise SystemExit("INVALID: input or unexpected window/pane changes contaminated a measured phase; inspect the retained report")


if __name__ == "__main__":
    main()
