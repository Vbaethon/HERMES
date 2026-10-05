import Foundation
import AppKit
import AVFoundation
import Darwin

private actor DownloadStatusRecorder {
    private var statuses: [DownloaderInfra.DownloadStatus] = []
    func record(_ status: DownloaderInfra.DownloadStatus) { statuses.append(status) }
    func snapshot() -> [String] { statuses.map(\.text) }
    func stageSnapshot() -> [DownloaderInfra.DownloadStage] { statuses.map(\.stage) }
    func statusSnapshot() -> [DownloaderInfra.DownloadStatus] { statuses }
}

private actor DownloadProgressRecorder {
    private var values: [Double] = []
    private let suspendFirst: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    init(suspendFirst: Bool = false) { self.suspendFirst = suspendFirst }

    func record(_ value: Double) async {
        if suspendFirst && !isWaiting && values.isEmpty {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        values.append(value)
    }

    func release() { continuation?.resume(); continuation = nil }
    func snapshot() -> [Double] { values }
}

private func checkDownloadProgress() async throws {
    let recorder = DownloadProgressRecorder()
    let progress = DownloaderInfra.DownloadProgressAggregator(totalCount: 3) { await recorder.record($0) }
    for (index, value) in [(-1, 1.0), (3, 1.0), (0, Double.nan), (1, .infinity), (2, -.infinity)] {
        await progress.update(index: index, fraction: value)
    }
    await progress.complete(index: 3)
    let invalidValues = await recorder.snapshot()
    precondition(invalidValues.isEmpty, "invalid indices and nonfinite progress must not change the total")
    await progress.update(index: 0, fraction: 0.6)
    await progress.update(index: 0, fraction: 0.1) // Retry starts from an earlier byte count.
    await progress.update(index: 1, fraction: 0.9)
    await progress.update(index: 1, fraction: -0.5)
    await progress.complete(index: 0)
    await progress.update(index: 0, fraction: 0.4) // Late callback for a completed file.
    await progress.complete(index: 0)
    await progress.complete(index: 2)
    await progress.update(index: 1, fraction: 2)
    await progress.complete(index: 1)
    let values = await recorder.snapshot()
    precondition(values.first == 0.6 / 3 && values.last == 1
        && zip(values, values.dropFirst()).allSatisfy { $0 < $1 },
        "retries, duplicate completions and late callbacks must preserve increasing cumulative progress")

    // Hold the first consumer across an actor suspension. Sibling callbacks
    // must be coalesced until it finishes, rather than delivered ahead of it.
    let delayed = DownloadProgressRecorder(suspendFirst: true)
    let concurrent = DownloaderInfra.DownloadProgressAggregator(totalCount: 2) { await delayed.record($0) }
    let firstUpdate = Task { await concurrent.update(index: 0, fraction: 0.2) }
    for _ in 0..<1000 {
        if await delayed.isWaiting { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    let firstIsWaiting = await delayed.isWaiting
    precondition(firstIsWaiting, "the delayed progress consumer must start")
    await concurrent.update(index: 1, fraction: 0.6)
    await concurrent.update(index: 0, fraction: 0.1)
    await concurrent.complete(index: 0)
    await concurrent.update(index: 0, fraction: 0.3)
    await concurrent.complete(index: 1)
    let whileWaiting = await delayed.snapshot()
    await delayed.release()
    await firstUpdate.value
    let delivered = await delayed.snapshot()
    precondition(whileWaiting.isEmpty && delivered == [0.1, 1],
        "a suspended consumer must receive the older value before the latest total, including final completion")
    print("PASS: multi-file progress rejects retry regressions and late callbacks, serializes concurrent delivery, and reaches 100%")
}

private func containsStagesInOrder(_ stages: [DownloaderInfra.DownloadStage], _ expected: [DownloaderInfra.DownloadStage]) -> Bool {
    var remaining = expected.makeIterator()
    var next = remaining.next()
    for stage in stages where stage == next { next = remaining.next() }
    return next == nil
}

private final class FailedNativeTransferProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    override func stopLoading() { }
}

private func stopFixtureServer(_ process: Process, terminated: DispatchSemaphore) {
    if process.isRunning { process.terminate() }
    if terminated.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        _ = terminated.wait(timeout: .now() + 1)
    }
}

/// Read compressed track samples to detect a video or audio re-encode during
/// passthrough composition. Container offsets and atom ordering may differ.
private func compressedTrackSamples(at url: URL, mediaType: AVMediaType) async throws -> [Data] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: mediaType).first else { return [] }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "RegressionSampleReader", code: 1) }
    var samples: [Data] = []
    while let sample = output.copyNextSampleBuffer() {
        let count = CMSampleBufferGetNumSamples(sample)
        if count == 0 { continue } // Native timed-metadata markers can have no payload.
        guard let buffer = CMSampleBufferGetDataBuffer(sample) else {
            throw NSError(domain: "RegressionSampleReader", code: 2)
        }
        var offset = 0
        // AVAssetReader may batch AAC packets differently for MP4 and MOV.
        // Compare packets rather than the arbitrary sample-buffer boundaries.
        for index in 0..<count {
            let dataLength = CMSampleBufferGetSampleSize(sample, at: index)
            guard dataLength > 0 else { throw NSError(domain: "RegressionSampleReader", code: 4) }
            var data = Data(count: dataLength)
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(buffer, atOffset: offset, dataLength: dataLength, destination: bytes.baseAddress!)
            }
            guard status == noErr else { throw NSError(domain: "RegressionSampleReader", code: Int(status)) }
            samples.append(data)
            offset += dataLength
        }
    }
    if reader.status == .failed { throw reader.error ?? NSError(domain: "RegressionSampleReader", code: 3) }
    return samples
}

private func livePhotoContentIdentifier(at url: URL) async throws -> String? {
    let metadata = try await AVURLAsset(url: url).load(.metadata)
    guard let item = metadata.first(where: { $0.identifier?.rawValue == "mdta/com.apple.quicktime.content.identifier" }) else { return nil }
    return try await item.load(.stringValue)
}

private func audioTrackSubtype(at url: URL) async throws -> UInt32? {
    guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first,
          let format = try await track.load(.formatDescriptions).first else { return nil }
    return CMFormatDescriptionGetMediaSubType(format)
}

