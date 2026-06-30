import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum XHSNativeDownloader {
    private static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let maxConcurrentDownloads = DownloaderHTTPCompatibility.downloadConcurrencyLimit()
    private static let networkSession: URLSession = DownloaderHTTPCompatibility.makeDownloadSession()

    private struct NoteInfo {
        var noteID = ""
        var title = ""
        var author = "unknown"
        var userID = ""
        var type = ""
        var items: [MediaItem] = []
        var videoURL: URL?
        var videoURLs: [URL] = []
        var videoScore: Int64 = 0
        var videoHDRHint: VideoHDRHint?
        var requestUserAgent = mobileUserAgent

        var hasMedia: Bool {
            !items.isEmpty || videoURL != nil
        }
    }

    private struct MediaItem {
        var index: Int
        var imageURL: URL
        var liveURL: URL?
        var liveURLs: [URL]
        var fileID: String
    }

    private struct DownloadTask {
        var urls: [URL]
        var destination: URL
        var stripsDescription: Bool
        var requestUserAgent: String
        var videoHDRHint: VideoHDRHint?
        var cookie: String?
    }

    private struct VideoHDRHint {
        var sourceMarkedHDR = false
        var streamMarkedHDR = false
        var transferFunction: String?
        var colorPrimaries: String?
        var yCbCrMatrix: String?

        var needsPassthroughRemux: Bool {
            sourceMarkedHDR || streamMarkedHDR
        }
    }

    static func run(
        shareText: String,
        destinationRoot: URL,
        progress: DownloaderInfra.ProgressHandler? = nil,
        cookie: String? = nil
    ) async -> ToolRunResult {
        do {
            let links = try await extractLinks(from: shareText)
            guard !links.isEmpty else {
                return .failure("没有提取到小红书作品链接。")
            }
            let accountIDHint = links.count == 1 ? extractAccountIDHint(from: shareText) : nil

            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            var lines: [String] = []
            for link in links {
                let note = try await fetchNote(link, cookie: cookie)
                let author = FileNaming.sanitizeFileName(note.author.isEmpty ? "unknown" : note.author, fallback: "unknown")
                let rawUserID = note.userID.isEmpty ? (accountIDHint ?? "") : note.userID
                let userID = rawUserID.isEmpty ? "" : cleanAccountName(rawUserID)
                let outputFolder = try FileNaming.userOutputFolder(root: destinationRoot, author: author, userID: userID, defaultName: "xhs_note")
                let folderName = outputFolder.lastPathComponent
                try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

                var usedNames = Set<String>()
                var tasks: [DownloadTask] = []
                for item in note.items {
                    let baseName = originalFileIDBasename(item.fileID, defaultName: String(format: "%02d", item.index))
                    tasks.append(DownloadTask(
                        urls: [item.imageURL],
                        destination: FileNaming.uniqueDestination(in: outputFolder, name: "\(baseName).bin", usedNames: &usedNames),
                        stripsDescription: false,
                        requestUserAgent: note.requestUserAgent,
                        videoHDRHint: nil,
                        cookie: cookie
                    ))
                    if let liveURL = item.liveURL {
                        tasks.append(DownloadTask(
                            urls: item.liveURLs.isEmpty ? [liveURL] : item.liveURLs,
                            destination: FileNaming.uniqueDestination(in: outputFolder, name: "\(baseName).mp4", usedNames: &usedNames),
                            stripsDescription: false,
                            requestUserAgent: note.requestUserAgent,
                            videoHDRHint: nil,
                            cookie: cookie
                        ))
                    }
                }

                if let videoURL = note.videoURL {
                    tasks.append(DownloadTask(
                        urls: note.videoURLs.isEmpty ? [videoURL] : note.videoURLs,
                        destination: FileNaming.uniqueDestination(in: outputFolder, name: originalURLFilename(videoURL, defaultName: "video.mp4"), usedNames: &usedNames),
                        stripsDescription: false,
                        requestUserAgent: note.requestUserAgent,
                        videoHDRHint: note.videoHDRHint,
                        cookie: cookie
                    ))
                }

                guard !tasks.isEmpty else {
                    throw NSError(domain: "XHSDownloader", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有可下载的小红书媒体。"])
                }

                try await download(tasks, progress: progress)
                let liveCount = note.items.filter { $0.liveURL != nil }.count
                let videoCount = note.videoURL == nil ? 0 : 1
                lines.append([
                    "noteId: \(note.noteID)",
                    "用户: \(folderName)",
                    "分享链接: \(link.absoluteString)",
                    "下载原图: \(note.items.count) 张",
                    "下载视频: \(videoCount) 个",
                    note.videoHDRHint?.sourceMarkedHDR == true ? "HDR: 源视频标记为 HDR，已优先保留最高规格视频流" : nil,
                    "下载 Live Photo 视频: \(liveCount) 个",
                    "输出目录: \(outputFolder.path)"
                ].compactMap { $0 }.joined(separator: "\n"))
            }
            lines.append("完成。输出只保留媒体文件，不保存鉴权链接。")
            return .success(lines.joined(separator: "\n\n"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func extractLinks(from text: String) async throws -> [URL] {
        let patterns = [
            #"(?:https?://)?(?:www\.)?xiaohongshu\.com/explore/[^\s"<>\\^`{|}，。；！？、【】《》]+"#,
            #"(?:https?://)?(?:www\.)?xiaohongshu\.com/discovery/item/[^\s"<>\\^`{|}，。；！？、【】《》]+"#,
            #"(?:https?://)?(?:www\.)?xiaohongshu\.com/user/profile/[a-z0-9]+/[^\s"<>\\^`{|}，。；！？、【】《》]+"#,
            #"(?:https?://)?xhslink\.com/[^\s"<>\\^`{|}，。；！？、【】《》]+"#
        ]
        var links: [URL] = []
        var seen = Set<String>()
        for pattern in patterns {
            for rawValue in RegexUtilities.allMatches(pattern, in: text) {
                let cleaned = MediaFileUtilities.trimURLPunctuation(rawValue)
                guard let sourceURL = normalizedShareURL(cleaned) else { continue }
                let resolvedURL = sourceURL.host == "xhslink.com" ? (try? await resolveURL(sourceURL)) ?? sourceURL : sourceURL
                guard seen.insert(resolvedURL.absoluteString).inserted else { continue }
                links.append(resolvedURL)
            }
        }
        let trimmedText = MediaFileUtilities.trimURLPunctuation(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmedText.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           let directURL = normalizedShareURL(trimmedText),
           directURL.host == "xhslink.com" || directURL.host?.contains("xiaohongshu.com") == true {
            let resolvedURL = directURL.host == "xhslink.com" ? (try? await resolveURL(directURL)) ?? directURL : directURL
            if seen.insert(resolvedURL.absoluteString).inserted {
                links.append(resolvedURL)
            }
        }
        return links
    }

    private static func normalizedShareURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value) else { return nil }
        if components.scheme == nil {
            components.scheme = components.host == "xhslink.com" ? "http" : "https"
        }
        return components.url
    }

    private static func extractAccountIDHint(from text: String) -> String? {
        let patterns = [
            #"(?i)(?:小红书号|红书号|red\s*id|redid)\s*(?:是|[:：])\s*([A-Za-z0-9._-]{3,40})"#,
            #"(?i)(?:小红书号|红书号|red\s*id|redid)\s+([A-Za-z0-9._-]{3,40})"#
        ]
        for pattern in patterns {
            if let value = RegexUtilities.firstCapture(1, pattern: pattern, in: text) {
                return value
            }
        }
        return nil
    }

    private static func resolveURL(_ url: URL) async throws -> URL {
        let (_, responseURL) = try await requestAsync(url, readsBody: false)
        return responseURL ?? url
    }

    private static func fetchNote(_ url: URL, cookie: String? = nil) async throws -> NoteInfo {
        var notes: [NoteInfo] = []
        var desktopMessage: String?
        var firstError: Error?
        do {
            var desktopResult = try await fetchNoteOnce(url, requestUserAgent: desktopUserAgent, cookie: cookie)
            desktopMessage = desktopResult.sourceMessage
            if desktopResult.note.hasMedia {
                desktopResult.note.requestUserAgent = desktopUserAgent
                notes.append(desktopResult.note)
            }
        } catch {
            firstError = error
        }

        var mobileMessage: String?
        do {
            var mobileResult = try await fetchNoteOnce(url, requestUserAgent: mobileUserAgent, cookie: cookie)
            mobileMessage = mobileResult.sourceMessage
            if mobileResult.note.hasMedia {
                mobileResult.note.requestUserAgent = mobileUserAgent
                notes.append(mobileResult.note)
            }
        } catch {
            if firstError == nil {
                firstError = error
            }
        }

        if let bestNote = notes.max(by: { lhs, rhs in
            let lhsScore = noteScore(lhs)
            let rhsScore = noteScore(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            // Tiebreaker: mobile UA responses typically carry richer stream metadata
            // (width, height, videoBitrate, etc.) that desktop responses strip out.
            return lhs.requestUserAgent == mobileUserAgent
        }) {
            return bestNote
        }
        if let firstError {
            throw firstError
        }
        let sourceMessage = desktopMessage ?? mobileMessage
        let detail = sourceMessage.map { "源站返回：\($0)" } ?? "源站未返回 imageList/video。"
        throw NSError(domain: "XHSDownloader", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有可下载的小红书媒体。\(detail)"])
    }

    private static func fetchNoteOnce(_ url: URL, requestUserAgent: String, cookie: String? = nil) async throws -> (note: NoteInfo, sourceMessage: String?) {
        let (data, _) = try await requestAsync(url, readsBody: true, requestUserAgent: requestUserAgent, cookie: cookie)
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let state = try extractInitialState(from: html)
        guard let note = extractNote(from: state) else {
            throw NSError(domain: "XHSDownloader", code: 4, userInfo: [NSLocalizedDescriptionKey: "未能从页面提取 noteData。"])
        }
        return (try parseNote(note, fallbackURL: url), sourceErrorMessage(from: state))
    }

    private static func extractNote(from state: [String: Any]) -> [String: Any]? {
        if let note = deepGet(state, keys: ["noteData", "data", "noteData"]) as? [String: Any] {
            return note
        }
        if let note = deepGet(state, keys: ["note", "noteDetailMap", "[-1]", "note"]) as? [String: Any] {
            return note
        }
        guard let detailMap = deepGet(state, keys: ["note", "noteDetailMap"]) as? [String: Any] else {
            return nil
        }
        for value in detailMap.values {
            if let container = value as? [String: Any],
               let note = container["note"] as? [String: Any] {
                return note
            }
        }
        return nil
    }

    private static func sourceErrorMessage(from state: [String: Any]) -> String? {
        if let message = JSONValueUtilities.nonEmptyString(deepGet(state, keys: ["note", "serverRequestInfo", "errMsg"])) {
            return message
        }
        if let message = JSONValueUtilities.nonEmptyString(deepGet(state, keys: ["noteData", "data", "msg"])) {
            return message
        }
        if let message = JSONValueUtilities.nonEmptyString(deepGet(state, keys: ["noteData", "msg"])) {
            return message
        }
        return nil
    }

    private static func parseNote(_ note: [String: Any], fallbackURL: URL) throws -> NoteInfo {
        let user = note["user"] as? [String: Any] ?? [:]
        var info = NoteInfo()
        info.noteID = JSONValueUtilities.string(note["noteId"]) ?? fallbackURL.lastPathComponent
        info.title = JSONValueUtilities.string(note["title"]) ?? ""
        info.author = JSONValueUtilities.string(user["nickname"]) ?? JSONValueUtilities.string(user["nickName"]) ?? JSONValueUtilities.string(user["userId"]) ?? JSONValueUtilities.string(user["id"]) ?? "unknown"
        info.userID = JSONValueUtilities.string(user["redId"])
            ?? JSONValueUtilities.string(user["redID"])
            ?? JSONValueUtilities.string(user["red_id"])
            ?? ""
        info.type = JSONValueUtilities.string(note["type"]) ?? ""

        if info.type != "video" {
            let imageList = note["imageList"] as? [[String: Any]] ?? []
            for (offset, item) in imageList.enumerated() {
                guard let imageCandidate = bestImageURL(from: item) else {
                    continue
                }
                let liveCandidate = bestLivePhotoCandidate(from: item)
                let liveURLs = liveCandidate.map { streamURLs($0.item) } ?? []
                info.items.append(MediaItem(
                    index: offset + 1,
                    imageURL: imageCandidate.url,
                    liveURL: liveURLs.first,
                    liveURLs: liveURLs,
                    fileID: JSONValueUtilities.nonEmptyString(item["fileId"]) ?? imageCandidate.token
                ))
            }
        }

        if info.type == "video" {
            if let bestVideo = bestVideoCandidate(from: note) {
                info.videoURLs = streamURLs(bestVideo.item)
                info.videoURL = info.videoURLs.first
                info.videoScore = streamScore(bestVideo)
                info.videoHDRHint = videoHDRHint(from: bestVideo.item)
            } else if let originKey = JSONValueUtilities.nonEmptyString(deepGet(note, keys: ["video", "consumer", "originVideoKey"])) {
                info.videoURL = URL(string: "https://sns-video-bd.xhscdn.com/\(MediaFileUtilities.formatURL(originKey))")
                info.videoHDRHint = videoHDRHint(from: note)
            }
        }
        return info
    }

    private static func extractInitialState(from html: String) throws -> [String: Any] {
        guard let rawText = RegexUtilities.firstCapture(1, pattern: #"window\.__INITIAL_STATE__=(.*?)</script>"#, in: html, dotMatchesLineSeparators: true) else {
            throw NSError(domain: "XHSDownloader", code: 5, userInfo: [NSLocalizedDescriptionKey: "页面中没有 window.__INITIAL_STATE__。"])
        }
        let decoded = MediaFileUtilities.htmlDecode(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        let normalized = decoded.replacingOccurrences(
            of: #"(?<=[:\[,])\s*undefined\s*(?=[,\]}])"#,
            with: "null",
            options: .regularExpression
        )
        guard let data = normalized.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "XHSDownloader", code: 6, userInfo: [NSLocalizedDescriptionKey: "小红书页面数据不是有效 JSON。"])
        }
        return json
    }

    private struct StreamCandidate {
        var codec: String
        var item: [String: Any]
    }

    private struct ImageCandidate {
        var sourceText: String
        var token: String
        var url: URL
        var keyHint: String
    }

    private static func bestVideoURL(from note: [String: Any]) -> URL? {
        if let best = bestVideoCandidate(from: note),
           let url = streamURL(best.item) {
            return url
        }
        if let originKey = JSONValueUtilities.nonEmptyString(deepGet(note, keys: ["video", "consumer", "originVideoKey"])) {
            return URL(string: "https://sns-video-bd.xhscdn.com/\(MediaFileUtilities.formatURL(originKey))")
        }
        return nil
    }

    private static func bestVideoCandidate(from note: [String: Any]) -> StreamCandidate? {
        var candidates: [StreamCandidate] = []
        let inheritedVideoMeta = deepGet(note, keys: ["video", "media", "video"]) as? [String: Any] ?? [:]
        if let stream = deepGet(note, keys: ["video", "media", "stream"]) as? [String: Any] {
            candidates.append(contentsOf: streamCandidates(from: stream, inheritedMeta: inheritedVideoMeta))
        }
        if let mediaV2Text = JSONValueUtilities.nonEmptyString(deepGet(note, keys: ["video", "mediaV2"])),
           let mediaV2 = parseJSONString(mediaV2Text) as? [String: Any] {
            let mediaV2VideoMeta = deepGet(mediaV2, keys: ["video"]) as? [String: Any] ?? [:]
            if let stream = deepGet(mediaV2, keys: ["stream"]) as? [String: Any] {
                candidates.append(contentsOf: streamCandidates(from: stream, inheritedMeta: mediaV2VideoMeta))
            }
            if let stream = deepGet(mediaV2, keys: ["video", "stream"]) as? [String: Any] {
                candidates.append(contentsOf: streamCandidates(from: stream, inheritedMeta: mediaV2VideoMeta))
            }
            if var opaque = deepGet(mediaV2, keys: ["video", "opaque1"]) as? [String: Any] {
                if let width = deepGet(mediaV2, keys: ["video", "width"]) {
                    opaque["width"] = width
                }
                if let height = deepGet(mediaV2, keys: ["video", "height"]) {
                    opaque["height"] = height
                }
                if let hdrType = deepGet(mediaV2, keys: ["video", "hdr_type"]) {
                    opaque["hdr_type"] = hdrType
                }
                inheritVideoHDRMetadata(from: mediaV2VideoMeta, into: &opaque)
                candidates.append(contentsOf: screencastCandidates(from: opaque, inheritedMeta: mediaV2VideoMeta))
            }
        }

        return candidates.max(by: { streamScore($0) < streamScore($1) })
    }

    private static func bestLivePhotoURL(from item: [String: Any]) -> URL? {
        bestLivePhotoCandidate(from: item).flatMap { streamURL($0.item) }
    }

    private static func bestLivePhotoCandidate(from item: [String: Any]) -> StreamCandidate? {
        let candidates = nestedStreamCandidates(in: item)
        return candidates.max { lhs, rhs in
            streamScore(lhs) < streamScore(rhs)
        }
    }

    private static func bestImageURL(from item: [String: Any]) -> ImageCandidate? {
        let candidates = nestedImageCandidates(in: item)
        return candidates.max { lhs, rhs in
            imageScore(lhs) < imageScore(rhs)
        }
    }

    private static func noteScore(_ note: NoteInfo) -> Int64 {
        if note.videoURL != nil {
            var score = note.videoScore
            let urlText = note.videoURL?.absoluteString.lowercased() ?? ""
            if note.requestUserAgent == desktopUserAgent, urlText.contains("/stream/1/") {
                score += 5_000_000_000_000
            }
            if urlText.contains("watermark") || urlText.contains("/wm") {
                score -= 1_000_000_000_000
            }
            return score
        }
        return Int64(note.items.count) * 1_000_000_000
    }

    private static func streamCandidates(from stream: [String: Any], inheritedMeta: [String: Any] = [:]) -> [StreamCandidate] {
        var candidates: [StreamCandidate] = []
        for key in ["h264", "h265", "h266", "av1"] {
            if let values = stream[key] as? [[String: Any]] {
                candidates.append(contentsOf: values.map {
                    var item = $0
                    inheritVideoHDRMetadata(from: inheritedMeta, into: &item)
                    return StreamCandidate(codec: key, item: item)
                })
            }
        }
        return candidates
    }

    private static func screencastCandidates(from dict: [String: Any], inheritedMeta: [String: Any] = [:]) -> [StreamCandidate] {
        var candidates: [StreamCandidate] = []
        for (key, codec, hint) in [
            ("hd_screencast_stream", "h265", "hd_screencast"),
            ("default_screencast_stream", "h264", "default_screencast")
        ] as [(String, String, String)] {
            if let urlString = JSONValueUtilities.nonEmptyString(dict[key]) {
                var item = dict
                item["master_url"] = urlString
                item["stream_quality_hint"] = hint
                inheritVideoHDRMetadata(from: inheritedMeta, into: &item)
                candidates.append(StreamCandidate(codec: codec, item: item))
            }
        }
        return candidates
    }

    private static func nestedStreamCandidates(in value: Any, depth: Int = 0) -> [StreamCandidate] {
        guard depth <= 5 else { return [] }
        if let mediaV2Text = value as? String, mediaV2Text.contains("stream"),
           let mediaV2 = parseJSONString(mediaV2Text) {
            return nestedStreamCandidates(in: mediaV2, depth: depth + 1)
        }
        if let values = value as? [Any] {
            return values.flatMap { nestedStreamCandidates(in: $0, depth: depth + 1) }
        }
        guard let dictionary = value as? [String: Any] else {
            return []
        }

        var candidates = streamCandidates(from: dictionary, inheritedMeta: dictionary)
        candidates.append(contentsOf: screencastCandidates(from: dictionary, inheritedMeta: dictionary))
        for nestedValue in dictionary.values {
            candidates.append(contentsOf: nestedStreamCandidates(in: nestedValue, depth: depth + 1))
        }
        return candidates
    }

    private static func nestedImageCandidates(in value: Any, keyHint: String = "", depth: Int = 0) -> [ImageCandidate] {
        guard depth <= 5 else { return [] }
        if let text = value as? String {
            let decoded = MediaFileUtilities.formatURL(text)
            guard decoded.contains("xhscdn.com") || decoded.contains("sns-img") || decoded.contains("imageView") else {
                return []
            }
            let token = extractImageToken(decoded)
            guard !token.isEmpty, let url = imageURL(from: decoded, token: token) else {
                return []
            }
            return [ImageCandidate(sourceText: decoded, token: token, url: url, keyHint: keyHint)]
        }
        if let values = value as? [Any] {
            return values.flatMap { nestedImageCandidates(in: $0, keyHint: keyHint, depth: depth + 1) }
        }
        guard let dictionary = value as? [String: Any] else {
            return []
        }
        return dictionary.flatMap { key, nestedValue in
            nestedImageCandidates(in: nestedValue, keyHint: key, depth: depth + 1)
        }
    }

    private static func streamURL(_ item: [String: Any]) -> URL? {
        streamURLs(item).first
    }

    private static func streamURLs(_ item: [String: Any]) -> [URL] {
        var values: [String] = []
        for key in ["masterUrl", "master_url"] {
            if let value = JSONValueUtilities.nonEmptyString(item[key]) {
                values.append(value)
            }
        }
        for key in ["backupUrls", "backup_urls"] {
            values.append(contentsOf: (item[key] as? [String] ?? []).filter { !$0.isEmpty })
        }
        var seen = Set<String>()
        return values.compactMap { URL(string: MediaFileUtilities.formatURL($0)) }.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func streamScore(_ candidate: StreamCandidate) -> Int64 {
        let item = candidate.item
        let urlText = streamURL(item)?.absoluteString ?? ""
        let width = JSONValueUtilities.intValue(value(in: item, keys: ["width"]))
        let height = JSONValueUtilities.intValue(value(in: item, keys: ["height"]))
        let videoBitrate = JSONValueUtilities.intValue(value(in: item, keys: ["videoBitrate", "video_bitrate"]))
        let bitrate = videoBitrate != 0 ? videoBitrate : JSONValueUtilities.intValue(value(in: item, keys: ["avgBitrate", "avg_bitrate"]))
        let size = JSONValueUtilities.intValue(item["size"])
        let fps = videoFPSHint(urlText: urlText, meta: item)
        let hdr = videoHDRHint(urlText: urlText, meta: item)
        let qualityHint = (JSONValueUtilities.nonEmptyString(item["stream_quality_hint"]) ?? "").lowercased()
        let codecScore: Int64
        switch candidate.codec.lowercased() {
        case "av1":
            codecScore = 3
        case "h266":
            codecScore = 2
        case "h265":
            codecScore = 1
        default:
            codecScore = 0
        }

        var score = Int64(hdr) * 10_000_000_000_000
            + Int64(fps) * 100_000_000_000
            + Int64(width * height) * 1_000_000
            + Int64(bitrate) * 1_000
            + Int64(size)
            + codecScore
        let lowercasedURLText = urlText.lowercased()
        if lowercasedURLText.contains("/stream/1/") {
            score += 8_000_000_000_000
        } else if lowercasedURLText.contains("/stream/79/") {
            score -= 2_000_000_000_000
        }
        if qualityHint == "hd_screencast" {
            score += 5_000_000_000_000
        } else if qualityHint == "default_screencast" {
            score += 100_000_000
        }
        return score
    }

    private static func imageScore(_ candidate: ImageCandidate) -> Int {
        let key = candidate.keyHint.lowercased()
        let text = candidate.sourceText.lowercased()
        let urlText = candidate.url.absoluteString.lowercased()
        var score = 0
        if key.contains("urldefault") || key == "url" {
            score += 10_000
        }
        if !key.contains("pre") && !key.contains("thumb") && !key.contains("cover") {
            score += 5_000
        }
        if urlText.contains("sns-img-bd.xhscdn.com") {
            score += 2_000
        }
        if !text.contains("imageview") && !text.contains("resize") && !text.contains("thumbnail") {
            score += 1_000
        }
        if candidate.token.contains("note_pre_post") {
            score += 20_000
        }
        if candidate.token.contains("note_pre_post_uhdr") {
            score += 30_000
        }
        if text.contains("h5_") || text.contains("style_") || text.contains("imageview") {
            score -= 5_000
        }
        score += min(candidate.token.count, 500)
        return score
    }

    private static func inheritVideoHDRMetadata(from inheritedMeta: [String: Any], into item: inout [String: Any]) {
        for key in ["hdrType", "hdr_type", "dynamicRange", "dynamic_range", "videoCodec", "video_codec", "codec", "format", "streamType"] {
            if let value = inheritedMeta[key], item[key] == nil {
                item[key] = value
            }
        }
        if item["hdrType"] == nil, let value = inheritedMeta["hdr_type"] {
            item["hdrType"] = value
        }
        if item["hdr_type"] == nil, let value = inheritedMeta["hdrType"] {
            item["hdr_type"] = value
        }
    }

    private static func videoHDRHint(from meta: [String: Any]) -> VideoHDRHint? {
        let hdrType = JSONValueUtilities.intValue(meta["hdrType"]) != 0
            ? JSONValueUtilities.intValue(meta["hdrType"])
            : JSONValueUtilities.intValue(meta["hdr_type"])
        let text = [
            JSONValueUtilities.nonEmptyString(meta["dynamicRange"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["dynamic_range"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["qualityType"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["quality_type"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["videoCodec"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["video_codec"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["codec"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["format"]) ?? ""
        ].joined(separator: " ").lowercased()

        var hint = VideoHDRHint()
        hint.sourceMarkedHDR = hdrType > 0 || JSONValueUtilities.boolValue(meta["hdr"]) || JSONValueUtilities.boolValue(meta["isHDR"]) || JSONValueUtilities.boolValue(meta["is_hdr"]) || text.contains("hdr") || text.contains("hlg") || text.contains("dolby") || text.contains("dovi")
        hint.streamMarkedHDR = hdrType > 1 || text.contains("hdr10") || text.contains("10bit") || text.contains("10-bit") || text.contains("main10") || text.contains("dvhe")
        hint.transferFunction = text.contains("hlg") ? "ITU_R_2100_HLG" : (text.contains("pq") || text.contains("hdr10") || text.contains("dolby") ? "SMPTE_ST_2084_PQ" : nil)
        hint.colorPrimaries = hint.sourceMarkedHDR ? "ITU_R_2020" : nil
        hint.yCbCrMatrix = hint.sourceMarkedHDR ? "ITU_R_2020" : nil
        return hint.sourceMarkedHDR ? hint : nil
    }

    private static func videoFPSHint(urlText: String, meta: [String: Any]) -> Int {
        let text = ([
            urlText,
            JSONValueUtilities.nonEmptyString(meta["fps"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["frameRate"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["frame_rate"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["fpsType"]) ?? ""
        ]).joined(separator: " ").lowercased()
        var values = RegexUtilities.allMatches(#"\d{2,3}\s*fps"#, in: text).compactMap { Int($0.filter(\.isNumber)) }
        for key in ["fps", "frameRate", "frame_rate"] {
            if let value = Double(JSONValueUtilities.string(meta[key]) ?? ""), value > 0 {
                values.append(Int(value.rounded()))
            }
        }
        return values.max() ?? 0
    }

    private static func videoHDRHint(urlText: String, meta: [String: Any]) -> Int {
        let text = ([
            urlText,
            JSONValueUtilities.nonEmptyString(meta["hdrType"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["hdr_type"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["dynamicRange"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["dynamic_range"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["qualityType"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["quality_type"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["videoCodec"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["codec"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["format"]) ?? "",
            JSONValueUtilities.nonEmptyString(meta["streamType"]) ?? ""
        ]).joined(separator: " ").lowercased()
        if text.contains("dolby") || text.contains("dvhe") || text.contains("dovi") {
            return 4
        }
        if text.contains("hdr10") || text.contains("hdr") || text.contains("hlg") {
            return 3
        }
        if text.contains("10bit") || text.contains("10-bit") || text.contains("main10") {
            return 2
        }
        if JSONValueUtilities.boolValue(meta["hdr"]) || JSONValueUtilities.boolValue(meta["isHDR"]) || JSONValueUtilities.boolValue(meta["is_hdr"]) {
            return 3
        }
        if JSONValueUtilities.intValue(meta["hdrType"]) > 0 || JSONValueUtilities.intValue(meta["hdr_type"]) > 0 {
            return 2
        }
        return 0
    }

    private static func imageURL(from imageURLText: String, token: String) -> URL? {
        let decoded = MediaFileUtilities.formatURL(imageURLText)
        let firstPathComponent = token.split(separator: "/").first.map(String.init) ?? ""
        if firstPathComponent.range(of: #"^\d{12}$"#, options: .regularExpression) != nil,
           let originalURL = URL(string: decoded) {
            return originalURL
        }
        return URL(string: "https://sns-img-bd.xhscdn.com/\(token)")
    }

    private static func parseJSONString(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func value(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dictionary[key] {
                return value
            }
        }
        return nil
    }

    private static func requestAsync(_ url: URL, readsBody: Bool, requestUserAgent: String = mobileUserAgent, cookie: String? = nil) async throws -> (Data, URL?) {
        let requestURL = secureXHSURL(url)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.assumesHTTP3Capable = false
        request.setValue(requestUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.xiaohongshu.com/explore", forHTTPHeaderField: "Referer")
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        if requestURL.host?.lowercased() == "xhslink.com"
            || DownloaderHTTPCompatibility.shouldUseDirectly(for: request) {
            return try await DownloaderHTTPCompatibility.dataAsync(for: request, readsBody: readsBody)
        }
        do {
            let (data, response) = try await networkSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200..<400).contains(httpResponse.statusCode) {
                throw NSError(domain: "XHSDownloader", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode): \(requestURL.absoluteString)"])
            }
            return (readsBody ? data : Data(), response.url)
        } catch {
            guard DownloaderHTTPCompatibility.shouldFallback(after: error) else { throw error }
            return try await DownloaderHTTPCompatibility.dataAsync(for: request, readsBody: readsBody)
        }
    }

    private static func download(
        _ tasks: [DownloadTask],
        maxConcurrentDownloads requestedMaxConcurrentDownloads: Int? = nil,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async throws {
        guard !tasks.isEmpty else { return }
        let limit = max(1, requestedMaxConcurrentDownloads ?? maxConcurrentDownloads)
        let progressAggregator = DownloaderInfra.DownloadProgressAggregator(totalCount: tasks.count, handler: progress)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iter = Array(tasks.enumerated()).makeIterator()
            for _ in 0..<min(limit, tasks.count) {
                guard let t = iter.next() else { break }
                group.addTask {
                    try await download(t.element) { fraction in
                        await progressAggregator.update(index: t.offset, fraction: fraction)
                    }
                    await progressAggregator.complete(index: t.offset)
                }
            }
            for try await _ in group {
                guard let t = iter.next() else { continue }
                group.addTask {
                    try await download(t.element) { fraction in
                        await progressAggregator.update(index: t.offset, fraction: fraction)
                    }
                    await progressAggregator.complete(index: t.offset)
                }
            }
        }
    }

    private static func download(
        _ task: DownloadTask,
        retries: Int = 3,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async throws {
        var lastError: Error?
        for attempt in 0...retries {
            do {
                try FileManager.default.createDirectory(at: task.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporaryURL = task.destination.appendingPathExtension("part")
                for sourceURL in task.urls {
                    do {
                        try await downloadOnceAsync(sourceURL, to: temporaryURL, requestUserAgent: task.requestUserAgent, cookie: task.cookie, progress: progress)
                        let suffix = MediaFileUtilities.sniffSuffix(temporaryURL, defaultSuffix: task.destination.pathExtension.isEmpty ? "bin" : task.destination.pathExtension)
                        let finalURL = task.destination.deletingPathExtension().appendingPathExtension(suffix)
                        try? FileManager.default.removeItem(at: finalURL)
                        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: finalURL.path)
                        if task.stripsDescription, ["heic", "heif", "jpg", "jpeg", "png", "webp"].contains(finalURL.pathExtension.lowercased()) {
                            try? stripImageDescription(finalURL)
                        }
                        if let videoHDRHint = task.videoHDRHint, finalURL.pathExtension.lowercased() == "mp4" {
                            try? await remuxHDRVideoIfNeeded(at: finalURL, hint: videoHDRHint)
                        }
                        return
                    } catch {
                        lastError = error
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                }
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: task.destination.appendingPathExtension("part"))
                if attempt < retries {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                }
            }
        }
        throw lastError ?? NSError(domain: "XHSDownloader", code: 7, userInfo: [NSLocalizedDescriptionKey: "下载失败：\(task.destination.lastPathComponent)"])
    }

    private static func remuxHDRVideoIfNeeded(at url: URL, hint: VideoHDRHint) async throws {
        guard hint.needsPassthroughRemux else { return }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isReadable) else { return }
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).hdrremux.mp4")
        try? FileManager.default.removeItem(at: tempURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        exportSession.shouldOptimizeForNetworkUse = true
        do {
            try await exportSession.export(to: tempURL, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        guard FileManager.default.fileExists(atPath: tempURL.path) else { return }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    private static func shouldUseDirectly(_ req: URLRequest) -> Bool {
        req.url?.host?.lowercased() == "xhslink.com" || DownloaderHTTPCompatibility.shouldUseDirectly(for: req)
    }

    private static func downloadOnceAsync(
        _ url: URL,
        to destination: URL,
        requestUserAgent: String,
        cookie: String? = nil,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async throws {
        let requestURL = secureXHSURL(url)
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 30
        request.assumesHTTP3Capable = false
        request.setValue(requestUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if shouldUseDirectly(request) {
            await progress?(0)
            try await DownloaderHTTPCompatibility.downloadAsync(request, to: destination)
            await progress?(1)
            return
        }
        do {
            try await DownloaderInfra.downloadOnceAsync(requestURL, to: destination, userAgent: requestUserAgent, session: networkSession, shouldUseDirectly: shouldUseDirectly, extraHeaders: ["Referer": "https://www.xiaohongshu.com/"], progress: progress)
        } catch {
            guard DownloaderHTTPCompatibility.shouldFallback(after: error, for: request) else { throw error }
            await progress?(0)
            try await DownloaderHTTPCompatibility.downloadAsync(request, to: destination)
            await progress?(1)
        }
    }

    private static func secureXHSURL(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              host.contains("xiaohongshu.com")
                || host.contains("xhscdn.com") else {
            return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }

    private static func stripImageDescription(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let type = CGImageSourceGetType(source) ?? UTType.heic.identifier as CFString
        let count = CGImageSourceGetCount(source)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, type, count, nil) else { return }
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = JSONValueUtilities.mutableDictionary(CGImageSourceCopyPropertiesAtIndex(source, index, nil))
            let tiff = JSONValueUtilities.mutableDictionary(properties[kCGImagePropertyTIFFDictionary])
            tiff.removeObject(forKey: kCGImagePropertyTIFFImageDescription)
            tiff.removeObject(forKey: "ImageDescription")
            properties[kCGImagePropertyTIFFDictionary] = tiff
            let iptc = JSONValueUtilities.mutableDictionary(properties[kCGImagePropertyIPTCDictionary])
            iptc.removeObject(forKey: kCGImagePropertyIPTCCaptionAbstract)
            iptc.removeObject(forKey: "Caption/Abstract")
            properties[kCGImagePropertyIPTCDictionary] = iptc
            let exif = JSONValueUtilities.mutableDictionary(properties[kCGImagePropertyExifDictionary])
            exif.removeObject(forKey: kCGImagePropertyExifUserComment)
            properties[kCGImagePropertyExifDictionary] = exif
            CGImageDestinationAddImage(destination, image, properties)
        }
        guard CGImageDestinationFinalize(destination) else { return }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    }

    private static func extractImageToken(_ value: String) -> String {
        let decoded = MediaFileUtilities.formatURL(value)
        guard let url = URL(string: decoded) else { return "" }
        var parts = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init)
        if parts.count >= 3, parts.first?.range(of: #"^\d{12}$"#, options: .regularExpression) != nil {
            parts = Array(parts.dropFirst(2))
        }
        return parts.joined(separator: "/").components(separatedBy: "!").first ?? ""
    }

    private static func deepGet(_ data: Any, keys: [String]) -> Any? {
        var current: Any = data
        for key in keys {
            if key.hasPrefix("["), key.hasSuffix("]"), let index = Int(key.dropFirst().dropLast()) {
                if let array = current as? [Any] {
                    let resolvedIndex = index < 0 ? array.count + index : index
                    guard array.indices.contains(resolvedIndex) else { return nil }
                    current = array[resolvedIndex]
                } else if let dictionary = current as? [String: Any] {
                    let values = Array(dictionary.values)
                    let resolvedIndex = index < 0 ? values.count + index : index
                    guard values.indices.contains(resolvedIndex) else { return nil }
                    current = values[resolvedIndex]
                } else {
                    return nil
                }
            } else if let dictionary = current as? [String: Any], let value = dictionary[key] {
                current = value
            } else {
                return nil
            }
        }
        return current
    }

    private static func originalFileIDBasename(_ fileID: String, defaultName: String) -> String {
        let name = (fileID as NSString).lastPathComponent.components(separatedBy: "!").first ?? ""
        return URL(fileURLWithPath: cleanFileName(name.isEmpty ? defaultName : name)).deletingPathExtension().lastPathComponent
    }

    private static func originalURLFilename(_ url: URL, defaultName: String) -> String {
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return cleanFileName(name.isEmpty ? defaultName : name)
    }

    private static func cleanAccountName(_ value: String) -> String {
        let pattern = #"[^一-龥a-zA-Z0-9-_！？，。；：“”（）《》]"#
        let cleaned = value.replacingOccurrences(of: pattern, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String((cleaned.isEmpty ? "unknown" : cleaned).prefix(120))
    }

    private static func cleanFileName(_ value: String) -> String {
        let pattern = #"[^一-龥a-zA-Z0-9-_.！？，。；：“”（）《》]"#
        let cleaned = value.replacingOccurrences(of: pattern, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_."))
        return String((cleaned.isEmpty ? "xhs_file" : cleaned).prefix(180))
    }

}
