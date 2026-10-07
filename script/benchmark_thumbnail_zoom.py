#!/usr/bin/env python3
"""Measure native thumbnail zoom CPU work using synthetic, controlled artwork.

python3 script/benchmark_thumbnail_zoom.py --counts 70 1500 --baseline HEAD \
    --output /tmp/hermes-thumbnail-zoom.json

The optimized probe opens an isolated NSWindow/NSCollectionView and exercises
all six adjacent 9/7/5/3 transitions through the production gesture methods.
Temporary production copies are instrumented, and their thumbnail provider is
replaced only in the probe with generated CGImages. No real media, application
defaults, importer, download records, or production source files are touched.
Synchronous submission times and AppKit callback gaps are NOT display FPS.
Each item count starts with a fresh controller and a new synthetic URL prefix.
The first measured 5→3 gesture has no prior zoom-cache preparation; the next
matching gesture measures its warm revisit. Native visible-cell artwork is
allowed to finish loading before both, so this does not simulate empty cells.
Use --cold-warm-only to run only those two phases per item count.
Use --compile-only to validate the harness without opening a window, or
--wait-file NEW_SIGNAL to compile before waiting for a quiet-window signal.
All temporary sources, executables and child processes are cleaned on exit.
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
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Sources/UIModels.swift", "Sources/Utilities/FileSystemUtilities.swift",
    "Sources/Utilities/NativeMediaResources.swift",
    "Sources/Views/CollectionViews/ThumbnailGridController.swift",
    "Sources/Views/CollectionViews/ThumbnailGridZoomController.swift",
    "Sources/Views/CollectionViews/ThumbnailZoomGeometry.swift",
    "Sources/Views/CollectionViews/ThumbnailZoomOverlay.swift",
    "Sources/Views/Thumbnail/ThumbnailService.swift",
    "Sources/Views/Thumbnail/ThumbnailItemViews.swift",
    "Sources/Views/Thumbnail/ThumbnailCompositionEffect.swift",
    "Sources/Views/Thumbnail/SystemThumbnailProvider.swift",
]


def run_process(command, *, timeout=180, capture=False):
    process = subprocess.Popen(command, cwd=ROOT, start_new_session=True,
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
            print(stderr or "", end="", file=sys.stderr)
        raise subprocess.CalledProcessError(process.returncode, command)
    return stdout or ""


def instrument(source, signature, key, *, assume_main=False):
    matches = list(re.finditer(signature, source))
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one {key} method, found {len(matches)}")
    start = matches[0].end()
    record = f'ZoomProbeCounters.record("{key}", milliseconds: (ProcessInfo.processInfo.systemUptime - zoomProbeStarted) * 1000)'
    if assume_main:
        record = "MainActor.assumeIsolated { " + record + " }"
    return source[:start] + f"""
        let zoomProbeStarted = ProcessInfo.processInfo.systemUptime
        defer {{ {record} }}
