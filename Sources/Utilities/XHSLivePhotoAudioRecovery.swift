import Foundation
import AVFoundation
import CoreMedia
import CryptoKit

/// Adds an already-matched client audio track without decoding or re-encoding either stream.
/// The caller owns image-file-ID matching and keeps the untouched original when this returns false.
enum XHSLivePhotoAudioRecovery {
    private struct CopyTrack {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var finished = false
    }

    private struct SampleFingerprint: Equatable {
        let digest: SHA256.Digest
        let sizes: [Int]
        let sampleCount: Int
    }

    /// False means the original already has audio, the donor is incompatible, or passthrough
    /// could not preserve the original resources. Neither input is ever modified.
    static func addingAudio(from donor: URL, to original: URL, output: URL) async throws -> Bool {
        try Task.checkCancellation()
        let source = try asset(at: original)
        let sourceTracks = try await source.load(.tracks)
        guard sourceTracks.allSatisfy({ $0.mediaType != .audio }),
              let sourceVideo = sourceTracks.first(where: { $0.mediaType == .video }) else { return false }

        let donorAsset = try asset(at: donor)
        guard let audio = try await donorAsset.loadTracks(withMediaType: .audio).first else { return false }
        let sourceDuration = try await source.load(.duration).seconds
        let donorDuration = try await donorAsset.load(.duration).seconds
        let sourceRange = try await sourceVideo.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        // Allow a few AAC priming/padding frames, but never offset or stretch the sound.
        guard sourceDuration.isFinite, donorDuration.isFinite, sourceDuration > 0, donorDuration > 0,
              abs(sourceDuration - donorDuration) <= 0.12,
              abs(sourceRange.duration.seconds - audioRange.duration.seconds) <= 0.12,
              sourceRange.start.seconds.isFinite, audioRange.start.seconds.isFinite,
              abs(sourceRange.start.seconds) <= 0.02, abs(audioRange.start.seconds) <= 0.02 else { return false }

        let outputPath = output.resolvingSymlinksInPath().standardizedFileURL
        guard outputPath != original.resolvingSymlinksInPath().standardizedFileURL,
              outputPath != donor.resolvingSymlinksInPath().standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else {
            throw failure("补音输出路径必须是新的临时文件。")
        }

        let reader = try AVAssetReader(asset: source)
        let audioReader = try AVAssetReader(asset: donorAsset)
        var writer: AVAssetWriter?
        var preserved = false
        defer {
            reader.cancelReading()
            audioReader.cancelReading()
            if !preserved {
                writer?.cancelWriting()
                try? FileManager.default.removeItem(at: output)
            }
        }
        let activeWriter = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer = activeWriter
        activeWriter.metadata = try await source.load(.metadata)
        var copies: [CopyTrack] = []
        for track in sourceTracks {
            guard let copy = try await copyTrack(track, reader: reader, writer: activeWriter) else { return false }
            copies.append(copy)
        }
        guard let audioCopy = try await copyTrack(audio, reader: audioReader, writer: activeWriter) else { return false }
        copies.append(audioCopy)

        try Task.checkCancellation()
        guard activeWriter.startWriting() else { throw activeWriter.error ?? failure("无法开始无损补音。") }
        activeWriter.startSession(atSourceTime: .zero)
        guard reader.startReading() else { throw reader.error ?? failure("无法读取原始实况。") }
        guard audioReader.startReading() else { throw audioReader.error ?? failure("无法读取客户端声音。") }
        // Interleave all inputs so one full track cannot block another track's writer buffer.
        while copies.contains(where: { !$0.finished }) {
            try Task.checkCancellation()
            var advanced = false
            for index in copies.indices where !copies[index].finished && copies[index].input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if let sample = copies[index].output.copyNextSampleBuffer() {
                    guard copies[index].input.append(sample) else {
                        throw activeWriter.error ?? failure("无法无损写入实况轨道。")
                    }
                } else {
                    if copies[index].reader.status == .failed {
                        throw copies[index].reader.error ?? failure("实况轨道读取失败。")
                    }
                    copies[index].input.markAsFinished()
                    copies[index].finished = true
                }
                advanced = true
            }
            if activeWriter.status == .failed { throw activeWriter.error ?? failure("无损补音失败。") }
            if !advanced { try await Task.sleep(for: .milliseconds(5)) }
        }
        await activeWriter.finishWriting()
        try Task.checkCancellation()
        guard activeWriter.status == .completed else { throw activeWriter.error ?? failure("无损补音未完成。") }