@main struct DownloadRegression {
    static func main() async throws {
        try await checkDownloadProgress()
        try XHSCachedMotionRegression.run()
        try await XHSReplacementRegression.run()
        typealias D = DouyinNativeDownloader
        let a = URL(string: "https://example.com/a.mp4")!
        let b = URL(string: "https://example.com/b.mp4")!
        func item(_ index: Int, _ video: URL?) -> D.MediaItem {
            D.MediaItem(index: index, imageURL: URL(string: "https://example.com/\(index).jpg")!, videoURL: video, sourceMarkedHDR: false, streamMarkedHDR: false, width: 100, height: 100, videoWidth: 100, videoHeight: 100)
        }
        var current = D.AwemeInfo(awemeID: "work", images: [item(1,a), item(2,nil)])
        let cached = D.AwemeInfo(awemeID: "work", images: [item(1,a), item(2,b)])
        precondition(D.mergeLivePhotoVideos(from: cached, into: current).images[1].videoURL == b)
        let sparse = D.AwemeInfo(awemeID: "work", images: [item(1,a)])
        precondition(D.mergeLivePhotoVideos(from: sparse, into: current).images[1].videoURL == nil)
        let unrelated = D.AwemeInfo(awemeID: "other", images: [item(2,b)])
        precondition(D.mergeLivePhotoVideos(from: unrelated, into: current).images[1].videoURL == nil)
        current.images[0].videoURL = nil
        let flat = D.AwemeInfo(awemeID: "work", videos: [.init(index: 1, videoURL: a, sourceMarkedHDR: false, streamMarkedHDR: false, width: 100, height: 100)])
        precondition(D.mergeLivePhotoVideos(from: flat, into: current).images.allSatisfy { $0.videoURL == nil })
        // The actual timeline consumer must never fill an unbound image by proximity.
        let timelineBase = D.AwemeInfo(awemeID: "work", images: [item(1,a), item(2,nil), item(3,b)])
        let timeline = D.mergeTimelineLivePhotoCandidates([a,b,URL(string:"https://cdn.example.com/b.mp4?__vid=other")!], into: timelineBase)
        precondition(timeline.images.map(\.videoURL) == timelineBase.images.map(\.videoURL))
        precondition(D.mergeTimelineLivePhotoCandidates([a,b], into: .init(awemeID:"work", images:[item(1,nil)])).images[0].videoURL == nil)

        let bound = URL(string:"https://example.com/placeholder?video_id=v1234567890")!
        let recovered = URL(string:"https://cdn.example.com/motion.mp4?video_id=v1234567890&__vid=work")!
        let otherCDN = URL(string:"https://other.example.com/motion.mp4?video_id=v1234567890&__vid=work")!
        let boundInfo = D.AwemeInfo(awemeID:"work",images:[item(1,bound),item(2,nil)])
        let recoveredInfo = D.mergeTimelineLivePhotoCandidates([recovered,otherCDN],into:boundInfo)
        precondition(recoveredInfo.images[0].videoURL == recovered)
        precondition(recoveredInfo.images[0].alternateURLs == [otherCDN])
        precondition(recoveredInfo.images[1].videoURL == nil)
        let conflicting = D.AwemeInfo(awemeID:"work",images:[item(1,bound),item(2,bound)])
        precondition(D.mergeTimelineLivePhotoCandidates([recovered],into:conflicting).images.allSatisfy { $0.videoURL == bound })
        let otherWork = URL(string:"https://cdn.example.com/motion.mp4?video_id=v1234567890&__vid=other")!
        precondition(D.mergeTimelineLivePhotoCandidates([otherWork],into:boundInfo).images[0].videoURL == bound)

        typealias X = XHSNativeDownloader
        func xhsNote(_ liveIndices: Set<Int>, mobile: Bool, identity: String = "note") throws -> X.NoteInfo {
            let images: [[String: Any]] = (1...2).map { i in
                var image: [String: Any] = ["fileId":"image-\(i)", "urlDefault":"https://sns-img.xhscdn.com/image-\(i)"]
                if liveIndices.contains(i) {
                    image["stream"] = ["h264":[["masterUrl":"https://video.xhscdn.com/\(i).mp4", "width":720, "height":1280]]]
                }
                return image
            }
            var parsed = try X.parseNote(["noteId":identity,"type":"normal","imageList":images], fallbackURL: URL(string:"https://www.xiaohongshu.com/explore/\(identity)")!)
            parsed.requestUserAgent = mobile ? X.mobileUserAgent : X.desktopUserAgent
            return parsed
        }
        let desktop = try xhsNote([],mobile:false)
        let mobile = try xhsNote([1,2],mobile:true)
        precondition(X.preferredNote([desktop,mobile])!.items.allSatisfy { $0.liveURL == nil && $0.livePhotoDeclared })
        precondition(!X.noteIsLessComplete(mobile,mobile))
        precondition(!X.noteIsLessComplete(desktop,desktop))
        let sameDesktop = try xhsNote([1,2],mobile:false)
        precondition(X.preferredNote([sameDesktop,mobile])!.requestUserAgent == X.mobileUserAgent)
        precondition(X.preferredNote([mobile,sameDesktop])!.requestUserAgent == X.mobileUserAgent)
        let partial = X.preferredNote([try xhsNote([1],mobile:false),try xhsNote([2],mobile:true)])!
        precondition(partial.items.allSatisfy { $0.liveURL == nil && $0.livePhotoDeclared })
        let otherNote = try xhsNote([1,2],mobile:true,identity:"other")
        precondition(X.preferredNote([desktop,otherNote])!.items.allSatisfy { $0.liveURL == nil })
        var highQuality = sameDesktop
        highQuality.items[0].liveScore += 1
        highQuality.items[0].imageQuality += 1
        highQuality.items[0].imageURL = URL(string:"https://sns-img.xhscdn.com/high-quality")!
        let richer = X.preferredNote([mobile,highQuality])!
        precondition(richer.items[0].liveURL == nil)
        precondition(richer.items[0].imageURL == highQuality.items[0].imageURL)
        var videoDesktop = X.NoteInfo(noteID:"video",type:"video",videoURL:a,videoScore:100)
        videoDesktop.requestUserAgent = X.desktopUserAgent
        videoDesktop.videoFromAppCache = true
        videoDesktop.usedAppCache = true
        var videoMobile = videoDesktop
        videoMobile.requestUserAgent = X.mobileUserAgent
        videoMobile.videoScore = 1
        precondition(X.preferredNote([videoDesktop,videoMobile])!.requestUserAgent == X.desktopUserAgent)

        // Ordinary videos use their cloud upload key even when playback metadata
        // advertises a smaller web rendition or a highly scored HDR variant.
        let originVideoID = "fedcba987654321001234567"
        let originFallback = URL(string: "https://www.xiaohongshu.com/discovery/item/\(originVideoID)")!
        let webPlaybackURL = "https://sns-video.xhscdn.com/stream/1/web-720p.mp4"
        let hdrPlaybackURL = "https://sns-video.xhscdn.com/playback-hdr10.mp4"
        func originVideoNote(_ key: Any?) -> [String: Any] {
            var consumer: [String: Any] = [:]
            if let key { consumer["originVideoKey"] = key }
            return ["noteId": originVideoID, "type": "video", "hdr_type": 2,
                "user": ["nickname": "Video fixture author", "redId": "video.fixture.account"],
                "video": ["consumer": consumer, "media": ["video": ["hdr_type": 2], "stream": [
                    "h264": [["masterUrl": webPlaybackURL, "backupUrls": ["https://sns-bak.xhscdn.com/web-720p.mp4"],
                        "width": 720, "height": 1280, "videoBitrate": 900_000]],
                    "h265": [["masterUrl": hdrPlaybackURL, "width": 2160, "height": 3840,
                        "videoBitrate": 20_000_000, "hdrType": 2, "dynamicRange": "HDR10", "fps": 60]]
                ]]]]
        }
        for key in ["1040g0_fixture-raw", "spectrum/1040g0_fixture-raw"] {
            let cloudVideo = try X.parseNote(originVideoNote(key), fallbackURL: originFallback)
            let expectedOriginal = URL(string: "https://sns-video-bd.xhscdn.com/" + key)!
            precondition(cloudVideo.originalVideoURL == expectedOriginal && cloudVideo.videoURL == expectedOriginal && cloudVideo.videoURLs == [expectedOriginal],
                "The exact original upload key must be the only video source; web and HDR playback renditions cannot be fallbacks")
            precondition(cloudVideo.items.isEmpty && cloudVideo.videoHDRHint == nil,
                "Playback HDR hints must not trigger remuxing or infer color information for the untouched upload")
            precondition(!cloudVideo.usedAppCache && !X.shouldRefreshClientCache(for: cloudVideo),
                "An available cloud original satisfies source discovery without a forced client-cache refresh")
        }
        let evolvedVideo = try X.parseNote(["noteId": originVideoID, "type": "video", "video": [
            "resources": [["role": "original", "url": "https://sns-video-qc.xhscdn.com/upload_v5/region/original.mov?sign=fixture",
                "backup_urls": ["https://sns-bak-v6.xhscdn.com/upload_v5/region/original.mov?sign=backup"]]]]], fallbackURL: originFallback)
        precondition(evolvedVideo.originalVideoURLs.count == 2 && evolvedVideo.originalVideoURL?.host == "sns-video-qc.xhscdn.com", "Video source schema evolution must preserve supplied originals and backups")
        let invalidOriginKeys: [Any?] = [nil, "", "/leading-slash", "../other", "spectrum/../other",
            "https://example.com/other", "key?rendition=720", "key#fragment", "key with spaces",
            "key\nwith-newline", 12345, true, NSNull(), ["url": webPlaybackURL], [12345, NSNull()]]
        for key in invalidOriginKeys {
            let unavailableOriginal = try X.parseNote(originVideoNote(key), fallbackURL: originFallback)
            precondition(unavailableOriginal.noteID == originVideoID && unavailableOriginal.type == "video")
            precondition(!unavailableOriginal.hasMedia && unavailableOriginal.originalVideoURL == nil
                && unavailableOriginal.videoURL == nil && unavailableOriginal.videoURLs.isEmpty,
                "Missing or malformed original keys must preserve identity for exact-note cache lookup without accepting a playback or arbitrary URL")
            precondition(X.shouldRefreshClientCache(for: unavailableOriginal),
                "A regular video without an original or exact-note cache source must refresh the client cache")
        }
        let cache1080URL = URL(string: "https://sns-video.xhscdn.com/cache-video-1080p.mp4")!
        let cache1080Backup = URL(string: "https://sns-video-bak.xhscdn.com/cache-video-1080p.mp4")!
        let cache720URL = URL(string: "https://sns-video.xhscdn.com/stream/1/cache-video-720p.mp4")!
        func appVideoSnapshot(_ identity: String = originVideoID, highResolution: Bool = true) -> [String: Any] {
            var renditions: [[String: Any]] = [["url": cache720URL.absoluteString, "width": 720, "height": 1280,
                "avg_bitrate": 1_000_000, "desc": "720P H264"]]
            if highResolution {
                renditions.append(["url": cache1080URL.absoluteString, "backup_urls": [cache1080Backup.absoluteString],
                    "width": 1080, "height": 1920, "avg_bitrate": 2_500_000, "desc": "1080P H264"])
            }
            return ["id": identity, "type": "video", "video": ["url": cache720URL.absoluteString, "url_info_list": renditions]]
        }
        let cachedVideo = X.parseAppNote(appVideoSnapshot(), expectedID: originVideoID, fallbackURL: originFallback)!
        precondition(cachedVideo.usedAppCache && cachedVideo.videoFromAppCache && cachedVideo.originalVideoURL == nil)
        precondition(cachedVideo.videoURL == cache1080URL && cachedVideo.videoURLs == [cache1080URL, cache1080Backup],
            "A cached 1080p video must outrank a /stream/1/ 720p variant and retain only its explicit backups")
        var smallerCachedVideo = X.parseAppNote(appVideoSnapshot(highResolution: false), expectedID: originVideoID, fallbackURL: originFallback)!
        smallerCachedVideo.requestUserAgent = X.desktopUserAgent
        precondition(X.preferredNote([smallerCachedVideo, cachedVideo])!.videoURL == cache1080URL,
            "Desktop provenance and playback path bonuses must not make a smaller cache video win")
        let noOriginalVideo = try X.parseNote(originVideoNote(nil), fallbackURL: originFallback)
        let cacheOnlyVideo = X.preferredNote([noOriginalVideo, cachedVideo])!
        precondition(cacheOnlyVideo.videoURL == cache1080URL && cacheOnlyVideo.videoURLs == [cache1080URL, cache1080Backup]
            && cacheOnlyVideo.videoFromAppCache && cacheOnlyVideo.usedAppCache,
            "An unavailable original must use only the highest-quality exact-note client-cache rendition")
        precondition(cacheOnlyVideo.author == "Video fixture author" && cacheOnlyVideo.userID == "video.fixture.account",
            "Client video selection must preserve author and account metadata from the matching web note")
        precondition(X.shouldRefreshClientCache(for: cacheOnlyVideo))
        let originalVideo = try X.parseNote(originVideoNote("spectrum/original_fixture"), fallbackURL: originFallback)
        let preferredOriginal = X.preferredNote([originalVideo, smallerCachedVideo, cachedVideo])!
        precondition(preferredOriginal.originalVideoURL == originalVideo.originalVideoURL
            && preferredOriginal.videoURL == originalVideo.videoURL
            && preferredOriginal.videoURLs == [originalVideo.videoURL!, cache1080URL, cache1080Backup],
            "The cloud original must remain first with only the best exact-note client rendition as its fallback")
        precondition(preferredOriginal.videoHDRHint == nil, "Cached playback metadata must not trigger remuxing of raw original bytes")
        for forbidden in [webPlaybackURL, hdrPlaybackURL, cache720URL.absoluteString] {
            precondition(!preferredOriginal.videoURLs.contains(URL(string: forbidden)!))
        }
        precondition(X.parseAppNote(appVideoSnapshot(), expectedID: "ffffffffffffffffffffffff", fallbackURL: originFallback) == nil)
        let unrelatedVideo = X.parseAppNote(appVideoSnapshot("ffffffffffffffffffffffff"),
            expectedID: "ffffffffffffffffffffffff", fallbackURL: originFallback)!
        precondition(X.preferredNote([originalVideo, unrelatedVideo])!.videoURLs == originalVideo.videoURLs,
            "A cached video belonging to another note must never become an original's fallback")
        for malformedVideo: [String: Any] in [[:], ["url_info_list": []], ["url": "file:///tmp/unrelated.mp4"],
            ["url_info_list": [["url": "not a video URL", "width": 1080, "height": 1920]]]] {
            precondition(X.parseAppNote(["id": originVideoID, "type": "video", "video": malformedVideo],
                expectedID: originVideoID, fallbackURL: originFallback) == nil,
                "Malformed client video records must not count as fallback sources")
        }
        let slowVideoURL = URL(string: "https://sns-video.xhscdn.com/client-variant-slow.mp4")!
        let fastVideoURL = URL(string: "https://sns-video.xhscdn.com/client-variant-fast.mp4")!
        func frameRateVariant(_ url: URL, bitrate: Int, fpsKey: String? = nil, fps: Int? = nil,
            description: String = "1080P H265 HDR10") -> [String: Any] {
            var item: [String: Any] = ["url": url.absoluteString, "master_url": url.absoluteString,
                "width": 1080, "height": 1920, "avg_bitrate": bitrate, "desc": description, "format": "HDR10"]
            if let fpsKey, let fps { item[fpsKey] = fps }
            return item
        }
        func frameRateClient(_ variants: [[String: Any]], legacy: Bool = false,
            sourceMeta: [String: Any] = [:]) -> X.NoteInfo {
            let video: [String: Any] = legacy ? ["url_info_list": variants]
                : ["media": ["video": sourceMeta, "stream": ["h265": variants]]]
            return X.parseAppNote(["id": originVideoID, "type": "video", "video": video],
                expectedID: originVideoID, fallbackURL: originFallback)!
        }
        for fpsKey in ["fps", "frameRate", "frame_rate"] {
            let highFrameRate = frameRateClient([
                frameRateVariant(slowVideoURL, bitrate: 8_000_000, fpsKey: fpsKey, fps: 30),
                frameRateVariant(fastVideoURL, bitrate: 1_000_000, fpsKey: fpsKey, fps: 60)
            ])
            precondition(highFrameRate.videoURL == fastVideoURL && highFrameRate.videoURLs == [fastVideoURL],
                "At equal stream HDR and resolution, explicit 60fps must outrank 30fps even when the latter has a higher bitrate")
        }
        let legacyHighFrameRate = frameRateClient([
            frameRateVariant(slowVideoURL, bitrate: 8_000_000, description: "1080P H265 HDR10 30FPS"),
            frameRateVariant(fastVideoURL, bitrate: 1_000_000, description: "1080P H265 HDR10 60FPS")
        ], legacy: true)
        precondition(legacyHighFrameRate.videoURL == fastVideoURL,
            "Legacy url_info_list desc must supply a stream's 60FPS hint without relying on URL filenames")
        for textKey in ["format", "streamDesc", "stream_desc", "fpsType"] {
            var slowText = frameRateVariant(slowVideoURL, bitrate: 8_000_000)
            var fastText = frameRateVariant(fastVideoURL, bitrate: 1_000_000)
            slowText[textKey] = "HDR10 30FPS"
            fastText[textKey] = "HDR10 60FPS"
            precondition(frameRateClient([slowText, fastText]).videoURL == fastVideoURL,
                "A stream's format/description/type FPS hints must participate in ordinary video selection")
        }
        let explicitFPSWins = frameRateClient([
            frameRateVariant(slowVideoURL, bitrate: 8_000_000, fpsKey: "fps", fps: 30, description: "1080P H265 HDR10 240FPS"),
            frameRateVariant(fastVideoURL, bitrate: 1_000_000, fpsKey: "fps", fps: 60, description: "1080P H265 HDR10 30FPS")
        ])
        precondition(explicitFPSWins.videoURL == fastVideoURL,
            "A valid explicit stream frame rate must take precedence over conflicting description text")
        for invalidFPS: Any in ["unknown", "NaN", Double.nan, Double.infinity, "1e100", -1, 0, 999_999, NSNull()] {
            var unknownFPS = frameRateVariant(slowVideoURL, bitrate: 8_000_000)
            unknownFPS["fps"] = invalidFPS
            precondition(frameRateClient([
                unknownFPS, frameRateVariant(fastVideoURL, bitrate: 1_000_000, fpsKey: "fps", fps: 60)
            ]).videoURL == fastVideoURL,
                "Unknown, non-finite and out-of-range FPS must not crash or outrank a valid 60fps stream")
        }
        var smallHighFPS = frameRateVariant(fastVideoURL, bitrate: 8_000_000, fpsKey: "fps", fps: 120)
        smallHighFPS["width"] = 720
        smallHighFPS["height"] = 1280
        precondition(frameRateClient([
            smallHighFPS, frameRateVariant(slowVideoURL, bitrate: 1_000_000, fpsKey: "fps", fps: 30)
        ]).videoURL == slowVideoURL, "At equal stream HDR, resolution must outrank FPS")
        let sourceFPSOnly = frameRateClient([
            frameRateVariant(slowVideoURL, bitrate: 8_000_000),
            frameRateVariant(fastVideoURL, bitrate: 1_000_000, fpsKey: "fps", fps: 60)
        ], sourceMeta: ["fps": 120, "frameRate": 120, "frame_rate": 120, "hdr_type": 2])
        precondition(sourceFPSOnly.videoURL == fastVideoURL,
            "An upload-level 120fps marker must not be inherited by a stream whose own frame rate is unknown")
        var sourceOnlySDR = frameRateVariant(fastVideoURL, bitrate: 8_000_000, fpsKey: "fps", fps: 60, description: "1080P H265 SDR")
        sourceOnlySDR["format"] = "SDR"
        let actualHDRStream = frameRateClient([
            sourceOnlySDR, frameRateVariant(slowVideoURL, bitrate: 1_000_000, fpsKey: "fps", fps: 30)
        ], sourceMeta: ["hdr_type": 2, "dynamic_range": "HDR10", "fps": 120])
        precondition(actualHDRStream.videoURL == slowVideoURL,
            "Stream HDR must outrank FPS; a source-only HDR marker must not promote the SDR 60fps stream")
        let originalWith60FPSFallback = X.preferredNote([originalVideo, legacyHighFrameRate])!
        precondition(originalWith60FPSFallback.videoURL == originalVideo.videoURL
            && originalWith60FPSFallback.videoURLs == [originalVideo.videoURL!, fastVideoURL]
            && originalWith60FPSFallback.videoHDRHint == nil,
            "A 60fps HDR cache candidate must remain a fallback behind the same note's untouched cloud original")
        var otherNote60FPS = legacyHighFrameRate
        otherNote60FPS.noteID = "ffffffffffffffffffffffff"
        var otherNoteOriginal = try X.parseNote(originVideoNote("spectrum/other_note_original"), fallbackURL: originFallback)
        otherNoteOriginal.noteID = otherNote60FPS.noteID
        precondition(X.preferredNote([originalVideo, otherNoteOriginal, otherNote60FPS])!.videoURLs == originalVideo.videoURLs,
            "An unrelated note's original and 60fps HDR cache stream must never be treated as versions of this work")
        precondition(!X.preferredNote([noOriginalVideo, otherNote60FPS])!.hasMedia,
            "A missing original cannot be rescued by another note's higher-specification client video")
        print("PASS: XHS client video FPS ranks after stream HDR/resolution and before bitrate; stream-only hints and exact-note original priority")
        print("PASS: XHS regular video prefers the exact cloud original, then highest-quality exact-note client cache without web fallback")

        // Client snapshots use a different schema and carry the AAC motion source.
        // All images in the real response report index=0; bind only by unique fileid.
        let noteID = "0123456789abcdef01234567"
        let fallback = URL(string: "https://www.xiaohongshu.com/discovery/item/\(noteID)")!
        var web = try xhsNote([1,2], mobile:true, identity:noteID)
        func appImage(_ number: Int, audio: Bool = true) -> [String: Any] {
            ["fileid":"image-\(number)", "index":0, "original":"https://sns-img.xhscdn.com/image-\(number)",
             "live_photo":["media":["stream":["h265":[["master_url":"https://sns-video.xhscdn.com/client-\(number).mp4",
                "backup_urls":["https://sns-bak.xhscdn.com/client-\(number).mp4"],
                "width":720,"height":1280,"audio_channels":audio ? 2 : 0,"audio_bitrate":audio ? 60000 : 0]]]]]]
        }
        var appNote: [String: Any] = ["id":noteID,"type":"normal","images_list":[appImage(2),appImage(1)]]
        let client = X.parseAppNote(appNote,expectedID:noteID,fallbackURL:fallback)!
        let combined = X.preferredNote([web,client])!
        precondition(combined.items[0].liveURL!.lastPathComponent == "client-1.mp4")
        precondition(combined.items[1].liveURL!.lastPathComponent == "client-2.mp4")
        precondition(combined.items.allSatisfy { $0.liveHasAudio && $0.audioURLs.count == 2 })
        precondition(combined.items.map(\.imageURL) == web.items.map(\.imageURL))
        precondition(!combined.items[0].liveURLs.contains(web.items[0].liveURL!))
        precondition(combined.items.allSatisfy { $0.liveFromAppCache })
        precondition(combined.usedAppCache)
        precondition(X.parseAppNote(appNote,expectedID:"ffffffffffffffffffffffff",fallbackURL:fallback) == nil)
        appNote["images_list"] = [appImage(1),appImage(1)]
        precondition(X.parseAppNote(appNote,expectedID:noteID,fallbackURL:fallback) == nil)
        appNote["images_list"] = [appImage(2)]
        let sparseClient = X.parseAppNote(appNote,expectedID:noteID,fallbackURL:fallback)!
        let sparseCombined = X.preferredNote([web,sparseClient])!
        precondition(sparseCombined.items[0].liveURL == nil && sparseCombined.items[1].liveFromAppCache)
        web.items[0].liveScore = Int64.max / 4
        precondition(X.preferredNote([web,client])!.items[0].liveHasAudio)
        appNote["images_list"] = [appImage(2, audio:false),appImage(1, audio:false)]
        let silentClient = X.parseAppNote(appNote,expectedID:noteID,fallbackURL:fallback)!
        let silentCombined = X.preferredNote([web,silentClient])!
        precondition(silentCombined.items.allSatisfy { $0.liveFromAppCache && !$0.liveHasAudio })
        precondition(silentCombined.items.map(\.liveURL) == combined.items.map(\.liveURL))
        precondition(X.shouldRefreshClientCache(for:silentCombined), "A playback-only snapshot must refresh to discover its original, regardless of audio metadata")
        precondition(X.shouldRefreshClientCache(for:sparseCombined))
        precondition(X.livePhotoDownloadTask(web.items[0],destination:URL(fileURLWithPath:"/tmp/web-live.mp4")) == nil)
        var higherQuality = appImage(1, audio:false)
        higherQuality["live_photo"] = ["media":["stream":["h265":[[
            "master_url":"https://sns-video.xhscdn.com/client-hires.mp4","width":1440,"height":2560,"audio_channels":0]]]]]
        let highQualityClient = X.parseAppNote(["id":noteID,"type":"normal","images_list":[higherQuality]],expectedID:noteID,fallbackURL:fallback)!
        let qualityPreferred = X.preferredNote([web,client,highQualityClient])!
        precondition(qualityPreferred.items[0].liveURL == highQualityClient.items[0].liveURL,
            "Audio metadata must not outrank client stream quality")
        var misleading = appImage(1)
        misleading["live_photo"] = ["media":["stream":["h264":[[
            "master_url":"https://sns-video.xhscdn.com/stream/1/10/19/watermarked.mp4", "stream_type":19,
            "stream_desc":"WEB_LIVEPHOTO_19", "width":4000,"height":4000,"audio_channels":2]]]]]
        let watermarked = X.parseAppNote(["id":noteID,"type":"normal","images_list":[misleading]],expectedID:noteID,fallbackURL:fallback)!
        precondition(watermarked.items[0].liveURL == nil && watermarked.items[0].livePhotoDeclared)
        print("PASS: exact-ID client Live Photos with or without audio metadata; no web motion fallback or watermarked rendition")

        // The client's upload key is a separate source from its playback stream.
        // Keep that key bound to the same note and unique still-image fileid.
        // Mixed namespaces also exercise reversed arrays, sparse data and revisions.
        let sourceKeys = [
            "livephoto_pre_post/1040g398325rhvd944q8g5onncaqnqnmqsnpi001",
            "livephoto/1040g398325rhvd944q8g5onncaqnqnmqsnpi002"
        ]
        func liveOriginalURLs(_ key: String) -> [URL] {
            [URL(string: "https://sns-video-bd.xhscdn.com/" + key)!,
             URL(string: "https://sns-bak-v6.xhscdn.com/" + key)!]
        }
        func originalAppImage(_ number: Int, stream: Bool = true, audio: Bool = false) -> [String: Any] {
            var image = appImage(number, audio: audio)
            image["live_photo_file_id"] = sourceKeys[number - 1]
            if !stream { image.removeValue(forKey: "live_photo") }
            return image
        }
        func originalClient(_ images: [[String: Any]], identity: String? = nil) -> X.NoteInfo? {
            let exactID = identity ?? noteID
            return X.parseAppNote(["id": exactID, "type": "normal", "images_list": images],
                expectedID: exactID, fallbackURL: fallback)
        }
        let sourceClient = originalClient([originalAppImage(2), originalAppImage(1)])!
        for media in sourceClient.items {
            let number = media.fileID == "image-1" ? 1 : 2
            let originals = liveOriginalURLs(sourceKeys[number - 1])
            precondition(media.livePhotoFileID == sourceKeys[number - 1])
            precondition(media.liveOriginalURLs == originals && media.liveURL == originals[0])
            precondition(Array(media.liveURLs.prefix(originals.count)) == originals,
                "Upload originals must precede the exact client's playback stream")
            precondition(media.liveURLs.contains(URL(string: "https://sns-video.xhscdn.com/client-\(number).mp4")!))
            precondition(media.liveFromAppCache && media.livePhotoDeclared && !media.liveHasAudio,
                "A silent upload source is usable without inventing audio metadata")
            let task = X.livePhotoDownloadTask(media, destination: URL(fileURLWithPath: "/tmp/source-\(number).mp4"))!
            precondition(task.urls == media.liveURLs && task.originalLivePhotoURLs == Set(originals),
                "The transfer must distinguish upload originals from playback fallbacks")
        }
        let keyOnlyClient = originalClient([originalAppImage(1, stream: false)])!
        let keyOnly = keyOnlyClient.items[0]
        precondition(keyOnly.liveURL == liveOriginalURLs(sourceKeys[0])[0] && keyOnly.livePhotoDeclared)
        precondition(keyOnly.liveURLs == liveOriginalURLs(sourceKeys[0]) && keyOnly.liveFromAppCache)
        precondition(!X.shouldRefreshClientCache(for: keyOnlyClient),
            "An exact upload key is a complete motion source even when stream metadata is absent")
        precondition(X.livePhotoDownloadTask(keyOnly, destination: URL(fileURLWithPath: "/tmp/key-only.mp4")) != nil)

        // Namespace evolution does not require another directory whitelist.
        for key in ["motion_upload_v3/region/a.mov", "notes_pre_post/object-3", "livephoto_pre_post_other/object_4"] {
            var image = appImage(1)
            image["live_photo_file_id"] = key
            let evolved = originalClient([image])!.items[0]
            precondition(evolved.livePhotoFileID == key && evolved.liveOriginalURLs == liveOriginalURLs(key),
                "An exact original role must accept a future safe object namespace")
        }
        let suppliedOriginal = URL(string: "https://sns-video-qc.xhscdn.com/motion_v4/region/object.mov?sign=offline&expires=123")!
        var schemaImage = appImage(1)
        schemaImage["live_photo"] = ["media": ["resources": [["role": "original", "url": suppliedOriginal.absoluteString,
            "backup_urls": [suppliedOriginal.absoluteString.replacingOccurrences(of: "sns-video-qc", with: "sns-bak-v6")]]]]]
        let discoveredSchema = originalClient([schemaImage])!.items[0]
        precondition(discoveredSchema.livePhotoFileID == "motion_v4/region/object.mov")
        precondition(discoveredSchema.liveOriginalURLs.first == suppliedOriginal
            && discoveredSchema.liveOriginalURLs.count == 2, "Keep actual signed original/backup URLs instead of guessing new hosts")
        precondition(discoveredSchema.liveOriginalFields[suppliedOriginal]?.contains("resources") == true,
            "Retain the field evidence for future schema diagnosis")
        let rawWeb = try X.parseNote(["noteId": noteID, "type": "normal", "imageList": [[
            "fileId": "image-1", "url": "https://sns-img.xhscdn.com/image-1", "livePhotoOriginalURL": suppliedOriginal.absoluteString]]], fallbackURL: fallback)
        precondition(X.preferredNote([rawWeb])!.items[0].liveURL == suppliedOriginal,
            "An exact original supplied by current web metadata must not require a local cache")
        let misleadingSources: [[String: Any]] = [
            ["live_photo": ["media": ["stream": ["h265": [["master_url": suppliedOriginal.absoluteString]]]]]],
            ["live_photo": ["unknown_url": suppliedOriginal.absoluteString]],
            ["live_photo": ["original_url": "https://example.com/motion_v4/object.mov"]],
            ["live_photo": ["original_url": "https://sns-video-qc.xhscdn.com/stream/1/10/66/a.mp4"]],
            ["live_photo": ["original_url": suppliedOriginal.absoluteString + "&resize=720"]],
            ["other_image": ["original_motion_url": suppliedOriginal.absoluteString]]
        ]
        for misleading in misleadingSources {
            precondition(X.discoverMotionOriginals(in: misleading).urls.isEmpty,
                "Playback scores, arbitrary fields, foreign hosts and transforms must not establish original provenance")
        }
        var conflictingImage = schemaImage
        conflictingImage["live_photo_file_id"] = "motion_v4/a_different_object.mov"
        precondition(X.discoverMotionOriginals(in: conflictingImage).urls.isEmpty, "Competing object identities remain unconfirmed")
        precondition(X.shouldRefreshClientCache(for: originalClient([appImage(1)])!),
            "Existing playback is not evidence that no cloud original exists")
        print("PASS: future namespaces, scoped original-role schema discovery, signed backups, web originals, field evidence and ambiguity rejection")

        let voicedPlaybackClient = originalClient([appImage(1, audio: true)])!
        for snapshots in [[web, voicedPlaybackClient, sourceClient], [web, sourceClient, voicedPlaybackClient]] {
            let preferredOriginal = X.preferredNote(snapshots)!.items[0]
            precondition(preferredOriginal.liveURL == liveOriginalURLs(sourceKeys[0])[0]
                && preferredOriginal.livePhotoFileID == sourceKeys[0],
                "A voiced playback stream must not displace its exact pre-post cloud original")
            precondition(preferredOriginal.liveAudioURLs.contains(voicedPlaybackClient.items[0].liveURL!),
                "The same-image voiced stream remains an audio donor after probing the original")
        }

        let highSilentStream = URL(string: "https://sns-video.xhscdn.com/high-silent.mp4")!
        let lowerAudioStream = URL(string: "https://sns-video.xhscdn.com/lower-audio.mp4")!
        let forbiddenAudioStream = URL(string: "https://sns-video.xhscdn.com/stream/1/10/19/audio-watermarked.mp4")!
        var donorImage = originalAppImage(1)
        donorImage["live_photo"] = ["media": ["stream": [
            "h265": [["master_url": highSilentStream.absoluteString, "width": 1440, "height": 2560, "audio_channels": 0]],
            "h264": [
                ["master_url": lowerAudioStream.absoluteString, "width": 720, "height": 1280, "audio_channels": 2],
                ["master_url": forbiddenAudioStream.absoluteString, "width": 4000, "height": 4000, "stream_type": 19, "audio_channels": 2]]]]]
        let parsedDonors = originalClient([donorImage])!.items[0]
        precondition(parsedDonors.liveAudioURLs.contains(highSilentStream) && parsedDonors.liveAudioURLs.contains(lowerAudioStream),
            "Every exact client rendition must remain available for actual audio probing, including absent audio metadata")
        precondition(!parsedDonors.liveAudioURLs.contains(forbiddenAudioStream),
            "A web watermarked rendition must not become an audio donor")
        donorImage.removeValue(forKey: "live_photo_file_id")
        let keylessDonors = originalClient([donorImage])!.items[0]
        precondition(keylessDonors.liveURL == highSilentStream && keylessDonors.liveOriginalURLs.isEmpty)
        precondition(keylessDonors.liveAudioURLs.contains(lowerAudioStream),
            "A lower-resolution audio donor must not replace the best keyless client video")

        // A later, larger playback rendition cannot erase an older upload key.
        // Reversed client image arrays and sparse snapshots must preserve web order.
        for snapshots in [[web, highQualityClient, sourceClient], [web, sourceClient, highQualityClient]] {
            let originalsPreferred = X.preferredNote(snapshots)!
            precondition(originalsPreferred.items.map(\.fileID) == web.items.map(\.fileID))
            for (offset, media) in originalsPreferred.items.enumerated() {
                let originals = liveOriginalURLs(sourceKeys[offset])
                precondition(media.livePhotoFileID == sourceKeys[offset] && media.liveOriginalURLs == originals)
                precondition(media.liveURL == originals[0] && Array(media.liveURLs.prefix(2)) == originals,
                    "Original provenance must outrank playback pixels in either snapshot order")
            }
            precondition(originalsPreferred.items[0].liveURLs.contains(highQualityClient.items[0].liveURL!),
                "The higher-quality exact client stream remains available after original-source failure")
        }
        let sparseSource = originalClient([originalAppImage(2, stream: false)])!
        let sparseSourcesMerged = X.preferredNote([web, highQualityClient, sparseSource])!
        precondition(sparseSourcesMerged.items[0].liveOriginalURLs.isEmpty)
        precondition(sparseSourcesMerged.items[0].liveURL == highQualityClient.items[0].liveURL)
        precondition(sparseSourcesMerged.items[1].liveOriginalURLs == liveOriginalURLs(sourceKeys[1]),
            "Sparse upload keys bind by fileid rather than snapshot array position")
        let olderKey = "livephoto/1040g398325rhvd944q8g5onncaqnqnmqsnpi009"
        let olderPlayback = URL(string: "https://sns-video.xhscdn.com/older-revision.mp4")!
        let olderPlaybackBackup = URL(string: "https://sns-bak.xhscdn.com/older-revision.mp4")!
        var olderKeyImage = originalAppImage(1)
        olderKeyImage["live_photo_file_id"] = olderKey
        olderKeyImage["live_photo"] = ["media": ["stream": ["h265": [[
            "master_url": olderPlayback.absoluteString, "backup_urls": [olderPlaybackBackup.absoluteString],
            "width": 4000, "height": 4000, "audio_channels": 2, "audio_bitrate": 128000]]]]]
        let olderKeyClient = originalClient([olderKeyImage])!
        let rejectedRevisionURLs = Set(liveOriginalURLs(olderKey) + [olderPlayback, olderPlaybackBackup])
        func assertLatestMotionRevision(_ media: X.MediaItem) {
            precondition(media.livePhotoFileID == sourceKeys[0] && media.liveOriginalURLs == liveOriginalURLs(sourceKeys[0]))
            precondition(media.liveURL == liveOriginalURLs(sourceKeys[0])[0])
            precondition(!media.liveURLs.contains(where: { rejectedRevisionURLs.contains($0) }),
                "An older changed upload key must not contribute any original or playback fallback")
            precondition(!media.liveAudioURLs.contains(where: { rejectedRevisionURLs.contains($0) }),
                "An older changed upload key must not donate sound to the latest motion revision")
        }
        let conflictingSnapshots = X.preferredNote([web, sourceClient, olderKeyClient])!
        assertLatestMotionRevision(conflictingSnapshots.items[0])
        let latestKeyClient = originalClient([originalAppImage(1)])!
        precondition(X.noteIsLessComplete(latestKeyClient, olderKeyClient),
            "The older revision must have a higher raw score to expose cache-only base contamination")
        let cacheOnlyRevisions = X.preferredNote([latestKeyClient, olderKeyClient])!
        assertLatestMotionRevision(cacheOnlyRevisions.items[0])
        let keylessPlayback = URL(string: "https://sns-video.xhscdn.com/trusted-keyless.mp4")!
        var trustedKeylessImage = appImage(1)
        trustedKeylessImage["live_photo"] = ["media": ["stream": ["h265": [[
            "master_url": keylessPlayback.absoluteString, "width": 2000, "height": 3000,
            "audio_channels": 2, "audio_bitrate": 96000]]]]]
        let trustedKeylessClient = originalClient([trustedKeylessImage])!
        let revisionsWithKeyless = X.preferredNote([web, latestKeyClient, olderKeyClient, trustedKeylessClient])!
        assertLatestMotionRevision(revisionsWithKeyless.items[0])
        precondition(revisionsWithKeyless.items[0].liveURLs.contains(keylessPlayback)
            && revisionsWithKeyless.items[0].liveAudioURLs.contains(keylessPlayback),
            "A same-fileid snapshot without a conflicting key remains a trusted playback and audio source")
        print("PASS: changed upload keys isolate playback/audio revisions before web or cache-only base selection; trusted keyless sources remain usable")
        let unrelatedSource = originalClient([originalAppImage(1)], identity: "ffffffffffffffffffffffff")!
        precondition(X.preferredNote([web, unrelatedSource])!.items.allSatisfy { $0.liveOriginalURLs.isEmpty },
            "A key from another note must never repair this note")
        var differentStill = originalAppImage(1)
        differentStill["fileid"] = "different-still"
        differentStill["original"] = "https://sns-img.xhscdn.com/different-still"
        let differentStillClient = originalClient([differentStill])!
        precondition(X.preferredNote([web, differentStillClient])!.items.allSatisfy { $0.liveOriginalURLs.isEmpty },
            "A key for another image must not be borrowed by matching array index")

        let invalidSourceKeys = ["livephoto", "livephoto_pre_post"].flatMap { namespace in
            ["../\(namespace)/foreign", "\(namespace)/../other", "\(namespace)/./other",
             "\(namespace)/%2e%2e/other", "\(namespace)/a%2fb", "\(namespace)/a\\b",
             "\(namespace)/", "\(namespace)/a?sign=foreign", "\(namespace)/a#fragment",
             "/\(namespace)/foreign", "https://example.com/\(namespace)/foreign",
             "\(namespace)/with space", "\(namespace)/\nforeign"]
        } + ["stream/1/10/66/foreign.mp4", "https://xhscdn.com.evil.example/livephoto/foreign", "livephoto/a!resize"]
        for invalidKey in invalidSourceKeys {
            var image = appImage(1)
            image["live_photo_file_id"] = invalidKey
            let rejectedKey = originalClient([image])!
            precondition(rejectedKey.items[0].livePhotoFileID == nil && rejectedKey.items[0].liveOriginalURLs.isEmpty,
                "Malformed source keys must not construct arbitrary CDN paths: \(invalidKey)")
            precondition(rejectedKey.items[0].liveURL == client.items[1].liveURL,
                "A rejected key must retain its own valid client playback fallback")
        }
        var duplicatedKeyImage = originalAppImage(2)
        duplicatedKeyImage["live_photo_file_id"] = sourceKeys[0]
        let duplicateKeySnapshot = originalClient([originalAppImage(1), duplicatedKeyImage])
        precondition(duplicateKeySnapshot == nil || duplicateKeySnapshot!.items.allSatisfy { $0.liveOriginalURLs.isEmpty },
            "One upload key claimed by different stills is ambiguous and cannot be bound to either")
        let ambiguousSnapshots = X.preferredNote([
            web, originalClient([originalAppImage(1)])!, originalClient([duplicatedKeyImage])!
        ])!
        precondition(ambiguousSnapshots.items.allSatisfy { $0.livePhotoFileID == nil && $0.liveOriginalURLs.isEmpty },
            "A key reused by different stills across separate snapshots must remain unbound")
        precondition(ambiguousSnapshots.items.map(\.liveURL) == combined.items.map(\.liveURL),
            "Rejecting an ambiguous cross-snapshot key must retain each still's own client stream")
        let plainStill = originalClient([["fileid": "image-1", "original": "https://sns-img.xhscdn.com/image-1"]])!
        precondition(plainStill.items[0].livePhotoFileID == nil && plainStill.items[0].liveOriginalURLs.isEmpty)
        precondition(plainStill.items[0].liveURL == nil && !plainStill.items[0].livePhotoDeclared,
            "An ordinary still must not acquire synthetic motion")
        print("PASS: upload Live Photo source priority, key-only/silent originals, identity-safe snapshot merge and malformed/ambiguous key rejection")
        let signedWebURLs = (1...4).map { number in
            URL(string: "https://sns-webpic-qc.xhscdn.com/202610011200/web-signature/notes_pre_post/still-\(number)!web-display")!
        }
        let signedClientURLs = (1...4).map { number in
            URL(string: "https://sns-na-i6.xhscdn.com/notes_pre_post/still-\(number)?imageView2/2/w/5000/h/5000/format/webp/q/90&ap=1&sc=ORIGINAL&sign=fixture")!
        }
        let stillWeb = try X.parseNote(["noteId": noteID, "type": "normal", "imageList": (1...4).map { number in
            ["fileId": "notes_pre_post/still-\(number)", "url": signedWebURLs[number - 1].absoluteString,
             "stream": ["h264": [["master_url": "https://sns-video.xhscdn.com/motion-\(number).mp4"]]]]
        }], fallbackURL: fallback)
        let stillClient = X.parseAppNote(["id": noteID, "type": "normal", "images_list": (1...4).map { number in
            ["fileid": "notes_pre_post/still-\(number)", "original": signedClientURLs[number - 1].absoluteString]
        }], expectedID: noteID, fallbackURL: fallback)!
        let stillCombined = X.preferredNote([stillWeb, stillClient])!
        precondition(stillCombined.items.count == 4 && stillCombined.usedAppCache)
        for (offset, media) in stillCombined.items.enumerated() {
            precondition(media.imageURL == stillWeb.items[offset].imageURL, "The preferred original must remain first")
            precondition(media.imageURLs == [media.imageURL, signedClientURLs[offset]], "Only the preferred bare original and exact-ID client ORIGINAL may be attempted")
            precondition(media.appOriginalURLs == [signedClientURLs[offset]])
            precondition(!media.imageURLs.contains(signedWebURLs[offset]), "A signed web display image must not be silently delivered as an original")
            precondition(Set(media.imageURLs).count == media.imageURLs.count)
            precondition(media.imageURLs.allSatisfy { !$0.host!.contains("sns-video") }, "Motion streams cannot be image fallback sources")
        }
        // A successful web page can advertise only display variants. Their
        // canonical bare originals remain usable, but the signed H5/style/
        // preview representations must never enter the download fallback list.
        let ordinaryImages: [[String: Any]] = (1...4).map { number in
            let fileID = "notes_pre_post/still-\(number)"
            return ["fileId": fileID,
                "url": "https://sns-webpic-qc.xhscdn.com/202610011200/web-signature/\(fileID)!h5_1080jpg",
                "infoList": [
                    ["imageScene": "H5_DTL", "url": signedWebURLs[number - 1].absoluteString],
                    ["imageScene": "H5_PRV", "url": "https://sns-webpic-qc.xhscdn.com/202610011200/web-signature/\(fileID)!style_fixture"]],
                "preview": "https://sns-na-i6.xhscdn.com/\(fileID)?imageView2/2/w/576/format/webp&sc=PREVIEW&sign=preview"]
        }
        let ordinaryWeb = try X.parseNote(["noteId": noteID, "type": "normal", "imageList": ordinaryImages], fallbackURL: fallback)
        let expectedBareURLs = (1...4).map { URL(string: "https://sns-img-bd.xhscdn.com/notes_pre_post/still-\($0)")! }
        let unavailableCache = X.preferredNote([ordinaryWeb])!
        precondition(unavailableCache.items.map(\.imageURL) == expectedBareURLs)
        for (offset, media) in unavailableCache.items.enumerated() {
            precondition(media.imageURLs == [expectedBareURLs[offset]] && media.appOriginalURLs.isEmpty,
                "Missing or unavailable client cache must preserve the bare source without adding a display-sized substitute")
        }
        precondition(X.shouldRefreshClientCache(for: nil))
        precondition(X.shouldRefreshClientCache(for: ordinaryWeb), "Ordinary stills missing client originals require the same bounded cache refresh as Live Photos")
        precondition(X.shouldRefreshClientCache(for: videoDesktop), "A regular video playback source still requires original discovery")
        let originalsReady = X.preferredNote([ordinaryWeb, stillClient])!
        precondition(!X.shouldRefreshClientCache(for: originalsReady), "All exact client originals satisfy an ordinary still-image refresh")
        precondition(X.shouldRefreshClientCache(for: stillCombined), "Having image originals must not bypass the missing client motion refresh")
        let oneOriginal = X.parseAppNote(["id": noteID, "type": "normal", "images_list": [
            ["fileid": "notes_pre_post/still-3", "original": signedClientURLs[2].absoluteString]
        ]], expectedID: noteID, fallbackURL: fallback)!
        let partialOriginals = X.preferredNote([ordinaryWeb, oneOriginal])!
        precondition(X.shouldRefreshClientCache(for: partialOriginals))
        precondition(partialOriginals.items[2].appOriginalURLs == [signedClientURLs[2]] && partialOriginals.items[1].appOriginalURLs.isEmpty,
            "A sparse client cache must bind each original by fileID rather than array position")
        let cancelledCacheOpen = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            precondition(Task.isCancelled)
            return await XHSAppCache.openNote(noteID, shareURL: fallback)
        }
        let cancelledCacheOpened = await cancelledCacheOpen.value
        precondition(!cancelledCacheOpened, "An already cancelled client refresh must return before opening an external app")

