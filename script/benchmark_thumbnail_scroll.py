#!/usr/bin/env python3
"""Compare native thumbnail scrolling with read-only media and isolated app state.

Example: python3 script/benchmark_thumbnail_scroll.py MEDIA_DIRECTORY --copies 10
Add --baseline GIT_REF to compile the same probe against an earlier revision.
Copies stress collection-cell reuse without creating or modifying media files.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("--copies", type=int, default=1)
parser.add_argument("--baseline", help="Git revision to compare with the working tree")
args = parser.parse_args()
if not args.directory.is_dir() or not 1 <= args.copies <= 100:
    parser.error("Use an existing media directory and 1–100 copies")

sources = [
    "Sources/UIModels.swift", "Sources/Utilities/FileSystemUtilities.swift",
    "Sources/Utilities/NativeMediaResources.swift",
    "Sources/Views/CollectionViews/ThumbnailGridController.swift",
    "Sources/Views/Thumbnail/ThumbnailService.swift",
    "Sources/Views/Thumbnail/ThumbnailItemViews.swift",
    "Sources/Views/Thumbnail/ThumbnailCompositionEffect.swift",
    "Sources/Views/Thumbnail/SystemThumbnailProvider.swift",
]
with tempfile.TemporaryDirectory(prefix="hermes-scroll-probe-") as directory:
    temp = Path(directory)
    compiled_sources = [root / source for source in sources]
    if args.baseline:
        compiled_sources = []
        for source in sources:
            target = temp / Path(source).name
            target.write_bytes(subprocess.check_output(
                ["git", "show", f"{args.baseline}:{source}"], cwd=root))
            compiled_sources.append(target)
    binary = temp / "HermesThumbnailScrollProbe"
    subprocess.run([
        "xcrun", "swiftc", "-j", "4", "-O", "-swift-version", "6", "-parse-as-library",
        "-target", "arm64-apple-macos27.0", *map(str, compiled_sources),
        str(root / "script/benchmark_thumbnail_scroll.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), str(args.directory.resolve()), str(args.copies)],
        check=True, timeout=60)