        let recovered = try asset(at: output)
        let recoveredTracks = try await recovered.load(.tracks)
        let recoveredOriginals = recoveredTracks.filter { $0.mediaType != .audio }
        guard recoveredOriginals.count == sourceTracks.count,
              recoveredTracks.filter({ $0.mediaType == .audio }).count == 1,
              try await metadataSignature(source) == metadataSignature(recovered) else { return false }
        // Validate the actual compressed payloads, including every timed-metadata track.
        for (before, after) in zip(sourceTracks, recoveredOriginals) {
            try Task.checkCancellation()
            guard before.mediaType == after.mediaType,
                  try await trackDescriptionPreserved(before, after),
                  try await fingerprint(before, asset: source) == fingerprint(after, asset: recovered) else { return false }
        }
        guard let recoveredAudio = recoveredTracks.first(where: { $0.mediaType == .audio }),
              try await fingerprint(audio, asset: donorAsset) == fingerprint(recoveredAudio, asset: recovered) else { return false }
        try Task.checkCancellation()
        preserved = true
        return true
    }

    private static func copyTrack(_ track: AVAssetTrack, reader: AVAssetReader, writer: AVAssetWriter) async throws -> CopyTrack? {
        let formats = try await track.load(.formatDescriptions)
        guard let format = formats.first else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
        input.metadata = try await track.load(.metadata)
        if track.mediaType != .audio { input.mediaTimeScale = try await track.load(.naturalTimeScale) }
        if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
        guard reader.canAdd(output), writer.canAdd(input) else { return nil }
        reader.add(output)
        writer.add(input)
        return CopyTrack(reader: reader, output: output, input: input)
    }

    private static func fingerprint(_ track: AVAssetTrack, asset: AVURLAsset) async throws -> SampleFingerprint {
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw failure("无法核验无损轨道。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? failure("无法核验无损轨道。") }
        var hasher = SHA256()
        var sizes: [Int] = []
        var sampleCount = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let countInBuffer = CMSampleBufferGetNumSamples(sample)
            // AVFoundation also emits zero-sample timing/trim markers without a data buffer.
            // They pass through the writer above; they are not compressed media payloads.
            guard countInBuffer > 0 else { continue }
            sampleCount += countInBuffer
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw failure("实况轨道缺少可核验的数据。") }
            let count = CMBlockBufferGetDataLength(block)
            guard count > 0 else { throw failure("实况轨道数据为空。") }
            var data = Data(repeating: 0, count: count)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw failure("无法读取实况轨道数据。") }
            hasher.update(data: data)
            // MOV and MP4 readers batch AAC packets differently; compare packet sizes,
            // rather than the arbitrary size of each reader buffer.
            for index in 0..<countInBuffer { sizes.append(CMSampleBufferGetSampleSize(sample, at: index)) }
        }
        guard reader.status == .completed else { throw reader.error ?? failure("实况轨道核验未完成。") }
        return SampleFingerprint(digest: hasher.finalize(), sizes: sizes, sampleCount: sampleCount)
    }

    private static func trackDescriptionPreserved(_ before: AVAssetTrack, _ after: AVAssetTrack) async throws -> Bool {
        let beforeFormats = try await before.load(.formatDescriptions)
        let afterFormats = try await after.load(.formatDescriptions)
        guard beforeFormats.count == afterFormats.count,
              zip(beforeFormats, afterFormats).allSatisfy({ formatDescriptionPreserved($0.0, $0.1) }),
              try await metadataSignature(before.load(.metadata)) == metadataSignature(after.load(.metadata)) else { return false }
        let beforeRange = try await before.load(.timeRange)
        let afterRange = try await after.load(.timeRange)
        guard abs(beforeRange.start.seconds - afterRange.start.seconds) < 0.002,
              abs(beforeRange.duration.seconds - afterRange.duration.seconds) < 0.002 else { return false }
        if before.mediaType == .video {
            guard try await before.load(.preferredTransform) == after.load(.preferredTransform),
                  try await before.load(.naturalSize) == after.load(.naturalSize) else { return false }
        }
        return true
    }

    private static func metadataSignature(_ asset: AVURLAsset) async throws -> [String] {
        try await metadataSignature(asset.load(.metadata))
    }

    private static func metadataSignature(_ items: [AVMetadataItem]) async throws -> [String] {
        var signature: [String] = []
        for item in items {
            try Task.checkCancellation()
            let value: String
            if let data = try await item.load(.dataValue) {
                value = SHA256.hash(data: data).description
            } else { value = try await item.load(.stringValue) ?? "" }
            signature.append("\(item.identifier?.rawValue ?? "")|\(item.dataType ?? "")|\(value)")
        }
        return signature.sorted()
    }

    private static func formatDescriptionPreserved(_ before: CMFormatDescription, _ after: CMFormatDescription) -> Bool {
        guard CMFormatDescriptionGetMediaType(before) == CMFormatDescriptionGetMediaType(after),
              CMFormatDescriptionGetMediaSubType(before) == CMFormatDescriptionGetMediaSubType(after) else { return false }
        if CMFormatDescriptionGetMediaType(before) == kCMMediaType_Video {
            let a = CMVideoFormatDescriptionGetDimensions(before)
            let b = CMVideoFormatDescriptionGetDimensions(after)
            guard a.width == b.width, a.height == b.height else { return false }
        }
        var a = CMFormatDescriptionGetExtensions(before) as? [String: Any] ?? [:]
        var b = CMFormatDescriptionGetExtensions(after) as? [String: Any] ?? [:]
        // MP4 and MOV describe their raw sample-entry wrappers under different keys.
        // Keep every codec configuration, color/HDR field and metadata-key table comparable.
        for key in ["VerbatimISOSampleEntry", "VerbatimSampleDescription"] {
            a.removeValue(forKey: key)
            b.removeValue(forKey: key)
        }
        return NSDictionary(dictionary: a).isEqual(to: b)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "XHSLivePhotoAudioRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func asset(at url: URL) throws -> AVURLAsset {
        // Staging paths end in .part; supply a container hint instead of using the suffix.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 12) ?? Data()
        let quickTime = header.count >= 12 && String(decoding: header[4..<12], as: UTF8.self) == "ftypqt  "
        return AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: quickTime ? "video/quicktime" : "video/mp4"])
    }
}