        var previewOnlyImage = appImage(2)
        previewOnlyImage.removeValue(forKey: "original")
        let largePreview = "https://sns-na-i6.xhscdn.com/image-2?imageView2/2/w/1440/format/webp&sc=DETAIL&sign=large"
        let smallPreview = "https://sns-na-i6.xhscdn.com/image-2?imageView2/2/w/576/format/webp&sc=PREVIEW&sign=small"
        previewOnlyImage["url_size_large"] = largePreview
        previewOnlyImage["url"] = smallPreview
        let previewOnlyClient = X.parseAppNote(["id": noteID, "type": "normal", "images_list": [previewOnlyImage]], expectedID: noteID, fallbackURL: fallback)!
        let previewCombined = X.preferredNote([web, previewOnlyClient])!
        precondition(previewCombined.items[1].liveHasAudio, "Rejecting display stills must preserve exact-ID client motion/audio recovery")
        precondition(previewCombined.items.allSatisfy { $0.appOriginalURLs.isEmpty })
        precondition(previewCombined.items[1].imageURL == web.items[1].imageURL)
        precondition(!previewCombined.items[1].imageURLs.contains(URL(string: largePreview)!) && !previewCombined.items[1].imageURLs.contains(URL(string: smallPreview)!))
        precondition(X.shouldRefreshClientCache(for: previewCombined), "A preview-only client snapshot must not be considered an original-image cache hit")
        previewOnlyImage.removeValue(forKey: "url_size_large")
        let smallOnlyClient = X.parseAppNote(["id": noteID, "type": "normal", "images_list": [previewOnlyImage]], expectedID: noteID, fallbackURL: fallback)!
        let smallOnlyCombined = X.preferredNote([web, smallOnlyClient])!
        precondition(smallOnlyCombined.items[1].liveHasAudio && smallOnlyCombined.items[1].appOriginalURLs.isEmpty)
        precondition(!smallOnlyCombined.items[1].imageURLs.contains(URL(string: smallPreview)!))
        let mismatchedOriginal = X.parseAppNote(["id": noteID, "type": "normal", "images_list": [
            ["fileid": "notes_pre_post/still-2", "original": signedClientURLs[3].absoluteString]
        ]], expectedID: noteID, fallbackURL: fallback)!
        let mismatchCombined = X.preferredNote([ordinaryWeb, mismatchedOriginal])!
        precondition(mismatchCombined.items[1].appOriginalURLs.isEmpty && !mismatchCombined.items[1].imageURLs.contains(signedClientURLs[3]),
            "A client's original URL for a different fileID must not be bound to this image")
        for transformation in ["!nc_n_webp_mw1", "!unrecognized_transform"] {
            let styledOriginal = "https://sns-na-i6.xhscdn.com/notes_pre_post/still-2" + transformation + "?sc=ORIGINAL&sign=fixture"
            let styledClient = X.parseAppNote(["id": noteID, "type": "normal", "images_list": [
                ["fileid": "notes_pre_post/still-2", "original": styledOriginal]
            ]], expectedID: noteID, fallbackURL: fallback)!
            let styledCombined = X.preferredNote([ordinaryWeb, styledClient])!
            precondition(styledCombined.items[1].appOriginalURLs.isEmpty && styledCombined.items[1].imageURLs == [expectedBareURLs[1]],
                "An original field with a path style, including an unknown style, must not become an original fallback")
        }

