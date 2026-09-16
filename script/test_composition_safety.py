#!/usr/bin/env python3
"""Test the real helper with generated media, never user assets or the Photos library."""
from pathlib import Path
import concurrent.futures
import hashlib
import json
import subprocess
import tempfile
import sys
import uuid

root = Path(__file__).resolve().parents[1]
fixture_source = r'''
import AppKit
import AVFoundation
import CoreVideo
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
memset(bitmap.bitmapData!, 100, bitmap.bytesPerRow * bitmap.pixelsHigh)
try bitmap.representation(using: .jpeg, properties: [:])!.write(to: root.appendingPathComponent("sample.jpg"))
let writer = try AVAssetWriter(outputURL: root.appendingPathComponent("sample.mov"), fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
writer.add(input)
precondition(writer.startWriting())
writer.startSession(atSourceTime: .zero)
for index in 0..<10 {
    var optional: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &optional) == kCVReturnSuccess)
    let pixel = optional!
    CVPixelBufferLockBaseAddress(pixel, [])
    memset(CVPixelBufferGetBaseAddress(pixel)!, Int32(index * 10), CVPixelBufferGetBytesPerRow(pixel) * 64)
    CVPixelBufferUnlockBaseAddress(pixel, [])
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
    precondition(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 5)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
precondition(writer.status == .completed)
'''
with tempfile.TemporaryDirectory(prefix="hermes-composition-safety-") as directory:
    temp = Path(directory)
    fixtures = temp / "fixtures"
    fixtures.mkdir()
    swift = temp / "main.swift"
    swift.write_text(fixture_source)
    subprocess.run(["xcrun", "swiftc", str(swift), "-o", str(temp / "generator")], check=True)
    subprocess.run([str(temp / "generator"), str(fixtures)], check=True, timeout=30)
    tool = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / ".build/debug/tool"
    assert tool.is_file(), "Build the current helper with swift build first"
    image, movie = fixtures / "sample.jpg", fixtures / "sample.mov"
    checksum = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    originals = {p: checksum(p) for p in (image, movie)}
    def run(image, movie, output, *args, success=True):
        result = subprocess.run([str(tool), str(image), str(movie), str(output), *args], capture_output=True, text=True, timeout=30)
        assert (result.returncode == 0) == success, (result.stdout, result.stderr)
        if success:
            entry = next(line for line in result.stdout.splitlines() if line.startswith("HERMES_RESULT:"))
            paths = json.loads(entry.removeprefix("HERMES_RESULT:"))
            assert all(Path(p).is_file() for p in paths.values())
            return paths
    same = run(image, movie, fixtures)
    assert same["imagePath"] != str(image) and same["moviePath"] != str(movie)
    assert all(checksum(p) == digest for p, digest in originals.items())
    print("PASS: input directory equals output directory; original pair preserved")
    invalid = temp / "invalid.mov"
    invalid.write_bytes(b"not a valid movie")
    before = {p.name: checksum(p) for p in fixtures.iterdir() if p.is_file()}
    run(image, invalid, fixtures, success=False)
    after = {p.name: checksum(p) for p in fixtures.iterdir() if p.is_file()}
    assert before == after
    assert not list(fixtures.glob(".hermes-stage-*"))
    print("PASS: failed recomposition preserves all existing outputs and cleans staging")
    concurrent_dir = temp / "concurrent"
    concurrent_dir.mkdir()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: run(image, movie, concurrent_dir), range(4)))
    assert len({item["imagePath"] for item in results}) == 4
    assert len({item["moviePath"] for item in results}) == 4
    assert len(list(concurrent_dir.glob("*.jpg"))) == len(list(concurrent_dir.glob("*.mov"))) == 4
    print("PASS: four concurrent same-name compositions publish distinct complete pairs")
    prepared = temp / "photos-preparation"
    prepared.mkdir()
    run(Path(same["imagePath"]), Path(same["moviePath"]), prepared, "--asset-id", str(uuid.uuid4()).upper())
    assert all(checksum(p) == digest for p, digest in originals.items())
    print("PASS: unique-ID Photos preparation works without changing source files")
