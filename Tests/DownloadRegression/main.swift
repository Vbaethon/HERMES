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
            let task = D.livePhotoDownloadTask(mergedMotion.images[0],destination:dir.appendingPathComponent("fixture-image-01.mp4"))!
            precondition(task.url == base.appendingPathComponent("bad.mp4"))
            let parsedOutcome = try await D.download(task,retries:0)
            precondition(parsedOutcome.usedFallback && parsedOutcome.fileURL.lastPathComponent == "fixture-image-01.mp4")
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
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath:dir.path)
        precondition(remaining.allSatisfy { !$0.hasPrefix(".media-check") })
        print("PASS: audit regressions (timeline safety, XHS identity/completeness/quality/UA, cache versions, parsed Live Photo fallback when HTTP fixture supplied), pairing identity/sparse data, source ID, playback parameters, HTML/JSON/empty/wrong-type rejection, image and staged video validation")
    }
}
