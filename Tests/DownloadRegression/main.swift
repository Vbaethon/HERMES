import Foundation
import AppKit
import AVFoundation

enum ToolRunResult: Sendable { case success(String), failure(String) }

@main struct DownloadRegression {
    static func main() async throws {
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
            let outcome = try await D.download(.init(url:base.appendingPathComponent("bad.mp4"),destination:dir.appendingPathComponent("fallback.mp4"),alternateURLs:[base.appendingPathComponent("good.mp4")]),retries:0)
            precondition(outcome.usedFallback)
            try await MediaFileUtilities.validateMedia(outcome.fileURL,expectedSuffix:"mp4")
            let outcomes = try await D.download([
                .init(url:base.appendingPathComponent("good.mp4"),destination:dir.appendingPathComponent("one.mp4")),
                .init(url:base.appendingPathComponent("good.mp4"),destination:dir.appendingPathComponent("two.mp4"))
            ],maxConcurrentDownloads:2)
            precondition(outcomes.count == 2 && outcomes.allSatisfy { !$0.usedFallback })
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath:dir.path)
        precondition(remaining.allSatisfy { !$0.hasPrefix(".media-check") })
        print("PASS: pairing identity/sparse data, source ID, playback parameters, HTML/JSON/empty/wrong-type rejection, image and staged video validation")
    }
}
