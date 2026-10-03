#!/usr/bin/env python3
"""Exercise the real media metadata functions with generated, offline fixtures."""
from pathlib import Path
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
fixture_main = r'''
import AppKit
import AudioToolbox

@main enum MetadataSafetyRegression {
    static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
    static func expectError(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected a normal metadata error") }
        catch { }
    }
    static func box(_ type: String, _ payload: Data) -> Data {
        var result = Data()
        appendUInt32BE(UInt32(payload.count + 8), to: &result)
        result.append(Data(type.utf8)); result.append(payload)
        return result
    }
    static func bytes(of url: URL, mediaType: AVMediaType) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: mediaType).first else { return Data() }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output); expect(reader.startReading(), "Sample reader failed")
        var result = Data()
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetDataBuffer(sample) {
                var value = Data(count: CMBlockBufferGetDataLength(buffer))
                let status = value.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                }
                expect(status == noErr, "Could not read media sample")
                result.append(value)
            }
        }
        expect(reader.status == .completed, "Sample reader did not finish")
        return result
    }
    static func title(of url: URL) async throws -> String? {
        for item in try await AVURLAsset(url: url).loadMetadata(for: .quickTimeMetadata)
        where item.identifier == .quickTimeMetadataTitle {
            return try await item.load(.stringValue)
        }
        return nil
    }
    static func generateMovie(_ url: URL, codec: AVVideoCodecType, title: String) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = [metadataItem(identifier: .quickTimeMetadataTitle, value: title as NSString,
            dataType: kCMMetadataBaseDataType_UTF8 as String)]
        var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: 64, AVVideoHeightKey: 64]
        if codec == .hevc {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input); expect(writer.startWriting(), "Fixture writer failed")
        writer.startSession(atSourceTime: .zero)
        for index in 0..<10 {
            var optional: CVPixelBuffer?
            expect(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &optional) == kCVReturnSuccess,
                "Fixture pixel buffer failed")
            let pixel = optional!
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel)!, Int32(index * 10), CVPixelBufferGetBytesPerRow(pixel) * 64)
            CVPixelBufferUnlockBaseAddress(pixel, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            expect(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 5)), "Fixture frame failed")
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        expect(writer.status == .completed, "Fixture video failed")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let originalID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let replacementID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        let originalTitle = "hev1 AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA " + originalID
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 100, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let image = root.appendingPathComponent("sample.jpg")
        let imageBytes = bitmap.representation(using: .jpeg, properties: [:])!
        try imageBytes.write(to: image)
        let imageWithID = root.appendingPathComponent("identified.jpg")
        try writeJPEGWithAssetID(sourceURL: image, outputURL: imageWithID, assetID: originalID)
        expect(try extractAssetID(from: imageWithID) == originalID, "JPEG MakerNote ID changed")

        // A normal image whose EXIF pointer is out of bounds still has valid pixels.
        let malformedImage = root.appendingPathComponent("malformed.jpg")
        let invalidExif = Data([0xff, 0xe1, 0, 16, 0x45, 0x78, 0x69, 0x66, 0, 0,
            0x4d, 0x4d, 0, 0x2a, 0xff, 0xff, 0xff, 0xff])
        try (Data(imageBytes.prefix(2)) + invalidExif + Data(imageBytes.dropFirst(2))).write(to: malformedImage)
        expect(CGImageSourceCreateWithURL(malformedImage as CFURL, nil) != nil, "Fixture must remain a readable image")
        expectError { _ = try extractAssetID(from: malformedImage) }
        for data in [Data([0x4d, 0x4d, 0, 42, 0xff, 0xff, 0xff, 0xff]),
                     Data([0, 0, 0xff, 0xff]) + Data("meta".utf8) + Data(repeating: 0, count: 12)] {
            expectError { _ = try extractAssetIDFromTIFF(data) }
            expectError { _ = try heicExifItemLocation(in: data) }
        }
        let jpeg = try Data(contentsOf: imageWithID)
        for length in 0..<jpeg.count {
            let candidate = root.appendingPathComponent("truncated.jpg")
            try jpeg.prefix(length).write(to: candidate)
            _ = try? extractAssetID(from: candidate)
        }
        print("PASS: malformed and truncated JPEG/TIFF/HEIF metadata returns errors without trapping")

        // Exercise real HEIF metadata round-trip and malformed box boundaries.
        let heic = root.appendingPathComponent("sample.heic")
        let destination = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, bitmap.cgImage!, [kCGImagePropertyExifDictionary:
            [kCGImagePropertyExifUserComment: "offline fixture"]] as CFDictionary)
        expect(CGImageDestinationFinalize(destination), "HEIF fixture failed")
        let identifiedHEIC = root.appendingPathComponent("identified.heic")
        try writeHEICWithAssetID(sourceURL: heic, outputURL: identifiedHEIC, assetID: originalID)
        expect(try extractAssetIDFromTIFF(extractHEICExifData(from: identifiedHEIC)) == originalID, "HEIF ID changed")
        let heicBytes = try Data(contentsOf: heic)
        for length in 0..<heicBytes.count { _ = try? heicExifItemLocation(in: Data(heicBytes.prefix(length))) }
        print("PASS: valid HEIF ID round-trip and every truncated box boundary")

        let orientedHEIC = root.appendingPathComponent("oriented.heic")
        let orientedDestination = CGImageDestinationCreateWithURL(orientedHEIC as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(orientedDestination, bitmap.cgImage!, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "native orientation fixture"]] as CFDictionary)
        expect(CGImageDestinationFinalize(orientedDestination), "Oriented HEIF fixture failed")
        let identifiedOrientedHEIC = root.appendingPathComponent("oriented-identified.heic")
        try writeHEICWithAssetID(sourceURL: orientedHEIC, outputURL: identifiedOrientedHEIC, assetID: originalID)
        expect(imageOrientation(identifiedOrientedHEIC) == 6, "Fixture needs a non-normalized native orientation")

        let video = root.appendingPathComponent("sample.mov")
        try await generateMovie(video, codec: .h264, title: originalTitle)
        // Add a generated AAC audio track to the ordinary fixture movie.
        let audio = root.appendingPathComponent("sample.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        var audioFile: AVAudioFile? = try AVAudioFile(forWriting: audio, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.05) * 0.1) }
        try audioFile!.write(from: buffer)
        audioFile = nil
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        defer { withExtendedLifetime((videoAsset, audioAsset)) {} }
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        let duration = CMTimeMinimum(videoRange.duration, audioRange.duration)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: videoRange.start, duration: duration), of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: audioRange.start, duration: duration), of: audioTrack, at: .zero)
        let withAudio = root.appendingPathComponent("with-audio.mov")
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        exporter.metadata = [metadataItem(identifier: .quickTimeMetadataTitle, value: originalTitle as NSString,
            dataType: kCMMetadataBaseDataType_UTF8 as String)]
        try await exporter.export(to: withAudio, as: .mov)
        print("PASS: generated ordinary video with an AAC audio track")
        let live = root.appendingPathComponent("live.mov")
        try await makeMovie(sourceURL: withAudio, outputURL: live, assetID: originalID)
        expect(try await extractAssetIDFromMovie(live) == originalID, "Read the actual content ID, not title UUID")
        let originalVideoBytes = try await bytes(of: withAudio, mediaType: .video)
        let originalAudioBytes = try await bytes(of: withAudio, mediaType: .audio)
        expect(!originalAudioBytes.isEmpty, "Fixture needs an audio track")
        expect(try await bytes(of: live, mediaType: .video) == originalVideoBytes, "Remux changed compressed video")
        expect(try await bytes(of: live, mediaType: .audio) == originalAudioBytes, "Remux changed audio")
        let copied = root.appendingPathComponent("copied.mov")
        expect(try await copyMovieReplacingAssetIDIfPossible(sourceURL: live, outputURL: copied, assetID: replacementID),
            "Standard Live Photo must retain the fast lossless path")
        expect(try await extractAssetIDFromMovie(copied) == replacementID, "Content ID was not replaced")
        expect(try await title(of: copied) == originalTitle, "Unrelated UUID/hev1 title was changed")
        let before = try Data(contentsOf: live), after = try Data(contentsOf: copied)
        let valueRanges = try movieMetadataValueRanges(in: before, key: "com.apple.quicktime.content.identifier")
        expect(before.count == after.count, "Fast path changed the file size")
        expect(before.indices.allSatisfy { offset in before[offset] == after[offset] || valueRanges.contains(where: { $0.contains(offset) }) },
            "Fast path changed bytes outside the content ID")
        // Unequal lengths cannot be patched in place and must use the existing remux.
        let fallback = root.appendingPathComponent("fallback.mov")
        expect(!(try await copyMovieReplacingAssetIDIfPossible(sourceURL: live, outputURL: fallback, assetID: "short-id")),
            "Unsafe variable-length field edit must decline the fast path")
        try await makeLivePhotoMovie(sourceURL: live, outputURL: fallback, assetID: "short-id")
        expect(try await extractAssetIDFromMovie(fallback) == "short-id", "Remux fallback did not set the ID")
        expect(try await title(of: fallback) == originalTitle, "Remux changed title metadata")
        expect(try await bytes(of: fallback, mediaType: .video) == originalVideoBytes, "Fallback changed video")
        expect(try await bytes(of: fallback, mediaType: .audio) == originalAudioBytes, "Fallback changed audio")
        print("PASS: actual MOV content ID, exact lossless edit, unchanged unrelated UUID/title, audio and video, safe remux fallback")

        // Synthetic container makes the allowed four-byte mutation unambiguous.
        let sampleEntry = box("hev1", Data(repeating: 0, count: 78) + box("hvcC", Data([1])))
        var stsd = Data(repeating: 0, count: 4); appendUInt32BE(1, to: &stsd); stsd.append(sampleEntry)
        let handler = box("hdlr", Data(repeating: 0, count: 8) + Data("vide".utf8))
        let track = box("trak", box("mdia", handler + box("minf", box("stbl", box("stsd", stsd)))))
        let payload = Data("compressed payload hev1 must remain unchanged".utf8)
        let structural = box("ftyp", Data("qt  ".utf8)) + box("mdat", payload)
            + box("free", Data("unrelated hev1".utf8)) + box("moov", track)
        let structuralURL = root.appendingPathComponent("structural.mov")
        try structural.write(to: structuralURL)
        try rewriteHEVCSampleEntryForAppleCompatibility(structuralURL)
        let changed = try Data(contentsOf: structuralURL)
        expect(changed.count == structural.count, "Sample entry edit changed length")
        expect(zip(structural, changed).filter { pair in pair.0 != pair.1 }.count == 2, "Only hev1 type may change to hvc1")
        expect(changed.range(of: payload) != nil && changed.range(of: Data("unrelated hev1".utf8)) != nil,
            "Sample entry edit touched media or unrelated metadata")
        let unchanged = try Data(contentsOf: live)
        try rewriteHEVCSampleEntryForAppleCompatibility(live)
        expect(try Data(contentsOf: live) == unchanged, "H264 movie containing hev1 in title was changed")

        // Real HEVC remux retains encoded samples and HLG color properties.
        let hevc = root.appendingPathComponent("hevc.mov")
        let hevcLive = root.appendingPathComponent("hevc-live.mov")
        try await generateMovie(hevc, codec: .hevc, title: originalTitle)
        try await makeLivePhotoMovie(sourceURL: hevc, outputURL: hevcLive, assetID: originalID)
        expect(try await bytes(of: hevc, mediaType: .video) == bytes(of: hevcLive, mediaType: .video), "HEVC remux changed samples")
        let sourceTrack = try await AVURLAsset(url: hevc).loadTracks(withMediaType: .video)[0]
        let outputTrack = try await AVURLAsset(url: hevcLive).loadTracks(withMediaType: .video)[0]
        let sourceFormat = try await sourceTrack.load(.formatDescriptions)[0]
        let outputFormat = try await outputTrack.load(.formatDescriptions)[0]
        for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
                    kCMFormatDescriptionExtension_YCbCrMatrix] {
            let sourceValue = CMFormatDescriptionGetExtension(sourceFormat, extensionKey: key) as? String
            let outputValue = CMFormatDescriptionGetExtension(outputFormat, extensionKey: key) as? String
            expect(sourceValue != nil && sourceValue == outputValue, "HEVC color property changed")
        }
        print("PASS: only HEVC sample entry changes; mdat, unrelated metadata, HEVC samples and HLG color properties preserved")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="hermes-tool-metadata-") as directory:
    temp = Path(directory)
    source = (root / "Sources/tool.swift").read_text()
    harness = temp / "MetadataSafetyRegression.swift"
    harness.write_text(source[:source.index("@main\nstruct Main")] + fixture_main)
    binary = temp / "metadata-regression"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-suppress-warnings", "-parse-as-library", str(harness), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(temp)], check=True, timeout=90)
    tool = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else temp / "tool"
    if len(sys.argv) == 1:
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(root / "Sources/tool.swift"), "-o", str(tool)], check=True)
    result = subprocess.run([str(tool), str(temp / "malformed.jpg"), str(temp / "sample.mov"), str(temp / "production-output")],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    output = json.loads(next(line.removeprefix("HERMES_RESULT:") for line in result.stdout.splitlines()
                             if line.startswith("HERMES_RESULT:")))
    assert all(Path(path).is_file() for path in output.values())
    assert not list((temp / "production-output").glob(".hermes-stage-*"))
    print("PASS: production helper recovers readable JPEG with bad EXIF and cleans staging")

    oriented_image = temp / "oriented-identified.heic"
    for label, movie, native in [
        ("native-orientation", temp / "live.mov", True),
        ("mismatched-native-id", temp / "copied.mov", False),
        ("missing-native-timing", temp / "with-audio.mov", False),
    ]:
        destination = temp / label
        result = subprocess.run([str(tool), str(oriented_image), str(movie), str(destination)],
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (label, result.returncode, result.stdout, result.stderr)
        output = json.loads(next(line.removeprefix("HERMES_RESULT:") for line in result.stdout.splitlines()
                                 if line.startswith("HERMES_RESULT:")))
        image_output, movie_output = Path(output["imagePath"]), Path(output["moviePath"])
        if native:
            assert image_output.suffix == ".heic", "Native oriented HEIF must keep its original format"
            assert image_output.read_bytes() == oriented_image.read_bytes(), "Native oriented HEIF was modified"
            assert movie_output.read_bytes() == movie.read_bytes(), "Native timing, audio, video or metadata was modified"
        else:
            assert image_output.suffix == ".jpg", "Mismatched or incomplete pairs must use the existing conversion path"
        assert not list(destination.glob(".hermes-stage-*"))
    print("PASS: native HEIF orientation 6 retains every source byte; mismatched IDs and incomplete movies keep conversion checks")
