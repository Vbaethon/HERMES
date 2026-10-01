import Foundation
import AppKit
import AVFoundation
import Darwin

enum ToolRunResult: Sendable { case success(String), failure(String) }

private actor DownloadStatusRecorder {
    private var messages: [String] = []
    func record(_ message: String) { messages.append(message) }
    func snapshot() -> [String] { messages }
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
        precondition(X.preferredNote([desktop,mobile])!.items.filter { $0.liveURL != nil }.count == 2)
        precondition(!X.noteIsLessComplete(mobile,mobile))
        precondition(!X.noteIsLessComplete(desktop,desktop))
        let sameDesktop = try xhsNote([1,2],mobile:false)
        precondition(X.preferredNote([sameDesktop,mobile])!.requestUserAgent == X.mobileUserAgent)
        precondition(X.preferredNote([mobile,sameDesktop])!.requestUserAgent == X.mobileUserAgent)
        let partial = X.preferredNote([try xhsNote([1],mobile:false),try xhsNote([2],mobile:true)])!
        precondition(partial.items.allSatisfy { $0.liveURL != nil })
        precondition(partial.items[0].liveUserAgent == X.desktopUserAgent)
        let otherNote = try xhsNote([1,2],mobile:true,identity:"other")
        precondition(X.preferredNote([desktop,otherNote])!.items.allSatisfy { $0.liveURL == nil })
        var highQuality = sameDesktop
        highQuality.items[0].liveScore += 1
        highQuality.items[0].imageQuality += 1
        highQuality.items[0].imageURL = URL(string:"https://sns-img.xhscdn.com/high-quality")!
        let richer = X.preferredNote([mobile,highQuality])!
        precondition(richer.items[0].liveScore == highQuality.items[0].liveScore)
        precondition(richer.items[0].imageURL == highQuality.items[0].imageURL)
        var videoDesktop = X.NoteInfo(noteID:"video",type:"video",videoURL:a,videoScore:100)
        videoDesktop.requestUserAgent = X.desktopUserAgent
        var videoMobile = videoDesktop
        videoMobile.requestUserAgent = X.mobileUserAgent
        videoMobile.videoScore = 1
        precondition(X.preferredNote([videoDesktop,videoMobile])!.requestUserAgent == X.desktopUserAgent)

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
        precondition(combined.items[0].liveURLs.contains(web.items[0].liveURL!))
        precondition(combined.usedAppCache)
        precondition(X.parseAppNote(appNote,expectedID:"ffffffffffffffffffffffff",fallbackURL:fallback) == nil)
        appNote["images_list"] = [appImage(1),appImage(1)]
        precondition(X.parseAppNote(appNote,expectedID:noteID,fallbackURL:fallback) == nil)
        appNote["images_list"] = [appImage(2)]
        let sparseClient = X.parseAppNote(appNote,expectedID:noteID,fallbackURL:fallback)!
        let sparseCombined = X.preferredNote([web,sparseClient])!
        precondition(!sparseCombined.items[0].liveHasAudio && sparseCombined.items[1].liveHasAudio)
        web.items[0].liveScore = Int64.max / 4
        precondition(X.preferredNote([web,client])!.items[0].liveHasAudio)
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
        precondition(!X.shouldRefreshClientCache(for: videoDesktop), "Video notes must not trigger still-image cache refresh")
        let originalsReady = X.preferredNote([ordinaryWeb, stillClient])!
        precondition(!X.shouldRefreshClientCache(for: originalsReady), "All exact client originals satisfy an ordinary still-image refresh")
        precondition(X.shouldRefreshClientCache(for: stillCombined), "Having image originals must not bypass the existing Live Photo audio refresh")
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
        let sourceStages = await imageStatuses.snapshot()
        precondition(sourceStages.contains { $0.contains("首选原图") })
        precondition(sourceStages.contains { $0.contains("首选原图失败") })
        precondition(sourceStages.contains { $0.contains("切换备用源") })
        precondition(sourceStages.contains { $0.contains("下载备用图片") })
        precondition(sourceStages.contains { $0.contains("校验图片") })
        precondition(sourceStages.last == "媒体下载完成，正在整理结果")
        precondition(sourceStages.allSatisfy { !$0.contains("http") }, "Progress text must not expose source URLs")

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
        let fallbackStages = await fallbackStatuses.snapshot()
        precondition(compatibilityBytes == validPNG)
        precondition(fallbackStages == ["当前源传输中断，正在重试"])

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
        let waitingStages = await waitingStatuses.snapshot()
        precondition(waitingStages.contains { $0.contains("第 1 张图片") && $0.contains("仍在等待下载") })
        precondition(!waitingStages.contains { $0.contains("失败") }, "Waiting alone must not be described as a failed source")
        precondition(waitingStages.last == "媒体下载完成，正在整理结果")
        let priorityStatuses = DownloadStatusRecorder()
        let statusAggregator = DownloaderInfra.$statusHandler.withValue({ message in
            await priorityStatuses.record(message)
        }) { DownloaderInfra.DownloadProgressAggregator(totalCount: 2, handler: nil) }
        await statusAggregator.updateStatus(index: 0, message: "第 1 张图片：仍在等待下载")
        await statusAggregator.updateStatus(index: 1, message: "第 2 张图片：正在校验图片")
        await statusAggregator.complete(index: 1)
        let priorityStages = await priorityStatuses.snapshot()
        precondition(priorityStages == ["第 1 张图片：仍在等待下载"])
        await statusAggregator.updateStatus(index: 0, message: "第 1 张图片：当前源已继续传输，正在下载")
        await statusAggregator.complete(index: 0)

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
            if await cancelledStatuses.snapshot().contains(where: { $0.contains("仍在等待下载") }) { observedWaiting = true; break }
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
            let outcomes = try await D.download([
                .init(url:base.appendingPathComponent("good.mp4"),destination:dir.appendingPathComponent("one.mp4")),
                .init(url:base.appendingPathComponent("good.mp4"),destination:dir.appendingPathComponent("two.mp4"))
            ],maxConcurrentDownloads:2)
            precondition(outcomes.count == 2 && outcomes.allSatisfy { !$0.usedFallback })
            if CommandLine.arguments.count > 3 {
                let silent = base.appendingPathComponent("silent.mp4")
                let good = base.appendingPathComponent("good.mp4")
                var audioItem = combined.items[0]
                audioItem.liveURL = silent
                audioItem.liveURLs = [silent, good]
                audioItem.audioURLs = [silent, good]
                let destination = dir.appendingPathComponent("xhs-audio.mp4")
                var audioTask = X.livePhotoDownloadTask(audioItem, destination:destination)!
                audioTask.displayOrder = displayOrder
                let result = try await X.download(audioTask, retries:0)
                precondition(result.isLivePhoto && result.hasAudio)
                precondition(MediaDisplayOrder.read(from: destination) == displayOrder)
                let expectedAudio = try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
                let downloadedAudio = try Data(contentsOf:destination)
                precondition(downloadedAudio == expectedAudio)
                // A failed client source may fall back, but must report actual silence.
                audioItem.liveURL = base.appendingPathComponent("bad.mp4")
                audioItem.liveURLs = [audioItem.liveURL!,silent]
                audioItem.audioURLs = [audioItem.liveURL!]
                let fallbackTask = X.livePhotoDownloadTask(audioItem,destination:dir.appendingPathComponent("xhs-silent.mp4"))!
                let silentResult = try await X.download(fallbackTask,retries:0)
                precondition(silentResult.isLivePhoto && !silentResult.hasAudio)
                // An advertised audio source alone must not publish a silent file.
                audioItem.liveURL = silent; audioItem.liveURLs = [silent]; audioItem.audioURLs = [silent]
                let rejected = dir.appendingPathComponent("xhs-rejected.mp4")
                do {
                    _ = try await X.download(X.livePhotoDownloadTask(audioItem,destination:rejected)!,retries:0)
                    fatalError("advertised audio silently lost")
                } catch { }
                precondition(!FileManager.default.fileExists(atPath:rejected.path))
                precondition(!FileManager.default.fileExists(atPath:rejected.appendingPathExtension("part").path))
                print("PASS: XHS client audio validation, silent source rejection, audio backup, explicit silent fallback")
            }
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath:dir.path)
        precondition(remaining.allSatisfy { !$0.hasPrefix(".media-check") })
        print("PASS: audit regressions (timeline safety, XHS identity/completeness/quality/UA, cache versions, parsed Live Photo fallback when HTTP fixture supplied), pairing identity/sparse data, source ID, playback parameters, HTML/JSON/empty/wrong-type rejection, image and staged video validation")
    }
}