        let qualityCacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("XHSOriginalSourceRegression-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: qualityCacheRoot) }
        func writeOriginalSnapshot(_ session: String, date: TimeInterval, signature: String) throws {
            let images: [[String: Any]] = (1...4).reversed().map { number in
                ["fileid": "notes_pre_post/still-\(number)", "original": signedClientURLs[number - 1].absoluteString.replacingOccurrences(of: "sign=fixture", with: "sign=" + signature)]
            }
            let body = String(decoding: try JSONSerialization.data(withJSONObject: [["note_list": [["id": noteID, "type": "normal", "images_list": images]]]]), as: UTF8.self)
            let file = qualityCacheRoot.appendingPathComponent(session + "/extra/extraFile")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["note_detail_response": body]).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: file.path)
        }
        try writeOriginalSnapshot("old-session", date: 100, signature: "older")
        try writeOriginalSnapshot("new-session", date: 300, signature: "newest")
        let orderedSnapshots = XHSAppCache.notes(noteID: noteID, roots: [qualityCacheRoot])
        precondition(orderedSnapshots.count == 2)
        let orderedClientNotes = orderedSnapshots.compactMap { X.parseAppNote($0, expectedID: noteID, fallbackURL: fallback) }
        let newestOriginals = X.preferredNote([ordinaryWeb] + orderedClientNotes)!
        for (offset, media) in newestOriginals.items.enumerated() {
            let newest = URL(string: signedClientURLs[offset].absoluteString.replacingOccurrences(of: "sign=fixture", with: "sign=newest"))!
            let older = URL(string: signedClientURLs[offset].absoluteString.replacingOccurrences(of: "sign=fixture", with: "sign=older"))!
            precondition(media.imageURL == expectedBareURLs[offset])
            precondition(media.appOriginalURLs == [newest, older] && media.imageURLs == [expectedBareURLs[offset], newest, older],
                "Multiple snapshots must keep the latest exact-ID original first without older-cache order reversal")
        }
        print("PASS: XHS originals reject signed display fallbacks, refresh missing still originals and prefer newest exact-ID client cache")
        actor ShortLinkCounter {
            var requests = 0
            func resolved() { requests += 1 }
        }
        let shortLinkCounter = ShortLinkCounter()
        let shortLinks = try await X.extractLinks(from: "https://xhslink.cn/o/fixture") { _ in
            await shortLinkCounter.resolved()
            return fallback
        }
        let shortRequests = await shortLinkCounter.requests
        precondition(shortLinks == [fallback] && shortRequests == 1, "Bare short links must resolve only once")
        print("PASS: XHS bare and exact-ID full-size cache image alternatives retain all four originals; one short-link resolution")
        let body = String(data: try JSONSerialization.data(withJSONObject:[["note_list":[appNote]]]),encoding:.utf8)!
        let envelope = try JSONSerialization.data(withJSONObject:["noteId":"another-visible-note","note_detail_response":body])
        precondition(XHSAppCache.notes(in:envelope,noteID:noteID).count == 1)
        precondition(XHSAppCache.notes(in:envelope,noteID:"ffffffffffffffffffffffff").isEmpty)
        precondition(XHSAppCache.notes(in:Data("{broken".utf8),noteID:noteID).isEmpty)
        precondition(XHSAppCache.noteID(from:fallback) == noteID)
        precondition(XHSAppCache.noteID(from:URL(string:"https://xhslink.cn/o/short")!) == nil)
        precondition(!XHSAppCache.isNoteID("../../other"))
        let dewuPairs = [DewuNativeDownloader.APIMediaPair(imageURL: a, videoURL: b),
                         DewuNativeDownloader.APIMediaPair(imageURL: b, videoURL: a)]
        precondition(DewuNativeDownloader.pairedImageURL(for: a, in: dewuPairs) == b)
        precondition(DewuNativeDownloader.pairedImageURL(for: b, in: dewuPairs.reversed()) == a)
        precondition(DewuNativeDownloader.pairedImageURL(for: a, in: []) == nil)
        precondition(DewuNativeDownloader.pairedImageURL(for: a, in: dewuPairs + [.init(imageURL:a,videoURL:a)]) == nil)
        let origin = DouyinSourceResolver.sourceURL(videoID: "v1234567890")!
        precondition(D.preferredDouyinPlaybackURL(origin,width:1080,height:1920) == origin)
        let missing = D.preferredDouyinPlaybackURL(URL(string:"https://www.douyin.com/aweme/v1/play/?video_id=v1234567890&watermark=1")!,width:1440,height:2560)
        let q = URLComponents(url: missing,resolvingAgainstBaseURL:false)!.queryItems!
        precondition(q.contains(.init(name:"ratio",value:"1080p")))
        precondition(q.contains(.init(name:"watermark",value:"0")))
        let info = D.parseAweme(["aweme_id":"work", "video":["play_addr_h264":["uri":"v1234567890","url_list":["https://www.douyin.com/aweme/v1/play/?video_id=v1234567890"]]]])
        precondition(info.sourceVideoID == "v1234567890")
        // Sanitized real slides response: keep each motion bound to its own image.
        let liveData = try Data(contentsOf: URL(fileURLWithPath: "Tests/DownloadRegression/Fixtures/douyin-live-four.json"))
        var liveJSON = try JSONSerialization.jsonObject(with: liveData) as! [String: Any]
        let liveInfo = D.parseAweme(liveJSON)
        precondition(liveInfo.images.count == 4 && liveInfo.videos.isEmpty)
        for (offset, image) in liveInfo.images.enumerated() {
            precondition(image.index == offset + 1)
            precondition(image.videoURL?.lastPathComponent == "live-\(offset + 1).mp4")
        }
        var liveImages = liveJSON["images"] as! [[String: Any]]
        liveImages[1].removeValue(forKey: "video")
        liveJSON["images"] = liveImages
        let sparseLive = D.parseAweme(liveJSON)
        precondition(sparseLive.images[1].videoURL == nil)
        precondition(sparseLive.images[2].videoURL?.lastPathComponent == "live-3.mp4")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        // Exercise the exact cache script used by production against real-format files.
        let oldDate = Date(timeIntervalSince1970: 0)
        let cutoff = Date(timeIntervalSince1970: 100)
        let archived = D.archivedDouyinCacheFiles([
            (url:a,date:oldDate,priority:2),
            (url:b,date:Date(timeIntervalSince1970:200),priority:1),
            (url:URL(string:"https://example.com/media")!,date:oldDate,priority:7)
        ],cutoff:cutoff)
        precondition(archived == [a])
        precondition(D.douyinCachePriority(for:"https://www.douyin.com/aweme/v1/web/aweme/post/") == 2)
        let cacheRuntime = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HERMES_CACHE_TEST_RUNTIME"]
            ?? "/Applications/抖音.app/Contents/MacOS/抖音")
        if FileManager.default.isExecutableFile(atPath:cacheRuntime.path) {
            let script = dir.appendingPathComponent("cache-reader.js")
            try D.desktopCacheScript.write(to:script,atomically:true,encoding:.utf8)
            let factory = #"""
            const fs=require('fs'), z=require('zlib'), path=require('path');
            const root=process.argv[1], target='7679728215564421722';
            const work={aweme_id:target,images:Array.from({length:6},(_,i)=>({
              url_list:['https://example.com/image-'+i+'.jpg'],
              video:{play_addr:{url_list:['https://example.com/motion-'+i+'.mp4']}}
            }))};
            function cache(name, coding, object, broken=false) {
              const key=Buffer.from('1/0/https://www.douyin.com/aweme/v1/web/aweme/favorite/');
              const header=Buffer.alloc(24);header.writeBigUInt64LE(0xfcfb6d1ba7725c30n);
              header.writeUInt32LE(9,8);header.writeUInt32LE(key.length,12);
              const raw=Buffer.from(JSON.stringify({aweme_list:[object]}));
              const body=coding==='br'?z.brotliCompressSync(raw):coding==='gzip'?z.gzipSync(raw):coding==='deflate'?z.deflateSync(raw):raw;
              const metadata=Buffer.from('HTTP/1.1 200 OK\0content-encoding:'+coding+'\0\0');
              const bodyEOF=Buffer.alloc(24);bodyEOF.writeBigUInt64LE(0xf4fa6f45970d41d8n);
              const finalEOF=Buffer.alloc(24);finalEOF.writeBigUInt64LE(broken?0n:0xf4fa6f45970d41d8n);
              finalEOF.writeUInt32LE(2,8);finalEOF.writeUInt32LE(metadata.length,16);
              fs.writeFileSync(path.join(root,name+'_0'),Buffer.concat([header,key,body,bodyEOF,metadata,Buffer.alloc(32),finalEOF]));
            }
            for(const coding of ['identity','br','gzip','deflate']) cache(coding,coding,work);
            fs.writeFileSync(path.join(root,'f_000001'),z.gzipSync(Buffer.from(JSON.stringify({aweme_list:[work]}))));
            fs.writeFileSync(path.join(root,'f_000002'),Buffer.from(JSON.stringify({aweme_list:[work]})));
            fs.writeFileSync(path.join(root,'f_000003'),Buffer.from('video bytes'));
            cache('broken','br',work,true);
            cache('unrelated','br',{aweme_id:'1111111111111111111',video:{description:target}});
            """#
            let created = try SubprocessRunner.run(executable:cacheRuntime,
                arguments:["-e",factory,dir.path],environment:["ELECTRON_RUN_AS_NODE":"1"],timeout:15)
            precondition(created.status == 0)
            precondition(Set(D.douyinTTNetCacheFiles(roots:[dir]).map(\.lastPathComponent)) == ["f_000001","f_000002"])
            for name in ["identity","br","gzip","deflate","broken","unrelated","f_000001","f_000002"] {
                let result = try SubprocessRunner.run(executable:cacheRuntime,
                    arguments:[script.path,"7679728215564421722",dir.appendingPathComponent(name.hasPrefix("f_") ? name : name+"_0").path],
                    environment:["ELECTRON_RUN_AS_NODE":"1"],timeout:15)
                if ["broken","unrelated"].contains(name) { precondition(result.status != 0); continue }
                precondition(result.status == 0)
                let json = try JSONSerialization.jsonObject(with:result.stdout) as! [String:Any]
                let parsed = D.parseAweme(json)
                precondition(parsed.awemeID == "7679728215564421722")
                precondition(parsed.images.count == 6 && parsed.images.allSatisfy { $0.videoURL != nil })
            }
            print("PASS: production cache decoder, identity/br/gzip/deflate, footer bounds, exact work identity, old cache stage, TTNet external gzip/JSON selection and decoding")
        } else { print("SKIP: cache runtime unavailable; set HERMES_CACHE_TEST_RUNTIME") }
        let cacheFiles = try (0..<256).map { i in
            let file = dir.appendingPathComponent("cache-\(i)")
            try Data([0]).write(to:file)
            return file
        }
        var tracker = D.CacheScanTracker()
        precondition(tracker.uncheckedFiles(Array(cacheFiles.prefix(64))).count == 64)
        precondition(tracker.uncheckedFiles(Array(cacheFiles.prefix(128))).count == 64)
        precondition(tracker.uncheckedFiles(cacheFiles).count == 128)
        precondition(tracker.uncheckedFiles(cacheFiles).isEmpty)
        try Data([0,1]).write(to:cacheFiles[0])
        precondition(tracker.uncheckedFiles(cacheFiles) == [cacheFiles[0]])
        let part=dir.appendingPathComponent("media.mp4.part")
        for body in ["", "<html>error</html>", "{\"error\":true}", "not a movie"] {
            try Data(body.utf8).write(to: part)
            do { try await MediaFileUtilities.validateMedia(part,expectedSuffix:"mp4"); fatalError("accepted invalid media") }
            catch { }
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        try bitmap.representation(using:.png,properties:[:])!.write(to:part)
        do { try await MediaFileUtilities.validateMedia(part,expectedSuffix:"png") } catch { throw NSError(domain:"REGRESSION valid PNG rejected",code:1,userInfo:[NSUnderlyingErrorKey:error]) }
        do { try await MediaFileUtilities.validateMedia(part,expectedSuffix:"mp4"); fatalError("accepted image as video") } catch { }
        let validPNG = try Data(contentsOf: part)
        let imageFixture = dir.appendingPathComponent("image-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: imageFixture, withIntermediateDirectories: true)
        try validPNG.write(to: imageFixture.appendingPathComponent("valid.png"))
        let imageServer = Process()
        imageServer.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        imageServer.arguments = ["python3", URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("xhs_image_fixture_server.py").path, imageFixture.path]
        imageServer.standardOutput = FileHandle.nullDevice
        imageServer.standardError = FileHandle.nullDevice
        let imageServerStopped = DispatchSemaphore(value: 0)
        imageServer.terminationHandler = { _ in imageServerStopped.signal() }
        try imageServer.run()
        defer { stopFixtureServer(imageServer, terminated: imageServerStopped) }
        let imagePortFile = imageFixture.appendingPathComponent("port")
        for _ in 0..<300 where !FileManager.default.fileExists(atPath: imagePortFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let imagePort = try String(contentsOf: imagePortFile, encoding: .utf8)
        let imageBase = URL(string: "http://127.0.0.1:\(imagePort)")!
        let imageTasks = (1...4).map { number in
            let good = imageBase.appendingPathComponent("original-\(number)")
            return X.DownloadTask(urls: [2, 3].contains(number) ? [imageBase.appendingPathComponent("invalid-\(number)"), good] : [good],
                destination: imageFixture.appendingPathComponent("photo-\(number).bin"), requestUserAgent: X.mobileUserAgent,
                videoHDRHint: nil, isImage: true)
        }
        let imageStatuses = DownloadStatusRecorder()
        let imageResults = try await DownloaderInfra.$statusHandler.withValue({ message in
            await imageStatuses.record(message)
        }) {
            try await X.download(imageTasks, maxConcurrentDownloads: 4)
        }
        precondition(imageResults.count == 4)
        for number in 1...4 {
            let saved = imageFixture.appendingPathComponent("photo-\(number).png")
            let savedBytes = try Data(contentsOf: saved)
            precondition(savedBytes == validPNG && !FileManager.default.fileExists(atPath: imageFixture.appendingPathComponent("photo-\(number).bin.part").path))
        }
        let imageRequests = try String(contentsOf: imageFixture.appendingPathComponent("requests.txt"), encoding: .utf8)
        precondition(imageRequests.split(separator: "\n").filter { $0.hasPrefix("/invalid-") }.count == 2, "Failed first image sources must advance to alternatives without redownloading completed stills")
        let sourceStages = await imageStatuses.stageSnapshot()
        precondition(sourceStages.contains(.downloadingImage))
        precondition(sourceStages.contains(.tryingAlternative))
        precondition(sourceStages.contains(.checkingFile))
        precondition(sourceStages.contains(.savingFile))
        precondition(sourceStages.last == .completed)
        let sourceMessages = await imageStatuses.snapshot()
        precondition(sourceMessages.allSatisfy { !$0.contains("http") }, "Progress text must not expose source URLs")

        // The fallback stage comes from the real native-to-curl branch, rather
        // than being inferred from a long pause in numeric progress.
        let fallbackStatuses = DownloadStatusRecorder()
        let failedConfiguration = URLSessionConfiguration.ephemeral
        failedConfiguration.protocolClasses = [FailedNativeTransferProtocol.self]
        let failedSession = URLSession(configuration: failedConfiguration)
        defer { failedSession.invalidateAndCancel() }
        let compatibilityFile = imageFixture.appendingPathComponent("compatibility.part")
        let usesNativeFirst: @Sendable (URLRequest) -> Bool = { _ in false }
        try await DownloaderInfra.$statusHandler.withValue({ message in
            await fallbackStatuses.record(message)
        }) {
            try await DownloaderInfra.downloadOnceAsync(imageBase.appendingPathComponent("compatibility"),
                to: compatibilityFile, userAgent: X.mobileUserAgent, session: failedSession,
                shouldUseDirectly: usesNativeFirst, transferPolicy: .init(maximumDuration: 10, idleTimeout: 12))
        }
        let compatibilityBytes = try Data(contentsOf: compatibilityFile)
        let fallbackStages = await fallbackStatuses.stageSnapshot()
        precondition(compatibilityBytes == validPNG)
        precondition(fallbackStages.contains(.retrying))

        // A completed sibling's validation must not hide the source that is
        // still waiting. The actual delayed HTTP response must later complete.
        let waitingStatuses = DownloadStatusRecorder()
        let waitingTasks = [
            X.DownloadTask(urls: [imageBase.appendingPathComponent("waiting-image")], destination: imageFixture.appendingPathComponent("waiting.bin"), requestUserAgent: X.mobileUserAgent, videoHDRHint: nil, isImage: true),
            X.DownloadTask(urls: [imageBase.appendingPathComponent("fast-image")], destination: imageFixture.appendingPathComponent("fast.bin"), requestUserAgent: X.mobileUserAgent, videoHDRHint: nil, isImage: true)
        ]
        _ = try await DownloaderInfra.$statusHandler.withValue({ message in
            await waitingStatuses.record(message)
        }) {
            try await X.download(waitingTasks, maxConcurrentDownloads: 2)
        }
        let waitingStages = await waitingStatuses.statusSnapshot()
        precondition(waitingStages.contains { $0.stage == .waitingForResponse && $0.item == "图片 1" })
        precondition(!waitingStages.contains { [.retrying, .tryingAlternative, .failed].contains($0.stage) }, "Waiting alone must not be described as a failed source")
        precondition(waitingStages.last?.stage == .completed)
        let priorityStatuses = DownloadStatusRecorder()
        let statusAggregator = DownloaderInfra.$statusHandler.withValue({ message in
            await priorityStatuses.record(message)
        }) { DownloaderInfra.DownloadProgressAggregator(totalCount: 2, handler: nil) }
        let waitingImage = DownloaderInfra.DownloadStatus(stage: .waitingForResponse, item: "图片 1")
        await statusAggregator.updateStatus(index: 0, status: waitingImage)
        await statusAggregator.updateStatus(index: 0, status: waitingImage)
        await statusAggregator.updateStatus(index: 1, status: .init(stage: .checkingFile, item: "图片 2"))
        await statusAggregator.complete(index: 1)
        await statusAggregator.updateStatus(index: 1, status: .init(stage: .retrying, item: "图片 2"))
        let priorityStages = await priorityStatuses.statusSnapshot()
        precondition(priorityStages == [waitingImage], "A sibling's check, completion or late retry must not hide the waiting source; identical updates must not repeat")
        await statusAggregator.updateStatus(index: 0, status: .init(stage: .downloadingImage, item: "图片 1"))
        await statusAggregator.complete(index: 0)
        await statusAggregator.complete(index: 0)
        await statusAggregator.updateStatus(index: 0, status: .init(stage: .waitingForResponse, item: "图片 1"))
        let completedPriorityStages = await priorityStatuses.stageSnapshot()
        precondition(completedPriorityStages == [.waitingForResponse, .downloadingImage, .completed], "All-complete is published once and completed tasks reject late statuses")

        let tierStatuses = DownloadStatusRecorder()
        let tierAggregator = DownloaderInfra.$statusHandler.withValue({ status in
            await tierStatuses.record(status)
        }) { DownloaderInfra.DownloadProgressAggregator(totalCount: 4, handler: nil) }
        await tierAggregator.updateStatus(index: 0, status: .init(stage: .checkingFile, item: "图片 1"))
        await tierAggregator.updateStatus(index: 1, status: .init(stage: .downloadingVideo, item: "视频"))
        await tierAggregator.updateStatus(index: 2, status: .init(stage: .retrying, item: "图片 2"))
        await tierAggregator.updateStatus(index: 3, status: .init(stage: .waitingClient, item: "实况 1"))
        await tierAggregator.updateStatus(index: 2, status: .init(stage: .tryingAlternative, item: "图片 2"))
        await tierAggregator.complete(index: 3)
        await tierAggregator.complete(index: 2)
        await tierAggregator.updateStatus(index: 0, status: .init(stage: .savingFile, item: "图片 1"))
        await tierAggregator.complete(index: 1)
        await tierAggregator.complete(index: 0)
        let tierStages = await tierStatuses.stageSnapshot()
        precondition(tierStages == [.checkingFile, .downloadingVideo, .retrying, .waitingClient, .tryingAlternative, .downloadingVideo, .savingFile, .completed],
            "Typed waiting, retry, transfer and check/save stages must retain their priority independently of their displayed text")
        let conciseStageLabels = DownloaderInfra.DownloadStage.allCases.map(\.text)
        precondition(conciseStageLabels.allSatisfy { !$0.isEmpty && $0.count <= 10 && !$0.contains("\n") && !$0.contains("http") },
            "Shared phase labels must remain concise, single-line and free of source URLs")

        // Cancel a real stalled request after its truthful waiting stage. No
        // backup, post-cancellation status, or staged file may remain.
        let cancelledStatuses = DownloadStatusRecorder()
        let cancelledDestination = imageFixture.appendingPathComponent("cancelled.bin")
        let cancelledTask = Task {
            try await DownloaderInfra.$statusHandler.withValue({ message in
                await cancelledStatuses.record(message)
            }) {
                try await X.download(X.DownloadTask(urls: [imageBase.appendingPathComponent("stall-cancelled"), imageBase.appendingPathComponent("must-not-retry")], destination: cancelledDestination, requestUserAgent: X.mobileUserAgent, videoHDRHint: nil, isImage: true), retries: 0)
            }
        }
        var observedWaiting = false
        for _ in 0..<120 {
            if await cancelledStatuses.stageSnapshot().contains(.waitingForResponse) { observedWaiting = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(observedWaiting)
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; fatalError("cancelled image download succeeded") }
        catch { precondition(DownloaderHTTPCompatibility.isCancellation(error)) }
        let cancelledStages = await cancelledStatuses.snapshot()
        try await Task.sleep(for: .milliseconds(250))
        let laterCancelledStages = await cancelledStatuses.snapshot()
        precondition(cancelledStages == laterCancelledStages)
        precondition(!FileManager.default.fileExists(atPath: cancelledDestination.appendingPathExtension("part").path))
        let cancellationRequests = try String(contentsOf: imageFixture.appendingPathComponent("requests.txt"), encoding: .utf8)
        precondition(!cancellationRequests.contains("/must-not-retry"))
        print("PASS: four-photo XHS fallback, real native compatibility retry, delayed-source waiting, concurrent status priority, cancellation status cleanup")
        try validPNG.prefix(33).write(to: part)
        do { try await MediaFileUtilities.validateMedia(part,expectedSuffix:"png"); fatalError("accepted PNG headers without pixel data") } catch { }
        let jpegBitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:64,pixelsHigh:64,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:192,bitsPerPixel:24)!
        for offset in 0..<(64 * 192) { jpegBitmap.bitmapData![offset] = UInt8(offset % 255) }
        let validJPEG = jpegBitmap.representation(using:.jpeg,properties:[:])!
        try validJPEG.write(to: part)
        try await MediaFileUtilities.validateMedia(part, expectedSuffix:"jpg")
        try validJPEG.prefix(validJPEG.count / 2).write(to: part)
        do { try await MediaFileUtilities.validateMedia(part,expectedSuffix:"jpg"); fatalError("accepted truncated JPEG with recovered partial pixels") } catch { }
        try validPNG.write(to: part)
        if CommandLine.arguments.count > 1 {
            try FileManager.default.removeItem(at: part)
            try FileManager.default.copyItem(at:URL(fileURLWithPath:CommandLine.arguments[1]),to:part)
            do { try await MediaFileUtilities.validateMedia(part,expectedSuffix:"mp4") } catch { throw NSError(domain:"REGRESSION valid staged MP4 rejected",code:1,userInfo:[NSUnderlyingErrorKey:error]) }
            let handle = try FileHandle(forWritingTo: part)
            let size = try handle.seekToEnd()
            try handle.truncate(atOffset: size - 1)
            try handle.close()
            do { try await MediaFileUtilities.validateMedia(part,expectedSuffix:"mp4"); fatalError("accepted truncated video") } catch { }

        }
        if CommandLine.arguments.count > 2 {
            let base = URL(string: CommandLine.arguments[2])!
            let goodVideoURL = base.appendingPathComponent("good.mp4")
            let badVideoURL = base.appendingPathComponent("bad.mp4")
            let expectedVideoBytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            actor VideoCacheLoadCounter {
                private var calls = 0
                func called() { calls += 1 }
                func count() -> Int { calls }
            }
            var fixtureCachedVideo = cachedVideo
            fixtureCachedVideo.videoURL = goodVideoURL
            fixtureCachedVideo.videoURLs = [goodVideoURL]
            let runtimeCachedVideo = fixtureCachedVideo
            var failedCloudVideo = originalVideo
            failedCloudVideo.originalVideoURL = badVideoURL
            failedCloudVideo.videoURL = badVideoURL
            failedCloudVideo.videoURLs = [badVideoURL]
            let failedCloudDestination = dir.appendingPathComponent("xhs-video-cache-fallback.mp4")
            let failedCloudTask = X.DownloadTask(urls: [badVideoURL], destination: failedCloudDestination,
                requestUserAgent: X.mobileUserAgent, videoHDRHint: .init(sourceMarkedHDR: true, streamMarkedHDR: true))
            let fallbackVideoStatuses = DownloadStatusRecorder()
            let fallbackVideoLoads = VideoCacheLoadCounter()
            let fallbackVideoResult = try await DownloaderInfra.$statusHandler.withValue({ message in
                await fallbackVideoStatuses.record(message)
            }) {
                try await X.downloadVideo(failedCloudVideo, task: failedCloudTask, shareURL: originFallback, cacheLoader: {
                    await fallbackVideoLoads.called()
                    return runtimeCachedVideo
                })
            }
            precondition(fallbackVideoResult.sourceURL == goodVideoURL && fallbackVideoResult.fromAppCache && !fallbackVideoResult.isLivePhoto)
            let fallbackVideoCalls = await fallbackVideoLoads.count()
            precondition(fallbackVideoCalls == 1, "A failed cloud upload should load the exact-note cache once")
            let fallbackVideoBytes = try Data(contentsOf: failedCloudDestination)
            precondition(fallbackVideoBytes == expectedVideoBytes, "A client fallback must preserve source bytes without HDR remuxing")
            precondition(!FileManager.default.fileExists(atPath: failedCloudDestination.appendingPathExtension("part").path))
            let fallbackVideoStages = await fallbackVideoStatuses.stageSnapshot()
            precondition(containsStagesInOrder(fallbackVideoStages, [.downloadingVideo, .checkingFile, .readingClient, .downloadingVideo, .checkingFile, .savingFile]),
                "The progress stages must accurately show cloud validation failure followed by client source download and validation")
            let fallbackVideoMessages = await fallbackVideoStatuses.snapshot()
            precondition(fallbackVideoMessages.allSatisfy { !$0.contains("http") }, "Video progress must not expose signed source URLs")

            var refreshedCloudVideo = runtimeCachedVideo
            refreshedCloudVideo.originalVideoURL = goodVideoURL
            refreshedCloudVideo.originalVideoURLs = [goodVideoURL]
            let updatedVideoSource = refreshedCloudVideo
            let refreshedDestination = dir.appendingPathComponent("xhs-video-refreshed-original.mp4")
            var refreshedTask = failedCloudTask
            refreshedTask.destination = refreshedDestination
            let refreshedOutcome = try await X.downloadVideo(failedCloudVideo, task: refreshedTask, shareURL: originFallback,
                cacheLoader: { updatedVideoSource })
            precondition(refreshedOutcome.usedOriginalVideo && !refreshedOutcome.fromAppCache && refreshedOutcome.sourceURL == goodVideoURL,
                "A new original found in refreshed exact-note details must outrank its cached playback")
            print("PASS: ordinary video schema/backups and failed cloud source rediscovery remain original-first")

            var goodCloudVideo = originalVideo
            goodCloudVideo.originalVideoURL = goodVideoURL
            goodCloudVideo.videoURL = goodVideoURL
            goodCloudVideo.videoURLs = [goodVideoURL]
            let goodCloudDestination = dir.appendingPathComponent("xhs-video-cloud-original.mp4")
            let goodCloudTask = X.DownloadTask(urls: [goodVideoURL, badVideoURL], destination: goodCloudDestination,
                requestUserAgent: X.mobileUserAgent, videoHDRHint: .init(sourceMarkedHDR: true, streamMarkedHDR: true))
            let goodCloudLoads = VideoCacheLoadCounter()
            let goodCloudStatuses = DownloadStatusRecorder()
            let goodCloudResult = try await DownloaderInfra.$statusHandler.withValue({ message in
                await goodCloudStatuses.record(message)
            }) {
                try await X.downloadVideo(goodCloudVideo, task: goodCloudTask, shareURL: originFallback, cacheLoader: {
                    await goodCloudLoads.called()
                    return runtimeCachedVideo
                })
            }
            let goodCloudCalls = await goodCloudLoads.count()
            precondition(goodCloudResult.sourceURL == goodVideoURL && !goodCloudResult.fromAppCache && goodCloudCalls == 0,
                "A valid cloud original must finish without invoking client-cache lookup")
            let goodCloudBytes = try Data(contentsOf: goodCloudDestination)
            precondition(goodCloudBytes == expectedVideoBytes, "A cloud original must be delivered byte-for-byte without playback HDR remuxing")
            let goodCloudStages = await goodCloudStatuses.stageSnapshot()
            precondition(containsStagesInOrder(goodCloudStages, [.downloadingVideo, .checkingFile, .savingFile]))
            precondition(!goodCloudStages.contains(.readingClient))

            var wrongCachedVideo = runtimeCachedVideo
            wrongCachedVideo.noteID = "ffffffffffffffffffffffff"
            let wrongCacheDestination = dir.appendingPathComponent("xhs-video-wrong-cache.mp4")
            let wrongCacheTask = X.DownloadTask(urls: [], destination: wrongCacheDestination,
                requestUserAgent: X.mobileUserAgent, videoHDRHint: nil)
            do {
                _ = try await X.downloadVideo(noOriginalVideo, task: wrongCacheTask, shareURL: originFallback, cacheLoader: { [wrongCachedVideo] in wrongCachedVideo })
                preconditionFailure("A playable client source from another note must not be published")
            } catch let error as NSError {
                precondition(error.domain == "XHSDownloader" && error.code == 8)
            }
            precondition(!FileManager.default.fileExists(atPath: wrongCacheDestination.path)
                && !FileManager.default.fileExists(atPath: wrongCacheDestination.appendingPathExtension("part").path))

            for noteToCancel in [goodCloudVideo, noOriginalVideo] {
                let cancelledVideoLoads = VideoCacheLoadCounter()
                let cancelledVideoDestination = dir.appendingPathComponent("xhs-video-cancelled-" + UUID().uuidString + ".mp4")
                let cancelledVideoTask = X.DownloadTask(urls: [goodVideoURL], destination: cancelledVideoDestination,
                    requestUserAgent: X.mobileUserAgent, videoHDRHint: nil)
                let cancelledVideo = Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    do {
                        _ = try await X.downloadVideo(noteToCancel, task: cancelledVideoTask, shareURL: originFallback, cacheLoader: {
                            await cancelledVideoLoads.called()
                            return runtimeCachedVideo
                        })
                        return false
                    } catch { return DownloaderHTTPCompatibility.isCancellation(error) }
                }
                let cancelledBeforeLookup = await cancelledVideo.value
                let cancelledLookupCalls = await cancelledVideoLoads.count()
                precondition(cancelledBeforeLookup && cancelledLookupCalls == 0,
                    "Cancellation must return before a cache lookup whether or not an original URL is available")
                precondition(!FileManager.default.fileExists(atPath: cancelledVideoDestination.path)
                    && !FileManager.default.fileExists(atPath: cancelledVideoDestination.appendingPathExtension("part").path))
            }
            print("PASS: XHS runtime cloud-original priority, cache fallback byte identity, exact-note rejection, cancellation and source progress stages")

            // Start at a fixed API response, then use the same task builder as run().
            var fixture = try JSONSerialization.jsonObject(with: liveData) as! [String: Any]
            var images = fixture["images"] as! [[String: Any]]
            images[0]["video"] = ["width":720,"height":1280,"play_addr":["url_list":[base.appendingPathComponent("bad.mp4").absoluteString,base.appendingPathComponent("good.mp4").absoluteString]]]
            fixture["images"] = images
            let parsed = D.parseAweme(fixture)
            precondition(parsed.images[0].alternateURLs.contains(base.appendingPathComponent("good.mp4")))
            var missingMotion = parsed
            missingMotion.images[0].videoURL = nil
            missingMotion.images[0].alternateURLs = []
            let mergedMotion = D.mergeLivePhotoVideos(from:parsed,into:missingMotion)
            let displayOrder = MediaDisplayOrder(postID: "fixture", downloadedAt: 100, index: 1)
            var task = D.livePhotoDownloadTask(mergedMotion.images[0],destination:dir.appendingPathComponent("fixture-image-01.mp4"))!
            task.displayOrder = displayOrder
            precondition(task.url == base.appendingPathComponent("bad.mp4"))
            let parsedOutcome = try await D.download(task,retries:0)
            precondition(parsedOutcome.usedFallback && parsedOutcome.fileURL.lastPathComponent == "fixture-image-01.mp4")
            precondition(MediaDisplayOrder.read(from: parsedOutcome.fileURL) == displayOrder)
            precondition(mergedMotion.images[0].index == 1 && mergedMotion.images[1].videoURL == parsed.images[1].videoURL)
            let badDestination = dir.appendingPathComponent("rejected.mp4")
            do {
                _ = try await D.download(.init(url:base.appendingPathComponent("bad.mp4"),destination:badDestination),retries:0)
                fatalError("invalid body accepted")
            } catch { }
            precondition(!FileManager.default.fileExists(atPath:badDestination.path))
            precondition(!FileManager.default.fileExists(atPath:badDestination.appendingPathExtension("part").path))
            let outcome = try await D.download(.init(url:base.appendingPathComponent("bad.mp4"),destination:dir.appendingPathComponent("fallback.mp4"),alternateURLs:[base.appendingPathComponent("good.mp4")]),retries:0)
            precondition(outcome.usedFallback)
            try await MediaFileUtilities.validateMedia(outcome.fileURL,expectedSuffix:"mp4")
            let douyinVideoStatuses = DownloadStatusRecorder()
            let outcomes = try await DownloaderInfra.$statusHandler.withValue({ status in
                await douyinVideoStatuses.record(status)
            }) {
                try await D.download([
                    .init(url:base.appendingPathComponent("good.mp4"),destination:dir.appendingPathComponent("one.mp4")),
                    .init(url:base.appendingPathComponent("good.mp4"),destination:dir.appendingPathComponent("two.mp4"))
                ],maxConcurrentDownloads:2)
            }
            precondition(outcomes.count == 2 && outcomes.allSatisfy { !$0.usedFallback })
            let douyinVideoStages = await douyinVideoStatuses.stageSnapshot()
            precondition(containsStagesInOrder(douyinVideoStages, [.downloadingVideo, .checkingFile, .savingFile, .completed]),
                "Douyin's real HTTP transfer, validation, saving and completion must publish shared typed stages")

            let dewuVideoStatuses = DownloadStatusRecorder()
            let dewuVideoDestination = dir.appendingPathComponent("dewu-stage-video.mp4")
            try await DownloaderInfra.$statusHandler.withValue({ status in
                await dewuVideoStatuses.record(status)
            }) {
                try await DewuNativeDownloader.download([
                    .init(url: goodVideoURL, destination: dewuVideoDestination)
                ], maxConcurrentDownloads: 1)
            }
            let dewuVideoStages = await dewuVideoStatuses.stageSnapshot()
            let dewuVideoBytes = try Data(contentsOf: dewuVideoDestination)
            precondition(dewuVideoBytes == expectedVideoBytes)
            precondition(containsStagesInOrder(dewuVideoStages, [.downloadingVideo, .checkingFile, .savingFile, .completed]),
                "Dewu's real HTTP transfer, validation, saving and completion must publish the same shared stages")
            for messages in [await douyinVideoStatuses.snapshot(), await dewuVideoStatuses.snapshot()] {
                precondition(messages.allSatisfy { !$0.contains("http") }, "Platform stages must not expose source URLs")
            }

            // Large real fixtures permit two separate 128 KiB file-growth events.
            // The server stalls between them, then keeps the response open while
            // the shared monitor observes resumed growth for each platform.
            if expectedVideoBytes.count > 256 * 1024 {
                let waitingVideoURL = base.appendingPathComponent("waiting.mp4")
                let slowDouyinStatuses = DownloadStatusRecorder()
                let slowDouyinDestination = dir.appendingPathComponent("douyin-waiting-video.mp4")
                let slowDouyinResults = try await DownloaderInfra.$statusHandler.withValue({ status in
                    await slowDouyinStatuses.record(status)
                }) {
                    try await D.download([.init(url: waitingVideoURL, destination: slowDouyinDestination)], maxConcurrentDownloads: 1)
                }
                precondition(slowDouyinResults.count == 1)
                let slowDouyinStages = await slowDouyinStatuses.stageSnapshot()
                let slowDouyinBytes = try Data(contentsOf: slowDouyinDestination)
                precondition(slowDouyinBytes == expectedVideoBytes)
                precondition(containsStagesInOrder(slowDouyinStages, [.downloadingVideo, .waitingForResponse, .downloadingVideo, .checkingFile, .savingFile, .completed]),
                    "A real slow Douyin video must resume its video stage instead of a generic file stage: \(slowDouyinStages)")
                precondition(!slowDouyinStages.contains(.downloadingFile))

                let slowDewuStatuses = DownloadStatusRecorder()
                let slowDewuDestination = dir.appendingPathComponent("dewu-waiting-video.mp4")
                try await DownloaderInfra.$statusHandler.withValue({ status in
                    await slowDewuStatuses.record(status)
                }) {
                    try await DewuNativeDownloader.download([.init(url: waitingVideoURL, destination: slowDewuDestination)], maxConcurrentDownloads: 1)
                }
                let slowDewuStages = await slowDewuStatuses.stageSnapshot()
                let slowDewuBytes = try Data(contentsOf: slowDewuDestination)
                precondition(slowDewuBytes == expectedVideoBytes)
                precondition(containsStagesInOrder(slowDewuStages, [.downloadingVideo, .waitingForResponse, .downloadingVideo, .checkingFile, .savingFile, .completed]),
                    "A real slow Dewu video must retain its video stage across waiting and recovery: \(slowDewuStages)")
                precondition(!slowDewuStages.contains(.downloadingFile))

                // XHS short-link downloads delegate their direct-curl branch to
                // this shared entry point; force that branch without a public CDN.
                let directCurlStatuses = DownloadStatusRecorder()
                let directCurlDestination = dir.appendingPathComponent("direct-curl-waiting-live.mp4")
                let usesDirectCurl: @Sendable (URLRequest) -> Bool = { _ in true }
                let directCurlSession = DownloaderHTTPCompatibility.makeDownloadSession()
                defer { directCurlSession.invalidateAndCancel() }
                try await DownloaderInfra.$statusHandler.withValue({ status in
                    await directCurlStatuses.record(status)
                }) {
                    try await DownloaderInfra.downloadWithRetriesAsync(waitingVideoURL, to: directCurlDestination, retries: 1,
                        validate: { try await MediaFileUtilities.validateMedia($0, expectedSuffix: "mp4") },
                        userAgent: X.mobileUserAgent, session: directCurlSession, shouldUseDirectly: usesDirectCurl,
                        stage: .downloadingLivePhoto)
                }
                let directCurlStages = await directCurlStatuses.stageSnapshot()
                let directCurlBytes = try Data(contentsOf: directCurlDestination)
                precondition(directCurlBytes == expectedVideoBytes)
                precondition(containsStagesInOrder(directCurlStages, [.downloadingLivePhoto, .waitingForResponse, .downloadingLivePhoto, .checkingFile, .savingFile]),
                    "The shared direct-curl branch must retain its media stage across waiting and recovery: \(directCurlStages)")
                precondition(!directCurlStages.contains(.downloadingFile))
                for file in [slowDouyinDestination, slowDewuDestination, directCurlDestination] {
                    precondition(!FileManager.default.fileExists(atPath: file.appendingPathExtension("part").path))
                }
                print("PASS: real Douyin, Dewu and direct-curl transfer, waiting, recovery, validation and saving stages")
            }
            if CommandLine.arguments.count > 3 {
                let silent = base.appendingPathComponent("silent.mp4")
                let good = base.appendingPathComponent("good.mp4")
                var localItem = combined.items[0]
                localItem.liveAudioURLs = [] // This fixture replaces every production donor URL.
                // Metadata can claim audio even when all actual client files are silent.
                localItem.liveURL = silent
                localItem.liveURLs = [silent, base.appendingPathComponent("silent-fallback.mp4")]
                let destination = dir.appendingPathComponent("xhs-silent.mp4")
                var localTask = X.livePhotoDownloadTask(localItem, destination:destination)!
                localTask.displayOrder = displayOrder
                let result = try await X.download(localTask, retries:0)
                precondition(result.isLivePhoto && !result.hasAudio)
                precondition(MediaDisplayOrder.read(from: destination) == displayOrder)
                let expectedSilent = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3]))
                let downloadedSilent = try Data(contentsOf:destination)
                precondition(downloadedSilent == expectedSilent)
                // Without an upload key, supplement the selected client video's
                // audio while preserving its higher-quality compressed video.
                localItem.liveURLs = [silent, good]
                let supplementedClientDestination = dir.appendingPathComponent("xhs-client-supplemented.mp4")
                let supplementedClientResult = try await X.download(X.livePhotoDownloadTask(localItem, destination: supplementedClientDestination)!, retries: 0)
                let supplementedClientMOV = supplementedClientDestination.deletingPathExtension().appendingPathExtension("mov")
                precondition(supplementedClientResult.isLivePhoto && supplementedClientResult.hasAudio)
                let silentClientVideo = try await compressedTrackSamples(at: URL(fileURLWithPath: CommandLine.arguments[3]), mediaType: .video)
                let supplementedClientVideo = try await compressedTrackSamples(at: supplementedClientMOV, mediaType: .video)
                precondition(!silentClientVideo.isEmpty && supplementedClientVideo == silentClientVideo,
                    "A keyless client video must retain its compressed samples when another exact source supplies audio")
                // Invalid content can fall back only to another exact client source.
                localItem.liveURL = base.appendingPathComponent("bad.mp4")
                localItem.liveURLs = [localItem.liveURL!,good]
                let audioDestination = dir.appendingPathComponent("xhs-audio.mp4")
                let audioResult = try await X.download(X.livePhotoDownloadTask(localItem,destination:audioDestination)!,retries:0)
                precondition(audioResult.isLivePhoto && audioResult.hasAudio)
                let expectedAudio = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
                let downloadedAudio = try Data(contentsOf:audioDestination)
                precondition(downloadedAudio == expectedAudio)
                // A working web video must not rescue a failed client motion source.
                var availableWeb = web
                availableWeb.items[0].liveURL = good
                availableWeb.items[0].liveURLs = [good]
                var failedClient = client
                let failedIndex = failedClient.items.firstIndex { $0.fileID == availableWeb.items[0].fileID }!
                failedClient.items[failedIndex].liveURL = localItem.liveURL
                failedClient.items[failedIndex].liveURLs = [localItem.liveURL!]
                let mergedFailure = X.preferredNote([availableWeb,failedClient])!.items[0]
                precondition(mergedFailure.liveURLs == [localItem.liveURL!])
                localItem.liveURLs = [localItem.liveURL!]
                let rejected = dir.appendingPathComponent("xhs-rejected.mp4")
                do {
                    _ = try await X.download(X.livePhotoDownloadTask(mergedFailure,destination:rejected)!,retries:0)
                    fatalError("invalid client source must not publish a file")
                } catch { }
                precondition(!FileManager.default.fileExists(atPath:rejected.path))
                precondition(!FileManager.default.fileExists(atPath:rejected.appendingPathExtension("part").path))
                print("PASS: silent client bytes preserved, actual client audio preserved, client backup recovery and failed-source cleanup")
                if CommandLine.arguments.count > 4 {
                    func fixtureRequestCounts() async throws -> [String: Int] {
                        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("requests.json"))
                        return try JSONSerialization.jsonObject(with: data) as! [String: Int]
                    }
                    let original = base.appendingPathComponent("original.mov")
                    let originalBackup = base.appendingPathComponent("original-backup.mov")
                    let invalidOriginal = base.appendingPathComponent("missing-original.mov")
                    let expectedOriginal = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[4]))
                    var originalItem = keyOnly
                    originalItem.liveURL = original
                    originalItem.liveOriginalURLs = [original, originalBackup]
                    originalItem.liveURLs = [original, originalBackup, good]
                    let originalDestination = dir.appendingPathComponent("xhs-upload.mp4")
                    let originalOrder = MediaDisplayOrder(postID: "xhs:original-mov-redownload", downloadedAt: 200, index: 1)
                    try expectedAudio.write(to: originalDestination)
                    MediaDisplayOrder(postID: originalOrder.postID, downloadedAt: 100, index: originalOrder.index).write(to: originalDestination)
                    var originalTask = X.livePhotoDownloadTask(originalItem, destination: originalDestination)!
                    originalTask.displayOrder = originalOrder
                    let countsBeforeOriginal = try await fixtureRequestCounts()
                    let originalResult = try await X.download(originalTask, retries: 0)
                    let publishedOriginal = originalDestination.deletingPathExtension().appendingPathExtension("mov")
                    let originalDownloadedBytes = try Data(contentsOf: publishedOriginal)
                    precondition(originalResult.isLivePhoto)
                    precondition(originalDownloadedBytes == expectedOriginal,
                        "Upload MOV bytes and native pairing metadata must survive transfer unchanged")
                    precondition(!FileManager.default.fileExists(atPath: originalDestination.path),
                        "A QuickTime redownload must replace the same resource's previous MP4 with its actual MOV container")
                    precondition(MediaDisplayOrder.read(from: publishedOriginal) == originalOrder,
                        "The replacement MOV must carry the current download's display metadata")
                    let countsAfterOriginal = try await fixtureRequestCounts()
                    if originalResult.hasAudio {
                        precondition(countsAfterOriginal["/good.mp4", default: 0] == countsBeforeOriginal["/good.mp4", default: 0],
                            "An original with actual audio must not download an audio donor")
                    }

                    var staleOriginalTask = originalTask
                    staleOriginalTask.urls = [invalidOriginal, good]
                    staleOriginalTask.originalLivePhotoURLs = [invalidOriginal]
                    staleOriginalTask.destination = dir.appendingPathComponent("rediscovered-original.mp4")
                    staleOriginalTask.sourceBinding = X.SourceBinding(noteID: noteID, imageFileID: keyOnly.fileID,
                        shareURL: fallback, motionKey: "old_namespace/old_object")
                    var freshItem = originalItem
                    freshItem.livePhotoFileID = "future_namespace_v5/fresh_object"
                    freshItem.liveURL = original
                    freshItem.liveURLs = [original]
                    freshItem.liveOriginalURLs = [original]
                    freshItem.liveAudioURLs = []
                    var freshNote = keyOnlyClient
                    freshNote.items = [freshItem]
                    let rediscoveredNote = freshNote
                    let sourceRefreshCounter = VideoCacheLoadCounter()
                    let beforeDiscoveryCounts = try await fixtureRequestCounts()
                    let discoveredOutcome = try await X.downloadWithOriginalDiscovery(staleOriginalTask, sourceLoader: {
                        await sourceRefreshCounter.called()
                        return rediscoveredNote
                    })
                    let afterDiscoveryCounts = try await fixtureRequestCounts()
                    let discoveryCalls = await sourceRefreshCounter.count()
                    precondition(discoveryCalls == 1 && discoveredOutcome.usedOriginalLivePhoto)
                    let discoveredFile = staleOriginalTask.destination.deletingPathExtension().appendingPathExtension("mov")
                    let discoveredBytes = try Data(contentsOf: discoveredFile)
                    precondition(discoveredBytes == expectedOriginal,
                        "A failed old URL must refresh and download the new original before trying playback")
                    precondition(afterDiscoveryCounts["/good.mp4", default: 0] == beforeDiscoveryCounts["/good.mp4", default: 0],
                        "Playback was requested before original rediscovery finished")
                    let sourceReceipt = MediaSourceProvenance.read(from: discoveredFile)!
                    precondition(sourceReceipt.state == .cloudOriginal && sourceReceipt.objectKey == "future_namespace_v5/fresh_object"
                        && sourceReceipt.imageFileID == keyOnly.fileID && sourceReceipt.sha256 == MediaSourceProvenance.hash(of: discoveredFile),
                        "Keep exact binding, state and media hash without saving signed URL tokens")
                    staleOriginalTask.destination = dir.appendingPathComponent("wrong-note-discovery.mp4")
                    var unrelatedRefresh = rediscoveredNote
                    unrelatedRefresh.noteID = "ffffffffffffffffffffffff"
                    let unrelatedRefreshNote = unrelatedRefresh
                    let refusedOutcome = try await X.downloadWithOriginalDiscovery(staleOriginalTask, sourceLoader: { unrelatedRefreshNote })
                    precondition(!refusedOutcome.usedOriginalLivePhoto && refusedOutcome.sourceURL == good,
                        "A different note's original must not be accepted during rediscovery")
                    print("PASS: failed GET refreshes exact-note originals once before playback; new key bytes, receipt/hash and unrelated-note rejection")

                    // An unavailable primary upload key first retries that key's
                    // backup, then only its exact client playback alternatives.
                    originalItem.liveURL = invalidOriginal
                    originalItem.liveOriginalURLs = [invalidOriginal, originalBackup]
                    originalItem.liveURLs = [invalidOriginal, originalBackup, good]
                    let backupDestination = dir.appendingPathComponent("xhs-upload-backup.mp4")
                    _ = try await X.download(X.livePhotoDownloadTask(originalItem, destination: backupDestination)!, retries: 0)
                    let publishedBackup = backupDestination.deletingPathExtension().appendingPathExtension("mov")
                    let backupDownloadedBytes = try Data(contentsOf: publishedBackup)
                    precondition(backupDownloadedBytes == expectedOriginal,
                        "A working original backup must win before a playable client stream")
                    originalItem.liveOriginalURLs = [invalidOriginal]
                    originalItem.liveURLs = [invalidOriginal, good]
                    let playbackDestination = dir.appendingPathComponent("xhs-upload-unavailable.mp4")
                    let playbackResult = try await X.download(X.livePhotoDownloadTask(originalItem, destination: playbackDestination)!, retries: 0)
                    precondition(playbackResult.isLivePhoto && playbackResult.hasAudio)
                    let playbackDownloadedBytes = try Data(contentsOf: playbackDestination)
                    precondition(playbackDownloadedBytes == expectedAudio,
                        "After original-source failure, preserve the exact client's validated playback bytes")

                    // When every exact source is silent, retain the successful
                    // original instead of treating absent audio as a failure.
                    originalItem.liveURL = silent
                    originalItem.liveOriginalURLs = [silent]
                    originalItem.liveURLs = [silent, base.appendingPathComponent("silent-fallback.mp4")]
                    let silentOriginalDestination = dir.appendingPathComponent("xhs-silent-upload.mp4")
                    let silentOriginalResult = try await X.download(X.livePhotoDownloadTask(originalItem, destination: silentOriginalDestination)!, retries: 0)
                    precondition(silentOriginalResult.isLivePhoto && !silentOriginalResult.hasAudio)
                    let silentOriginalBytes = try Data(contentsOf: silentOriginalDestination)
                    precondition(silentOriginalBytes == expectedSilent,
                        "When no exact source has audio, preserve the silent upload original bytes")

                    if CommandLine.arguments.count > 5 {
                        let silentNativeURL = URL(fileURLWithPath: CommandLine.arguments[5])
                        let silentNativeSource = base.appendingPathComponent("silent-original.mov")
                        originalItem.liveURL = silentNativeSource
                        originalItem.liveOriginalURLs = [silentNativeSource]
                        originalItem.liveURLs = [silentNativeSource, good]
                        let supplementedDestination = dir.appendingPathComponent("xhs-upload-supplemented.mp4")
                        let supplementedResult = try await X.download(X.livePhotoDownloadTask(originalItem, destination: supplementedDestination)!, retries: 0)
                        let supplementedMOV = supplementedDestination.deletingPathExtension().appendingPathExtension("mov")
                        precondition(supplementedResult.isLivePhoto && supplementedResult.hasAudio,
                            "An actual audio-bearing exact client stream must supplement a silent upload original")
                        let originalVideo = try await compressedTrackSamples(at: silentNativeURL, mediaType: .video)
                        let supplementedVideo = try await compressedTrackSamples(at: supplementedMOV, mediaType: .video)
                        precondition(!originalVideo.isEmpty && supplementedVideo == originalVideo,
                            "Audio supplementation must preserve every compressed original video sample")
                        let donorAudio = try await compressedTrackSamples(at: URL(fileURLWithPath: CommandLine.arguments[1]), mediaType: .audio)
                        let supplementedAudio = try await compressedTrackSamples(at: supplementedMOV, mediaType: .audio)
                        precondition(!supplementedAudio.isEmpty && supplementedAudio.count <= donorAudio.count)
                        precondition(supplementedAudio == Array(donorAudio.prefix(supplementedAudio.count)),
                            "Donor audio must be copied without re-encoding, clipped only to the original duration")
                        let originalIdentifier = try await livePhotoContentIdentifier(at: silentNativeURL)
                        let supplementedIdentifier = try await livePhotoContentIdentifier(at: supplementedMOV)
                        precondition(originalIdentifier == supplementedIdentifier,
                            "Audio supplementation must preserve the source's existing native Live Photo identifier")
                        let originalMetadataTracks = try await AVURLAsset(url: silentNativeURL).loadTracks(withMediaType: .metadata)
                        let supplementedMetadataTracks = try await AVURLAsset(url: supplementedMOV).loadTracks(withMediaType: .metadata)
                        precondition(originalMetadataTracks.count == supplementedMetadataTracks.count,
                            "Native timed metadata tracks must survive audio supplementation")
                        let originalSilentBytes = try Data(contentsOf: silentNativeURL)
                        originalItem.liveURLs = [silentNativeSource, base.appendingPathComponent("silent-fallback.mp4")]
                        let entirelySilentDestination = dir.appendingPathComponent("xhs-upload-no-audio.mp4")
                        let entirelySilentResult = try await X.download(X.livePhotoDownloadTask(originalItem, destination: entirelySilentDestination)!, retries: 0)
                        let entirelySilentMOV = entirelySilentDestination.deletingPathExtension().appendingPathExtension("mov")
                        let entirelySilentBytes = try Data(contentsOf: entirelySilentMOV)
                        precondition(entirelySilentResult.isLivePhoto && !entirelySilentResult.hasAudio)
                        precondition(entirelySilentBytes == originalSilentBytes,
                            "When the upload original and client stream are both silent, preserve the native MOV bytes")

                        // Inject only isolated fixture roots into the production
                        // recovery helper. The selected CDN identity is excluded
                        // from cloud requests but remains eligible for local audio.
                        let cachedSelected = URL(string: "https://sns-video-qc.xhscdn.com/stream/1/10/66/regression_selected_66.mp4?sign=fixture")!
                        let cachedIdentity = "stream_1_10_66_regression_selected_66"
                        func writeAudioCache(_ name: String, payload: Data) throws -> URL {
                            let cache = dir.appendingPathComponent("audio-cache-" + name, isDirectory: true)
                            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                            let padded = payload + Data(repeating: 0, count: 64)
                            try padded.write(to: cache.appendingPathComponent(cachedIdentity))
                            let map = "total_file_size:\(payload.count)\ncache_file_size:\(payload.count)\ncache_period_size:\(padded.count)\nentry_logical_pos:0\nentry_data_amount:\(payload.count)\nentry_physical_pos:0\nentry_info_flush\n"
                            try Data(map.utf8).write(to: cache.appendingPathComponent(cachedIdentity + "-map"))
                            return cache
                        }
                        func recoveryFixture(_ name: String, cloud: [URL]) throws -> (X.DownloadTask, URL) {
                            let destination = dir.appendingPathComponent("recovery-" + name + ".mp4")
                            let motion = dir.appendingPathComponent("recovery-" + name + ".mov")
                            try originalSilentBytes.write(to: motion)
                            return (X.DownloadTask(urls: [cachedSelected] + cloud, destination: destination,
                                requestUserAgent: X.mobileUserAgent, videoHDRHint: nil, isLivePhoto: true), motion)
                        }
                        let voicedCache = try writeAudioCache("voiced", payload: expectedAudio)
                        let (silentCloudTask, silentCloudMotion) = try recoveryFixture("silent-cloud", cloud: [silent])
                        let recoveredFromLocal = try await X.recoverLivePhotoAudio(silentCloudTask, at: silentCloudMotion,
                            excluding: cachedSelected, cacheRoots: [voicedCache])
                        precondition(recoveredFromLocal,
                            "A successful silent cloud response must still allow exact local audio from the selected client source")
                        let localPackets = try await compressedTrackSamples(at: silentCloudMotion, mediaType: .audio)
                        precondition(!localPackets.isEmpty && localPackets == Array(donorAudio.prefix(localPackets.count)),
                            "Selected-source cache audio must be copied without re-encoding")

                        let lpcmCache = try writeAudioCache("lpcm", payload: expectedOriginal)
                        let sourceAudioSubtype = try await audioTrackSubtype(at: URL(fileURLWithPath: CommandLine.arguments[4]))
                        let cloudAudioSubtype = try await audioTrackSubtype(at: URL(fileURLWithPath: CommandLine.arguments[1]))
                        precondition(sourceAudioSubtype != nil && cloudAudioSubtype != nil && sourceAudioSubtype != cloudAudioSubtype,
                            "Distinct cached LPCM and cloud AAC codecs must expose donor-priority mistakes")
                        let (voicedCloudTask, voicedCloudMotion) = try recoveryFixture("voiced-cloud", cloud: [good])
                        let recoveredFromCloud = try await X.recoverLivePhotoAudio(voicedCloudTask, at: voicedCloudMotion,
                            excluding: cachedSelected, cacheRoots: [lpcmCache])
                        precondition(recoveredFromCloud)
                        let chosenSubtype = try await audioTrackSubtype(at: voicedCloudMotion)
                        precondition(chosenSubtype == cloudAudioSubtype,
                            "Every usable cloud donor must take priority over cached audio")
                        let chosenPackets = try await compressedTrackSamples(at: voicedCloudMotion, mediaType: .audio)
                        precondition(!chosenPackets.isEmpty && chosenPackets == Array(donorAudio.prefix(chosenPackets.count)))

                        let silentCache = try writeAudioCache("silent", payload: expectedSilent)
                        let (noAudioTask, noAudioMotion) = try recoveryFixture("no-audio", cloud: [silent])
                        let allSilentRecovery = try await X.recoverLivePhotoAudio(noAudioTask, at: noAudioMotion,
                            excluding: cachedSelected, cacheRoots: [silentCache])
                        precondition(!allSilentRecovery)
                        let untouchedSilentMotion = try Data(contentsOf: noAudioMotion)
                        precondition(untouchedSilentMotion == originalSilentBytes,
                            "Silent cloud and local sources must leave the selected original unchanged")

                        let (onlySelectedTask, onlySelectedMotion) = try recoveryFixture("only-selected", cloud: [])
                        let onlySelectedRecovery = try await X.recoverLivePhotoAudio(onlySelectedTask, at: onlySelectedMotion,
                            excluding: cachedSelected, cacheRoots: [voicedCache])
                        precondition(onlySelectedRecovery,
                            "An empty cloud candidate list must still probe the exact selected client's local audio")
                        for task in [silentCloudTask, voicedCloudTask, noAudioTask, onlySelectedTask] {
                            for suffix in ["audio-source.part", "audio-merged.part"] {
                                precondition(!FileManager.default.fileExists(atPath: task.destination.appendingPathExtension(suffix).path),
                                    "Cloud and local recovery must clean temporary donors and compositions")
                            }
                        }
                        print("PASS: cloud audio before local cache, silent-cloud fallback to exact selected cache, all-silent byte preservation and selected-only local recovery")
                        print("PASS: silent original receives lossless donor audio with untouched video/native metadata; wholly silent sources preserve original MOV")
                    }

                    originalItem.liveURL = invalidOriginal
                    originalItem.liveOriginalURLs = [invalidOriginal]
                    originalItem.liveURLs = [invalidOriginal, base.appendingPathComponent("bad.mp4")]
                    let failedOriginalDestination = dir.appendingPathComponent("xhs-upload-rejected.mp4")
                    do {
                        _ = try await X.download(X.livePhotoDownloadTask(originalItem, destination: failedOriginalDestination)!, retries: 0)
                        fatalError("failed upload and client sources must not publish media")
                    } catch { }
                    for path in [failedOriginalDestination,
                                 failedOriginalDestination.deletingPathExtension().appendingPathExtension("mov"),
                                 failedOriginalDestination.appendingPathExtension("part")] {
                        precondition(!FileManager.default.fileExists(atPath: path.path))
                    }
                    print("PASS: original MOV byte/metadata preservation, native suffix, original backup before stream, wholly silent original preservation and failed-source cleanup")
                }
            }
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath:dir.path)
        precondition(remaining.allSatisfy { !$0.hasPrefix(".media-check") })
        print("PASS: audit regressions (timeline safety, XHS identity/completeness/quality/UA, cache versions, parsed Live Photo fallback when HTTP fixture supplied), pairing identity/sparse data, source ID, playback parameters, HTML/JSON/empty/wrong-type rejection, image and staged video validation")
    }
}