""" + source[start:]


def snapshot_sources(destination, revision):
    paths, digests = [], {}
    for relative in SOURCES:
        source = ((ROOT / relative).read_text() if revision is None else
                  subprocess.check_output(["git", "show", f"{revision}:{relative}"], cwd=ROOT, text=True))
        digests[relative] = hashlib.sha256(source.encode()).hexdigest()
        name = Path(relative).name
        if name == "SystemThumbnailProvider.swift":
            old = "static let shared = SystemThumbnailProvider()"
            if source.count(old) != 1:
                raise ValueError("Expected shared synthetic-provider substitution point")
            source = source.replace(old, "static let shared = SystemThumbnailProvider(loader: ZoomProbeArtwork.load)")
        if name == "ThumbnailGridZoomController.swift":
            methods = {
                "plan_prepare": r"private func preparePlan\([^\n]*\)\s*\{",
                "gesture_begin": r"func beginGesture\([^\n]*\)\s*\{",
                "gesture_change": r"func changeGesture\([^\n]*\)\s*\{",
                "release_clock_tick": r"func advanceAnimation\([^\n]*\)\s*\{",
                "native_commit": r"private func commitPlan\(\)\s*\{",
                "overlay_submit": r"private func applyOverlay\(\)\s*\{",
                "native_layout_handoff": r"private func applyNative\([^\n]*\)\s*\{",
                "handoff_bitmap_retain": r"private func retainHandoffImages\(\)\s*\{",
                "artwork_capture": r"private func makeArtwork\([^)]*\)\s*->\s*\[(?:Int\s*:\s*)?ZoomArtwork\]\s*\{",
                "badge_capture": r"private static func bitmap\([^\n]*\)\s*->\s*CGImage\?\s*\{",
                "prefetch_enqueue": r"private func prefetchPlanImages\(\)\s*\{",
                "native_item_attributes": r"override func layoutAttributesForItem\([^\n]*\)\s*->\s*NSCollectionViewLayoutAttributes\?\s*\{",
                "native_visible_attributes": r"override func layoutAttributesForElements\([^\n]*\)\s*->\s*\[NSCollectionViewLayoutAttributes\]\s*\{",
            }
            for key, signature in methods.items():
                source = instrument(source, signature, key)
            # These native calls account for most of the settled handoff.
            # Measure them separately in the temporary source; totals overlap
            # with native_layout_handoff and must not be added to frame time.
            for signature, key in [
                ("collection.setFrameSize(layout.collectionViewContentSize)", "native_document_resize"),
                ("collection.layoutSubtreeIfNeeded()", "native_collection_layout"),
                ("scroll.contentView.scroll(to: scroll.contentView.convert(documentOrigin, from: collection))", "native_scroll"),
                ("scroll.reflectScrolledClipView(scroll.contentView)", "native_scroll_reflect"),
                ("item.view.layoutSubtreeIfNeeded()", "native_cell_layout"),
            ]:
                source = source.replace(signature, f'ZoomProbeCounters.measure("{key}") {{ {signature} }}')
        elif name == "ThumbnailZoomOverlay.swift":
            source = instrument(source, r"func render\([^\n]*\)\s*\{", "overlay_render")
            source = instrument(source, r"@MainActor func update\([^\n]*\)\s*\{", "tile_update")
        elif name == "ThumbnailZoomGeometry.swift":
            source = instrument(source, r"static func nearestIndex\([^\n]*\)\s*->\s*Int\?\s*\{", "nearest_item", assume_main=True)
        elif name == "ThumbnailItemViews.swift":
            source = instrument(source, r"override func apply\([^\n]*\)\s*\{", "native_cell_apply")
            source = instrument(source, r"func retainZoomThumbnail\([^\n]*\)\s*\{", "native_bitmap_install")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)
        paths.append(target)
    return paths, digests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--counts", type=int, nargs="+", default=[70, 1500])
    parser.add_argument("--frames", type=int, default=36)
    parser.add_argument("--repeats", type=int, default=2)
    parser.add_argument("--cadence", type=int, choices=[60, 120], default=60)
    parser.add_argument("--width", type=float, default=1000)
    parser.add_argument("--height", type=float, default=650)
    parser.add_argument("--startup-delay", type=float, default=0)
    parser.add_argument("--baseline", help="Git revision to compare against current sources")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--wait-file", type=Path)
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--cold-warm-only", action="store_true")
    args = parser.parse_args()
    if any(count < 9 or count > 10000 for count in args.counts) or args.frames < 4 or args.repeats < 1:
        parser.error("Use 9–10000 items, at least four frames, and positive repeats")
    if args.width < 500 or args.height < 300 or args.startup_delay < 0:
        parser.error("Window must be at least 500×300; startup delay must be nonnegative")
    if args.wait_file and args.wait_file.exists():
        parser.error("--wait-file must name a new signal file")
    revision = (subprocess.check_output(["git", "rev-parse", "--verify", "--end-of-options",
                                        args.baseline + "^{commit}"], cwd=ROOT, text=True).strip()
                if args.baseline else None)
    report = {"schema": 1, "measurement": "Main-thread elapsed work, process CPU and callback gaps, not screen FPS",
              "synthetic_artwork": True, "optimized": True, "baseline_commit": revision,
              "configuration": {key: getattr(args, key) for key in
                                ["counts", "frames", "repeats", "cadence", "width", "height"]},
              "builds": [], "runs": []}
    variants = [("baseline", revision)] if revision else []
    variants.append(("current", None))
    with tempfile.TemporaryDirectory(prefix="hermes-zoom-probe-") as temporary:
        temporary = Path(temporary)
        harness = temporary / "ThumbnailZoomBenchmark.swift"
        harness.write_text((ROOT / "script/benchmark_thumbnail_zoom.swift").read_text())
        report["harness_sha256"] = hashlib.sha256(harness.read_bytes()).hexdigest()
        snapshots = []
        for label, commit in variants:
            destination = temporary / label
            sources, digests = snapshot_sources(destination, commit)
            binary = destination / f"HermesThumbnailZoomProbe-{uuid.uuid4().hex}"
            manifest = destination / "fixture.json"
            manifest.write_text(json.dumps({**report["configuration"], "label": label, "coldWarmOnly": args.cold_warm_only,
                                            "startupDelay": args.startup_delay}))
            snapshots.append((label, sources, binary, manifest))
            report["builds"].append({"label": label, "production_source_sha256": digests})
        for label, sources, binary, _ in snapshots:
            run_process(["xcrun", "swiftc", "-j", "4", "-O", "-g", "-swift-version", "6", "-parse-as-library",
                         "-target", f"{platform.machine()}-apple-macos27.0", *map(str, sources),
                         str(harness), "-o", str(binary)])
            print(f"COMPILED {label}", flush=True)
        if args.compile_only:
            print("Compilation verified; no GUI probe was launched.", flush=True)
            return
        if args.wait_file:
            print(f"READY: waiting for {args.wait_file}", flush=True)
            deadline = time.monotonic() + 600
            while not args.wait_file.exists():
                if time.monotonic() > deadline:
                    raise TimeoutError("Quiet-window signal did not arrive within ten minutes")
                time.sleep(0.1)
        for label, _, binary, manifest in snapshots:
            stdout = run_process([str(binary), str(manifest)], timeout=240, capture=True)
            records = [json.loads(line) for line in stdout.splitlines() if line.startswith("{")]
            phases = [record for record in records if record.get("event") == "phase"]
            valid = bool(phases) and all(record.get("valid") for record in phases)
            report["runs"].append({"label": label, "records": records, "valid": valid})
            for record in records:
                print(json.dumps(record, sort_keys=True), flush=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2))
        print(f"REPORT {args.output.resolve()}", flush=True)
    if any(not run["valid"] for run in report["runs"]):
        raise SystemExit("INVALID: input, geometry, or incomplete native handoff contaminated a phase")


if __name__ == "__main__":
    main()
