import AppKit
import AVFoundation
import Foundation

/// Reads only the client's bounded diagnostic detail snapshots. Never uses browsing
/// order, timestamps, or similar video filenames to associate pictures and motion.
enum XHSAppCache {
    static let detailSubpath = "Library/Caches/com.xingyin.ragnarok"
    private static let maximumBytes = 8 * 1024 * 1024

    static func isNoteID(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-fA-F]{24}$"#, options: .regularExpression) != nil
    }

    static func noteID(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let marker = parts.firstIndex(where: { $0 == "item" || $0 == "explore" }),
              parts.indices.contains(marker + 1), isNoteID(parts[marker + 1]) else { return nil }
        return parts[marker + 1]
    }

    static func cacheRoots() -> [URL] {
        let containers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers")
        let named = containers.appendingPathComponent("com.xingin.discover/Data/\(detailSubpath)")
        if FileManager.default.isReadableFile(atPath: named.path) { return [named] }
        // macOS can give iOS app containers UUID names. Match the app-specific path.
        let entries = (try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil)) ?? []
        return entries.map { $0.appendingPathComponent("Data/\(detailSubpath)") }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    static func notes(in data: Data, noteID: String) -> [[String: Any]] {
        guard isNoteID(noteID), data.count <= maximumBytes,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = envelope["note_detail_response"] as? String,
              let body = response.data(using: .utf8), body.count <= maximumBytes,
              let groups = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else { return [] }
        return groups.flatMap { $0["note_list"] as? [[String: Any]] ?? [] }
            .filter { $0["id"] as? String == noteID }
    }

    static func notes(noteID: String, roots: [URL]) -> [[String: Any]] {
        var files: [URL] = []
        for root in roots {
            let sessions = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            files += sessions.map { $0.appendingPathComponent("extra/extraFile") }
        }
        files.sort { FileSystemUtilities.modificationDate($0) > FileSystemUtilities.modificationDate($1) }
        return files.prefix(64).flatMap { file -> [[String: Any]] in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumBytes,
                  let data = try? Data(contentsOf: file) else { return [] }
            return notes(in: data, noteID: noteID)
        }
    }

    @MainActor static func openNote(_ noteID: String, shareURL: URL) async -> Bool {
        guard !Task.isCancelled, isNoteID(noteID),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.xingin.discover") else { return false }
        var components = URLComponents()
        components.scheme = "xhsdiscover"
        components.host = "item"
        components.path = "/\(noteID)"
        components.queryItems = URLComponents(url: shareURL, resolvingAgainstBaseURL: false)?.queryItems?.filter {
            ["xsec_token", "xsec_source"].contains($0.name)
        }
        guard let url = components.url else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
            return true
        } catch { return false }
    }
}

enum XHSNativeDownloader {
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static let maxConcurrentDownloads = DownloaderHTTPCompatibility.downloadConcurrencyLimit()
    private static let networkSession: URLSession = DownloaderHTTPCompatibility.makeDownloadSession()

    struct NoteInfo: Sendable {
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
        var originalVideoURL: URL?
        var videoFromAppCache = false
        var requestUserAgent = mobileUserAgent
        var usedAppCache = false

        var hasMedia: Bool {
            !items.isEmpty || videoURL != nil
        }
    }

    struct MediaItem: Sendable {
        var index: Int
        var imageURL: URL
        var imageURLs: [URL] = []
        var appOriginalURLs: [URL] = []
        var liveURL: URL?
        var liveURLs: [URL]
        var fileID: String
        var imageQuality: Int = 0
        var liveScore: Int64 = 0
        var imageUserAgent: String?
        var liveUserAgent: String?
        var livePhotoDeclared = false
        var liveFromAppCache = false
        var livePhotoFileID: String? = nil
        var liveOriginalURLs: [URL] = []
        var liveAudioURLs: [URL] = []
        // Informational source metadata only; selection and validation use provenance and actual media.
        var liveHasAudio = false
        var audioURLs: Set<URL> = []

        mutating func discardMotionSources() {
            liveURL = nil
            liveURLs = []
            liveScore = 0
            livePhotoFileID = nil
            liveOriginalURLs = []
            liveAudioURLs = []
            liveUserAgent = nil
            liveFromAppCache = false
            liveHasAudio = false
            audioURLs = []
        }
    }

    struct DownloadTask {
        var urls: [URL]
        var destination: URL
        var requestUserAgent: String
        var videoHDRHint: VideoHDRHint?
        var isLivePhoto = false
        var isImage = false
        var originalLivePhotoURLs: Set<URL> = []
        var livePhotoAudioURLs: [URL] = []
        var displayOrder: MediaDisplayOrder? = nil
        var usesClientVideoSource = false
        var originalVideoURL: URL? = nil
    }

    struct DownloadResult: Sendable {
        var isLivePhoto: Bool
        var hasAudio: Bool
        var usedOriginalLivePhoto = false
        var recoveredAudio = false
        var sourceURL: URL? = nil
        var fromAppCache = false
    }

    struct VideoHDRHint: Sendable {
        var sourceMarkedHDR = false
        var streamMarkedHDR = false

        var needsPassthroughRemux: Bool {
            sourceMarkedHDR || streamMarkedHDR
        }
    }

    static func run(
        shareText: String,
        destinationRoot: URL,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async -> ToolRunResult {
        do {
            await DownloaderInfra.reportStatus(.readingLink)
            let links = try await extractLinks(from: shareText)
            guard !links.isEmpty else {
                return .failure("没有提取到小红书作品链接。")
            }
            let accountIDHint = links.count == 1 ? extractAccountIDHint(from: shareText) : nil

            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            var lines: [String] = []
            for (linkIndex, link) in links.enumerated() {
                let linkFraction = Double(linkIndex) / Double(links.count)
                let linkWidth = 1.0 / Double(links.count)
                /// 页面抓取阶段占每个链接的 20% 工作量。
                let scanRatio = 0.2

                if let progress {
                    await progress(linkFraction + 0.02 * linkWidth)
                }
                let fetchProgress: DownloaderInfra.ProgressHandler?
                if let progress {
                    fetchProgress = { fraction in
                        await progress(linkFraction + (0.02 + fraction * (scanRatio - 0.02)) * linkWidth)
                    }
                } else {
                    fetchProgress = nil
                }

                let note = try await fetchNote(link, progress: fetchProgress)

                if let progress {
                    await progress(linkFraction + scanRatio * linkWidth)
                }
                let author = FileNaming.sanitizeFileName(note.author.isEmpty ? "unknown" : note.author, fallback: "unknown")
                let rawUserID = note.userID.isEmpty ? (accountIDHint ?? "") : note.userID
                let userID = rawUserID.isEmpty ? "" : cleanAccountName(rawUserID)
                let outputFolder = try FileNaming.userOutputFolder(root: destinationRoot, author: author, userID: userID, defaultName: "xhs_note")
                let folderName = outputFolder.lastPathComponent
                try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

                let downloadedAt = Date().timeIntervalSince1970
                var usedNames = Set<String>()
                var tasks: [DownloadTask] = []
                for item in note.items {
                    let order = MediaDisplayOrder(postID: "xhs:" + note.noteID, downloadedAt: downloadedAt, index: item.index)
                    let baseName = originalFileIDBasename(item.fileID, defaultName: String(format: "%02d", item.index))
                    tasks.append(DownloadTask(
                        urls: item.imageURLs.isEmpty ? [item.imageURL] : item.imageURLs,
                        destination: FileNaming.uniqueDestination(in: outputFolder, name: "\(baseName).bin", usedNames: &usedNames),
                        requestUserAgent: item.imageUserAgent ?? note.requestUserAgent,
                        videoHDRHint: nil, isImage: true, displayOrder: order
                    ))
                    if item.liveURL != nil {
                        let destination = FileNaming.uniqueDestination(in: outputFolder, name: "\(baseName).mp4", usedNames: &usedNames)
                        if var task = livePhotoDownloadTask(item, destination: destination, userAgent: note.requestUserAgent) {
                            task.displayOrder = order
                            tasks.append(task)
                        }
                    }
                }

                if let videoURL = note.videoURL {
                    tasks.append(DownloadTask(
                        urls: note.videoURLs.isEmpty ? [videoURL] : note.videoURLs,
                        destination: FileNaming.uniqueDestination(in: outputFolder, name: originalURLFilename(videoURL, defaultName: "video.mp4"), usedNames: &usedNames),
                        requestUserAgent: note.requestUserAgent,
                        videoHDRHint: note.videoHDRHint,
                        displayOrder: MediaDisplayOrder(postID: "xhs:" + note.noteID, downloadedAt: downloadedAt, index: 1)
                    ))
                }

                guard !tasks.isEmpty else {
                    throw NSError(domain: "XHSDownloader", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有可下载的小红书媒体。"])
                }

                let downloadProgress: DownloaderInfra.ProgressHandler?
                if let progress {
                    downloadProgress = { fraction in
                        await progress(linkFraction + scanRatio * linkWidth + fraction * (1 - scanRatio) * linkWidth)
                    }
                } else {
                    downloadProgress = nil
                }
                let results: [DownloadResult]
                if note.type == "video", let task = tasks.first {
                    results = [try await downloadVideo(note, task: task, shareURL: link, progress: downloadProgress)]
                } else {
                    results = try await download(tasks, progress: downloadProgress)
                }
                let liveCount = note.items.filter { $0.liveURL != nil }.count
                let audioCount = results.filter { $0.isLivePhoto && $0.hasAudio }.count
                let originalLiveCount = results.filter { $0.usedOriginalLivePhoto }.count
                let recoveredAudioCount = results.filter { $0.recoveredAudio }.count
                let missingLiveCount = note.items.filter { $0.livePhotoDeclared && $0.liveURL == nil }.count
                let videoCount = note.videoURL == nil ? 0 : 1
                let downloadedOriginal = note.originalVideoURL.map { original in results.contains { $0.sourceURL == original } } ?? false
                lines.append([
                    "noteId: \(note.noteID)",
                    "用户: \(folderName)",
                    "分享链接: \(link.absoluteString)",
                    "下载原图: \(note.items.count) 张",
                    "下载视频: \(videoCount) 个",
                    videoCount > 0 ? (downloadedOriginal ? "视频来源：云端原始上传文件，保留源编码、分辨率与色彩信息。" : "视频来源：同笔记客户端缓存来源；本次未取得云端原始文件。") : nil,
                    "下载 Live Photo 视频: \(liveCount) 个",
                    liveCount > 0 ? "云端原始实况: \(originalLiveCount)/\(liveCount) 个" : nil,
                    liveCount > 0 ? "已核验有音轨: \(audioCount)/\(liveCount) 个" : nil,
                    recoveredAudioCount > 0 ? "已从同图客户端源无损补入音轨: \(recoveredAudioCount) 个" : nil,
                    liveCount > originalLiveCount ? "提示：\(liveCount - originalLiveCount) 段实况使用客户端最高规格备用流。" : nil,
                    note.usedAppCache || results.contains(where: \.fromAppCache) ? "已读取本机小红书客户端的同笔记素材记录。" : nil,
                    liveCount > audioCount ? "提示：\(liveCount - audioCount) 段实况文件未检测到音轨。" : nil,
                    missingLiveCount > 0 ? "提示：\(missingLiveCount) 张实况尚未取得本机客户端动态源，请在小红书中打开该笔记后重试。" : nil,
                    "输出目录: \(outputFolder.path)"
                ].compactMap { $0 }.joined(separator: "\n"))
            }
            lines.append("完成。输出只保留媒体文件，不保存鉴权链接。")
            await DownloaderInfra.reportStatus(.completed)
            return .success(lines.joined(separator: "\n\n"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func extractLinks(
        from text: String,
        resolveShortLink: @Sendable (URL) async throws -> URL = { try await resolveURL($0) }
    ) async throws -> [URL] {
        let patterns = [
            #"(?:https?://)?(?:www\.)?xiaohongshu\.com/explore/[^\s"<>\\^`{|}，。；！？、【】《》]+"#,
            #"(?:https?://)?(?:www\.)?xiaohongshu\.com/discovery/item/[^\s"<>\\^`{|}，。；！？、【】《》]+"#,
            #"(?:https?://)?(?:www\.)?xiaohongshu\.com/user/profile/[a-z0-9]+/[^\s"<>\\^`{|}，。；！？、【】《》]+"#,
            #"(?:https?://)?xhslink\.(?:com|cn)/[^\s"<>\\^`{|}，。；！？、【】《》]+"#
        ]
        var links: [URL] = []
        var seen = Set<String>()
        var seenSources = Set<URL>()
        for pattern in patterns {
            for rawValue in RegexUtilities.allMatches(pattern, in: text) {
                let cleaned = MediaFileUtilities.trimURLPunctuation(rawValue)
                guard let sourceURL = normalizedShareURL(cleaned) else { continue }
                guard seenSources.insert(sourceURL).inserted else { continue }
                let resolvedURL = DownloaderNetworkPolicy.isXHSShortLinkHost(sourceURL.host) ? (try? await resolveShortLink(sourceURL)) ?? sourceURL : sourceURL
                guard seen.insert(resolvedURL.absoluteString).inserted else { continue }
                links.append(resolvedURL)
            }
        }
        let trimmedText = MediaFileUtilities.trimURLPunctuation(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmedText.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           let directURL = normalizedShareURL(trimmedText),
           DownloaderNetworkPolicy.isXHSShortLinkHost(directURL.host) || directURL.host?.contains("xiaohongshu.com") == true {
            guard seenSources.insert(directURL).inserted else { return links }
            let resolvedURL = DownloaderNetworkPolicy.isXHSShortLinkHost(directURL.host) ? (try? await resolveShortLink(directURL)) ?? directURL : directURL
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

    private static func fetchNote(_ url: URL, progress: DownloaderInfra.ProgressHandler? = nil) async throws -> NoteInfo {
        await DownloaderInfra.reportStatus(.findingMedia)
        var notes: [NoteInfo] = []
        var desktopMessage: String?
        var firstError: Error?
        do {
            if let progress { await progress(0.1) }
            var desktopResult = try await fetchNoteOnce(url, requestUserAgent: desktopUserAgent)
            if let progress { await progress(0.5) }
            desktopMessage = desktopResult.sourceMessage
            if desktopResult.note.hasMedia || desktopResult.note.type == "video" {
                desktopResult.note.requestUserAgent = desktopUserAgent
                notes.append(desktopResult.note)
            }
        } catch {
            if let progress { await progress(0.1) }
            firstError = error
        }

        var mobileMessage: String?
        do {
            if let progress { await progress(0.6) }
            var mobileResult = try await fetchNoteOnce(url, requestUserAgent: mobileUserAgent)
            if let progress { await progress(0.95) }
            mobileMessage = mobileResult.sourceMessage
            if mobileResult.note.hasMedia || mobileResult.note.type == "video" {
                mobileResult.note.requestUserAgent = mobileUserAgent
                notes.append(mobileResult.note)
            }
        } catch {
            if let progress { await progress(0.6) }
            if firstError == nil {
                firstError = error
            }
        }

        if let progress { await progress(1) }

        let expectedID = XHSAppCache.noteID(from: url)
        if let expectedID { notes = notes.filter { $0.noteID == expectedID } }
        var bestNote = preferredNote(notes)
        let identity = expectedID ?? bestNote?.noteID
        if let identity, XHSAppCache.isNoteID(identity) {
            var roots = XHSAppCache.cacheRoots()
            func mergeCache() {
                let cached = XHSAppCache.notes(noteID: identity, roots: roots).compactMap {
                    parseAppNote($0, expectedID: identity, fallbackURL: url)
                }
                bestNote = preferredNote(notes + cached)
            }
            await DownloaderInfra.reportStatus(.readingClient)
            mergeCache()
            // Refresh missing exact-ID client originals or motion sources; audio metadata is not a source criterion.
            // A bounded wait leaves the bare original available if the app is absent.
            if shouldRefreshClientCache(for: bestNote) {
                try Task.checkCancellation()
                await DownloaderInfra.reportStatus(.waitingClient)
                try Task.checkCancellation()
                if await XHSAppCache.openNote(identity, shareURL: url) {
                    for _ in 0..<8 {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .seconds(1))
                        roots = XHSAppCache.cacheRoots()
                        mergeCache()
                        if !shouldRefreshClientCache(for: bestNote) { break }
                    }
                }
                try Task.checkCancellation()
            }
        }
        if let bestNote, bestNote.hasMedia { return bestNote }
        if bestNote?.type == "video" {
            throw NSError(domain: "XHSDownloader", code: 8, userInfo: [NSLocalizedDescriptionKey: "未取得云端原视频，客户端缓存也未找到同笔记的可用视频来源。请在小红书客户端打开该笔记后重试。"])
        }
        if let firstError {
            throw firstError
        }
        let sourceMessage = desktopMessage ?? mobileMessage
        let detail = sourceMessage.map { "源站返回：\($0)" } ?? "源站未返回 imageList/video。"
        throw NSError(domain: "XHSDownloader", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有可下载的小红书媒体。\(detail)"])
    }

    private static func fetchNoteOnce(_ url: URL, requestUserAgent: String) async throws -> (note: NoteInfo, sourceMessage: String?) {
        let (data, _) = try await requestAsync(url, readsBody: true, requestUserAgent: requestUserAgent)
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

    static func parseNote(_ note: [String: Any], fallbackURL: URL) throws -> NoteInfo {
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
                let hasAudio = liveCandidate.map { streamHasAudio($0.item) } ?? false
                info.items.append(MediaItem(
                    index: offset + 1,
                    imageURL: imageCandidate.url,
                    imageURLs: imageSourceURLs(from: item, preferred: imageCandidate),
                    liveURL: liveURLs.first,
                    liveURLs: liveURLs,
                    fileID: JSONValueUtilities.nonEmptyString(item["fileId"]) ?? imageCandidate.token,
                    imageQuality: imageScore(imageCandidate),
                    liveScore: liveCandidate.map(streamScore) ?? 0,
                    livePhotoDeclared: JSONValueUtilities.boolValue(item["livePhoto"]) || !nestedStreamCandidates(in: item).isEmpty,
                    liveHasAudio: hasAudio,
                    audioURLs: hasAudio ? Set(liveURLs) : []
                ))
            }
        }

        if info.type == "video" {
            // Ordinary videos download the exact upload key, never a web playback
            // rendition or an unbound local player cache. Live Photos keep their
            // separate client-cache path above.
            guard let rawKey = deepGet(note, keys: ["video", "consumer", "originVideoKey"]) as? String,
                  let key = JSONValueUtilities.nonEmptyString(rawKey),
                  key.range(of: #"^[A-Za-z0-9_/-]+$"#, options: .regularExpression) != nil,
                  !key.hasPrefix("/"),
                  let original = URL(string: "https://sns-video-bd.xhscdn.com/\(key)") else {
                return info
            }
            info.originalVideoURL = original
            info.videoURL = original
            info.videoURLs = [original]
            // Preserve the upload bytes. Playback-stream HDR hints must not cause
            // the original file to be remuxed or its color metadata to be inferred.
            info.videoHDRHint = nil
        }
        return info
    }

    static func parseAppNote(_ note: [String: Any], expectedID: String, fallbackURL: URL) -> NoteInfo? {
        guard XHSAppCache.isNoteID(expectedID), JSONValueUtilities.string(note["id"]) == expectedID else { return nil }
        if note["type"] as? String == "video" {
            var normalized = note
            normalized["noteId"] = expectedID
            guard var parsed = try? parseNote(normalized, fallbackURL: fallbackURL),
                  let candidate = bestVideoCandidate(from: note), let url = streamURLs(candidate.item).first else { return nil }
            parsed.videoURL = url
            parsed.videoURLs = streamURLs(candidate.item)
            parsed.videoScore = regularVideoScore(candidate)
            parsed.videoHDRHint = nil
            parsed.videoFromAppCache = true
            parsed.usedAppCache = true
            return parsed
        }
        guard note["type"] as? String == "normal",
              let images = note["images_list"] as? [[String: Any]], !images.isEmpty else { return nil }
        let ids = images.compactMap { JSONValueUtilities.nonEmptyString($0["fileid"]) }
        guard ids.count == images.count, Set(ids).count == ids.count else { return nil }
        // A motion key belongs to exactly one still in this response. Never bind
        // a duplicated key to two different images, even if their array indices agree.
        let liveKeys = images.compactMap { originalLivePhotoFileID($0["live_photo_file_id"]) }
        let keyCounts = Dictionary(liveKeys.map { ($0, 1) }, uniquingKeysWith: +)
        var normalized = note
        normalized["noteId"] = expectedID
        normalized["imageList"] = images.map { image -> [String: Any] in
            var result: [String: Any] = ["fileId": image["fileid"]!, "livePhoto": image["live_photo"] is [String: Any]]
            // Reconstruct the bare cover by identity. Display URLs are never originals.
            result["url"] = "https://sns-img-bd.xhscdn.com/\(image["fileid"]!)"
            result["stream"] = deepGet(image, keys: ["live_photo", "media", "stream"])
            return result
        }
        guard var parsed = try? parseNote(normalized, fallbackURL: fallbackURL), parsed.hasMedia else { return nil }
        parsed.usedAppCache = true
        // Keep the identity-derived cover and motion metadata even without an original.
        // Only this exact image's original field supplies a client fallback.
        for i in parsed.items.indices {
            parsed.items[i].imageQuality = -1
            guard let image = images.first(where: { $0["fileid"] as? String == parsed.items[i].fileID }) else { continue }
            if let key = originalLivePhotoFileID(image["live_photo_file_id"]), keyCounts[key] == 1 {
                let originals = originalLivePhotoURLs(for: key)
                parsed.items[i].livePhotoFileID = key
                parsed.items[i].liveOriginalURLs = originals
                parsed.items[i].liveURLs = orderedUniqueURLs(originals + parsed.items[i].liveURLs)
                parsed.items[i].liveURL = parsed.items[i].liveURLs.first
                parsed.items[i].livePhotoDeclared = true
                // Stream audio metadata describes the playback rendition, not
                // the original object. Probe the chosen file after downloading.
                parsed.items[i].liveHasAudio = false
            }
            parsed.items[i].liveFromAppCache = parsed.items[i].liveURL != nil
            parsed.items[i].liveAudioURLs = livePhotoAudioSourceURLs(from: image)
            parsed.items[i].appOriginalURLs = appOriginalURL(from: image, fileID: parsed.items[i].fileID).map { [$0] } ?? []
            parsed.items[i].imageURLs = orderedUniqueURLs([parsed.items[i].imageURL]
                + parsed.items[i].appOriginalURLs)
        }
        return parsed
    }

    private static func originalLivePhotoFileID(_ value: Any?) -> String? {
        // Client details use both namespaces for the exact still's cloud motion.
        // Keep the object key strict: no arbitrary paths, transforms or signed URLs.
        guard let key = JSONValueUtilities.nonEmptyString(value),
              key.range(of: #"^livephoto(?:_pre_post)?/[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        return key
    }

    private static func originalLivePhotoURLs(for key: String) -> [URL] {
        // These endpoints have been verified against the same exact cloud object.
        // Use GET: the primary CDN can return 404 to HEAD for an available MOV.
        ["sns-video-bd.xhscdn.com", "sns-bak-v6.xhscdn.com"].compactMap {
            URL(string: "https://\($0)/\(key)")
        }
    }

    static func shouldRefreshClientCache(for note: NoteInfo?) -> Bool {
        guard let note else { return true }
        guard note.type != "video" else { return note.originalVideoURL == nil && !note.videoFromAppCache }
        return note.items.isEmpty || note.items.contains {
            $0.appOriginalURLs.isEmpty || ($0.livePhotoDeclared && !$0.liveFromAppCache)
        }
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
        var streamHDRScore: Int? = nil
        var streamFPSScore: Int? = nil
    }

    private struct ImageCandidate {
        var sourceText: String
        var token: String
        var url: URL
        var keyHint: String
    }

    private static func bestVideoCandidate(from note: [String: Any]) -> StreamCandidate? {
        var candidates: [StreamCandidate] = []
        // Legacy ordinary-video client details contain explicit playable variants.
        if let video = note["video"] as? [String: Any] {
            let variants = video["url_info_list"] as? [[String: Any]] ?? []
            for variant in variants.isEmpty ? [video] : variants {
                guard let url = JSONValueUtilities.nonEmptyString(variant["url"]) else { continue }
                var item = variant
                item["master_url"] = url
                item["format"] = variant["desc"] ?? variant["format"]
                let hdr = videoHDRHint(urlText: url, meta: item)
                let desc = (JSONValueUtilities.string(variant["desc"]) ?? "").lowercased()
                candidates.append(StreamCandidate(codec: desc.contains("265") ? "h265" : "h264", item: item,
                    streamHDRScore: hdr, streamFPSScore: regularVideoFPSHint(item)))
            }
        }
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

        return candidates.filter { candidate in
            let urls = streamURLs(candidate.item)
            return !urls.isEmpty && urls.allSatisfy { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        }.max(by: { regularVideoScore($0) < regularVideoScore($1) })
    }

    private static func bestLivePhotoCandidate(from item: [String: Any]) -> StreamCandidate? {
        livePhotoCandidates(from: item).max { streamScore($0) < streamScore($1) }
    }

    private static func livePhotoCandidates(from item: [String: Any]) -> [StreamCandidate] {
        // WEB_LIVEPHOTO_19 is a separately encoded, potentially watermarked rendition.
        // A watermark query parameter cannot remove a logo already encoded in its frames.
        let candidates = nestedStreamCandidates(in: item).compactMap { candidate -> StreamCandidate? in
            let streamType = JSONValueUtilities.intValue(value(in: candidate.item, keys: ["streamType", "stream_type"]))
            let description = JSONValueUtilities.string(value(in: candidate.item, keys: ["streamDesc", "stream_desc"])) ?? ""
            guard streamType != 19, !description.uppercased().contains("WEB_LIVEPHOTO") else { return nil }
            let urls = streamURLs(candidate.item).filter { !isWatermarkedLivePhotoURL($0) }
            guard let first = urls.first else { return nil }
            var clean = candidate
            for key in ["masterUrl", "master_url", "backupUrls", "backup_urls"] { clean.item.removeValue(forKey: key) }
            clean.item["masterUrl"] = first.absoluteString
            clean.item["backupUrls"] = urls.dropFirst().map(\.absoluteString)
            return clean
        }
        return candidates
    }

    private static func livePhotoAudioSourceURLs(from item: [String: Any]) -> [URL] {
        let candidates = livePhotoCandidates(from: item).sorted { lhs, rhs in
            // Metadata orders candidates only. Actual downloaded tracks decide
            // whether any audio can be used; absent flags never discard a source.
            let leftAudio = streamHasAudio(lhs.item), rightAudio = streamHasAudio(rhs.item)
            if leftAudio != rightAudio { return leftAudio }
            let leftBitrate = JSONValueUtilities.intValue(value(in: lhs.item, keys: ["audioBitrate", "audio_bitrate"]))
            let rightBitrate = JSONValueUtilities.intValue(value(in: rhs.item, keys: ["audioBitrate", "audio_bitrate"]))
            if leftBitrate != rightBitrate { return leftBitrate > rightBitrate }
            return streamScore(lhs) > streamScore(rhs)
        }
        return orderedUniqueURLs(candidates.flatMap { streamURLs($0.item) })
    }

    private static func isWatermarkedLivePhotoURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/10/19/") || path.contains("/watermark/") || path.contains("/wm/")
            || URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name.lowercased() == "watermark" && $0.value == "1"
            } == true
    }

    private static func streamHasAudio(_ item: [String: Any]) -> Bool {
        ["audioChannels", "audio_channels", "audioBitrate", "audio_bitrate", "audioDuration", "audio_duration"].contains {
            JSONValueUtilities.intValue(item[$0]) > 0
        }
    }

    private static func bestImageURL(from item: [String: Any]) -> ImageCandidate? {
        let candidates = nestedImageCandidates(in: item).filter { isUnprocessedImageURL($0.url) }
        return candidates.max { lhs, rhs in
            imageScore(lhs) < imageScore(rhs)
        }
    }

    static func noteIsLessComplete(_ lhs: NoteInfo, _ rhs: NoteInfo) -> Bool {
        if lhs.type != "video", rhs.type != "video" {
            if lhs.items.count != rhs.items.count { return lhs.items.count < rhs.items.count }
            let left = lhs.items.filter { $0.liveURL != nil }.count
            let right = rhs.items.filter { $0.liveURL != nil }.count
            if left != right { return left < right }
        }
        let left = noteScore(lhs), right = noteScore(rhs)
        if left != right { return left < right }
        return lhs.requestUserAgent != mobileUserAgent && rhs.requestUserAgent == mobileUserAgent
    }

    static func preferredNote(_ notes: [NoteInfo]) -> NoteInfo? {
        // Do not compare or combine different works returned by inconsistent pages.
        guard let identity = notes.first?.noteID else { return nil }
        var matching = notes.filter { $0.noteID == identity }.map { note in
            var localOnly = note
            for i in localOnly.items.indices where !localOnly.items[i].liveFromAppCache {
                localOnly.items[i].livePhotoDeclared = localOnly.items[i].livePhotoDeclared || localOnly.items[i].liveURL != nil
                localOnly.items[i].discardMotionSources()
            }
            return localOnly
        }
        var keyImageIDs: [String: Set<String>] = [:]
        for note in matching {
            for item in note.items {
                if let key = item.livePhotoFileID { keyImageIDs[key, default: []].insert(item.fileID) }
            }
        }
        for noteIndex in matching.indices {
            for itemIndex in matching[noteIndex].items.indices {
                guard let key = matching[noteIndex].items[itemIndex].livePhotoFileID,
                      keyImageIDs[key, default: []].count > 1 else { continue }
                var item = matching[noteIndex].items[itemIndex]
                let originals = Set(item.liveOriginalURLs)
                item.liveURLs.removeAll { originals.contains($0) }
                item.liveURL = item.liveURLs.first
                item.liveOriginalURLs = []
                item.livePhotoFileID = nil
                item.liveFromAppCache = item.liveURL != nil
                matching[noteIndex].items[itemIndex] = item
            }
        }
        var latestMotionKeys: [String: String] = [:]
        for note in matching {
            for item in note.items {
                if let key = item.livePhotoFileID, latestMotionKeys[item.fileID] == nil {
                    latestMotionKeys[item.fileID] = key
                }
            }
        }
        // A changed upload key is a different motion revision. Reject all its
        // playback and audio sources before selecting a base snapshot, so an
        // older high-score record cannot supply sound to the newer original.
        for noteIndex in matching.indices {
            for itemIndex in matching[noteIndex].items.indices {
                let item = matching[noteIndex].items[itemIndex]
                if let key = item.livePhotoFileID, latestMotionKeys[item.fileID] != key {
                    matching[noteIndex].items[itemIndex].discardMotionSources()
                }
            }
        }
        // A client response supplements the web image order, even when its codec
        // has a higher score or its image array arrives in a different order.
        let webNotes = matching.filter { !$0.usedAppCache }
        guard var result = (webNotes.isEmpty ? matching : webNotes).max(by: noteIsLessComplete) else { return nil }
        if result.type == "video" {
            let cached = matching.filter { $0.type == "video" && $0.videoFromAppCache }.max { $0.videoScore < $1.videoScore }
            let original = matching.compactMap(\.originalVideoURL).first
            result.originalVideoURL = original
            result.videoURL = original ?? cached?.videoURL
            result.videoURLs = orderedUniqueURLs((original.map { [$0] } ?? []) + (cached?.videoURLs ?? []))
            result.videoFromAppCache = cached != nil
            result.usedAppCache = cached != nil
            result.videoHDRHint = nil
            if let cached { result.videoScore = cached.videoScore; result.requestUserAgent = cached.requestUserAgent }
            return result
        }
        guard !identity.isEmpty else { return result }
        // Cache records arrive newest first; collect their originals in that order.
        for i in result.items.indices {
            result.items[i].appOriginalURLs = []
            result.items[i].livePhotoFileID = nil
            result.items[i].liveOriginalURLs = []
        }
        var originalURLsByFileID: [String: Set<URL>] = [:]
        for note in matching {
            for item in note.items {
                originalURLsByFileID[item.fileID, default: []].formUnion(item.liveOriginalURLs)
            }
        }
        for note in matching where note.type == result.type {
            for item in note.items where !item.fileID.isEmpty {
                guard note.items.filter({ $0.fileID == item.fileID }).count == 1 else { continue }
                let indices = result.items.indices.filter { result.items[$0].fileID == item.fileID }
                if indices.count == 1, let i = indices.first {
                    let existingImageURLs = result.items[i].imageURLs.isEmpty
                        ? [result.items[i].imageURL] : result.items[i].imageURLs
                    let additionalImageURLs = note.usedAppCache ? []
                        : (item.imageURLs.isEmpty ? [item.imageURL] : item.imageURLs)
                    if item.imageQuality > result.items[i].imageQuality {
                        result.items[i].imageURL = item.imageURL
                        result.items[i].imageQuality = item.imageQuality
                        result.items[i].imageUserAgent = item.imageUserAgent ?? note.requestUserAgent
                    }
                    result.items[i].appOriginalURLs = orderedUniqueURLs(result.items[i].appOriginalURLs
                        + item.appOriginalURLs)
                    // Keep the bare original first and newer exact-ID client originals
                    // ahead of older snapshots. Web display variants never participate.
                    result.items[i].imageURLs = orderedUniqueURLs([result.items[i].imageURL]
                        + result.items[i].appOriginalURLs
                        + (existingImageURLs + additionalImageURLs).filter(isUnprocessedImageURL))
                    if note.usedAppCache, result.items[i].imageURLs != existingImageURLs {
                        result.usedAppCache = true
                    }
                    if item.liveURL != nil,
                       result.items[i].liveURL == nil || item.liveScore > result.items[i].liveScore {
                        let fallbackURLs = result.items[i].liveURLs
                        result.items[i].liveURL = item.liveURL
                        result.items[i].liveURLs = item.liveURLs + fallbackURLs.filter { !item.liveURLs.contains($0) }
                        result.items[i].liveScore = item.liveScore
                        result.items[i].liveUserAgent = item.liveUserAgent ?? note.requestUserAgent
                        result.items[i].liveFromAppCache = true
                        result.items[i].liveHasAudio = item.liveHasAudio
                        result.items[i].audioURLs.formUnion(item.audioURLs)
                        result.usedAppCache = result.usedAppCache || note.usedAppCache
                    } else if item.liveURL != nil {
                        result.items[i].liveURLs.append(contentsOf: item.liveURLs.filter { !result.items[i].liveURLs.contains($0) })
                        result.items[i].audioURLs.formUnion(item.audioURLs)
                    }
                    // Original provenance outranks any playback score, audio
                    // flag, codec or advertised dimensions. Snapshots arrive
                    // newest first; retain that exact key if older ones disagree.
                    if item.liveFromAppCache, let key = item.livePhotoFileID,
                       result.items[i].livePhotoFileID == nil || result.items[i].livePhotoFileID == key {
                        result.items[i].livePhotoFileID = key
                        result.items[i].liveOriginalURLs = orderedUniqueURLs(result.items[i].liveOriginalURLs + item.liveOriginalURLs)
                    }
                    if !result.items[i].liveOriginalURLs.isEmpty {
                        let allOriginals = originalURLsByFileID[item.fileID] ?? []
                        result.items[i].liveURLs = orderedUniqueURLs(result.items[i].liveOriginalURLs
                            + result.items[i].liveURLs.filter { !allOriginals.contains($0) })
                        result.items[i].liveURL = result.items[i].liveURLs.first
                        result.items[i].liveFromAppCache = true
                        result.items[i].liveHasAudio = false
                    }
                    if item.liveFromAppCache {
                        result.items[i].liveAudioURLs = orderedUniqueURLs(result.items[i].liveAudioURLs + item.liveAudioURLs)
                    }
                    result.items[i].livePhotoDeclared = result.items[i].livePhotoDeclared || item.livePhotoDeclared
                } else if indices.isEmpty, !result.items.contains(where: { $0.index == item.index }) {
                    var extra = item
                    extra.imageUserAgent = item.imageUserAgent ?? note.requestUserAgent
                    extra.liveUserAgent = item.liveUserAgent ?? note.requestUserAgent
                    result.items.append(extra)
                }
            }
        }
        result.items.sort { $0.index < $1.index }
        return result
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
        return note.items.reduce(Int64(0)) { $0 + $1.liveScore }
    }

    private static func streamCandidates(from stream: [String: Any], inheritedMeta: [String: Any] = [:]) -> [StreamCandidate] {
        var candidates: [StreamCandidate] = []
        for key in ["h264", "h265", "h266", "av1"] {
            if let values = stream[key] as? [[String: Any]] {
                candidates.append(contentsOf: values.map {
                    var item = $0
                    inheritVideoHDRMetadata(from: inheritedMeta, into: &item)
                    return StreamCandidate(codec: key, item: item,
                        streamHDRScore: videoHDRHint(urlText: streamURL($0)?.absoluteString ?? "", meta: $0),
                        streamFPSScore: regularVideoFPSHint($0))
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
        return dictionary.flatMap { key, nestedValue -> [ImageCandidate] in
            guard !["stream", "video", "live_photo", "livephoto"].contains(key.lowercased()) else { return [] }
            return nestedImageCandidates(in: nestedValue, keyHint: key, depth: depth + 1)
        }
    }

    private static func orderedUniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    private static func imageSourceURLs(from item: [String: Any], preferred: ImageCandidate) -> [URL] {
        let candidates = nestedImageCandidates(in: item).sorted { lhs, rhs in
            let left = imageScore(lhs), right = imageScore(rhs)
            return left == right ? lhs.sourceText < rhs.sourceText : left > right
        }
        // Only the reconstructed, unprocessed paths from web metadata are usable.
        // Its signed H5/style/display URLs may have a platform watermark baked in.
        return orderedUniqueURLs(([preferred.url] + candidates.map(\.url)).filter(isUnprocessedImageURL))
    }

    private static func isDisplayImageURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if ["!h5", "!style", "!web-display", "!display", "!preview", "/display/", "/preview/"].contains(where: path.contains) {
            return true
        }
        return (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains { item in
            let key = item.name.lowercased()
            if key == "sc" { return item.value?.uppercased() != "ORIGINAL" }
            return ["preview", "display", "thumbnail", "style", "h5"].contains(where: key.contains)
        }
    }

    private static func isUnprocessedImageURL(_ url: URL) -> Bool {
        guard !isDisplayImageURL(url), !url.path.contains("!") else { return false }
        return !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains { item in
            let key = item.name.lowercased()
            return ["imageview", "imagemogr", "resize"].contains(where: key.contains)
        }
    }

    private static func appOriginalURL(from image: [String: Any], fileID: String) -> URL? {
        guard let source = JSONValueUtilities.nonEmptyString(image["original"]),
              let url = URL(string: MediaFileUtilities.formatURL(source)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), host == "xhscdn.com" || host.hasSuffix(".xhscdn.com"),
              extractImageToken(source) == fileID, !url.path.contains("!"), !isDisplayImageURL(url) else { return nil }
        // The client's ORIGINAL field may include its own 5000-pixel WebP transform.
        // Preserve its signed URL verbatim; never borrow a DETAIL/PREVIEW field.
        return url
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

    private static func regularVideoScore(_ candidate: StreamCandidate) -> Int64 {
        let item = candidate.item
        let width = min(max(JSONValueUtilities.intValue(item["width"]), 0), 16_384)
        let height = min(max(JSONValueUtilities.intValue(item["height"]), 0), 16_384)
        let bitrate = min(max(JSONValueUtilities.intValue(value(in: item, keys: ["videoBitrate", "video_bitrate", "avgBitrate", "avg_bitrate"])), 0), 1_000_000_000)
        let hdr = min(max(candidate.streamHDRScore ?? 0, 0), 4)
        let fps = min(max(candidate.streamFPSScore ?? 0, 0), 240)
        // Rank stream-level HDR, resolution, frame rate, then bitrate. Bounds
        // keep every tier separate and the total safely within Int64.
        return Int64(hdr) * 1_000_000_000_000_000_000
            + Int64(width) * Int64(height) * 1_000_000_000
            + Int64(fps) * 1_000_001 + Int64(bitrate / 1_000)
    }

    private static func regularVideoFPSHint(_ item: [String: Any]) -> Int {
        var values: [Int] = []
        for key in ["fps", "frameRate", "frame_rate"] {
            if let value = Double(JSONValueUtilities.string(item[key]) ?? ""),
               value.isFinite, value >= 1, value <= 240 {
                values.append(Int(value.rounded()))
            }
        }
        if let fps = values.max() { return fps }
        let text = ["desc", "format", "streamDesc", "stream_desc", "fpsType"].compactMap {
            JSONValueUtilities.nonEmptyString(item[$0])
        }.joined(separator: " ").lowercased()
        values = RegexUtilities.allMatches(#"\d{2,3}\s*fps"#, in: text).compactMap {
            guard let fps = Int($0.filter(\.isNumber)), fps <= 240 else { return nil }
            return fps
        }
        return values.max() ?? 0
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

    private static func requestAsync(_ url: URL, readsBody: Bool, requestUserAgent: String = mobileUserAgent) async throws -> (Data, URL?) {
        let requestURL = secureXHSURL(url)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.assumesHTTP3Capable = false
        request.setValue(requestUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://www.xiaohongshu.com/explore", forHTTPHeaderField: "Referer")

        if DownloaderNetworkPolicy.isXHSShortLinkHost(requestURL.host) {
            return try await DownloaderHTTPCompatibility.dataAsync(for: request, readsBody: readsBody)
        }
        return try await DownloaderHTTPCompatibility.requestData(
            for: request, session: networkSession, readsBody: readsBody
        )
    }

    static func livePhotoDownloadTask(_ item: MediaItem, destination: URL, userAgent: String = mobileUserAgent) -> DownloadTask? {
        guard item.liveFromAppCache, let liveURL = item.liveURL else { return nil }
        let urls = item.liveURLs.isEmpty ? [liveURL] : item.liveURLs
        // All primary and backup URLs belong to this exact client motion source.
        return DownloadTask(urls: urls,
                            destination: destination, requestUserAgent: item.liveUserAgent ?? userAgent,
                            videoHDRHint: nil, isLivePhoto: true,
                            originalLivePhotoURLs: Set(item.liveOriginalURLs),
                            livePhotoAudioURLs: item.liveAudioURLs)
    }

    static func download(
        _ tasks: [DownloadTask],
        maxConcurrentDownloads requestedMaxConcurrentDownloads: Int? = nil,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async throws -> [DownloadResult] {
        guard !tasks.isEmpty else { return [] }
        let limit = max(1, requestedMaxConcurrentDownloads ?? maxConcurrentDownloads)
        let progressAggregator = DownloaderInfra.DownloadProgressAggregator(totalCount: tasks.count, handler: progress)
        let reportsStatus = DownloaderInfra.statusHandler != nil
        var imageNumber = 0
        let labels = tasks.map { task -> String in
            if task.isImage {
                imageNumber += 1
                return "图片 \(task.displayOrder?.index ?? imageNumber)"
            }
            if task.isLivePhoto { return "实况 \(task.displayOrder?.index ?? 1)" }
            return "视频"
        }
        return try await withThrowingTaskGroup(of: DownloadResult.self) { group in
            var results: [DownloadResult] = []
            var iter = Array(tasks.enumerated()).makeIterator()
            for _ in 0..<min(limit, tasks.count) {
                guard let t = iter.next() else { break }
                group.addTask {
                    let scopedStatus: DownloaderInfra.StatusHandler?
                    if reportsStatus {
                        scopedStatus = { status in
                            await progressAggregator.updateStatus(index: t.offset, status: status.forItem(labels[t.offset]))
                        }
                    } else { scopedStatus = nil }
                    let result = try await DownloaderInfra.$statusHandler.withValue(scopedStatus) {
                        try await download(t.element) { fraction in
                            await progressAggregator.update(index: t.offset, fraction: fraction)
                        }
                    }
                    await progressAggregator.complete(index: t.offset)
                    return result
                }
            }
            for try await result in group {
                results.append(result)
                guard let t = iter.next() else { continue }
                group.addTask {
                    let scopedStatus: DownloaderInfra.StatusHandler?
                    if reportsStatus {
                        scopedStatus = { status in
                            await progressAggregator.updateStatus(index: t.offset, status: status.forItem(labels[t.offset]))
                        }
                    } else { scopedStatus = nil }
                    let result = try await DownloaderInfra.$statusHandler.withValue(scopedStatus) {
                        try await download(t.element) { fraction in
                            await progressAggregator.update(index: t.offset, fraction: fraction)
                        }
                    }
                    await progressAggregator.complete(index: t.offset)
                    return result
                }
            }
            return results
        }
    }

    static func download(
        _ task: DownloadTask,
        retries: Int = 3,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async throws -> DownloadResult {
        try Task.checkCancellation()
        let transferPolicy = task.isImage
            ? DownloaderHTTPCompatibility.TransferPolicy(maximumDuration: 90, idleTimeout: 12) : nil
        let temporaryURL = task.destination.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        var lastError: Error?
        for attempt in 0...retries {
            do {
                try FileManager.default.createDirectory(at: task.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                for (sourceIndex, sourceURL) in task.urls.enumerated() {
                    do {
                        if sourceIndex > 0 { await DownloaderInfra.reportStatus(.tryingAlternative) }
                        let stage: DownloaderInfra.DownloadStage = task.isImage ? .downloadingImage
                            : task.isLivePhoto ? .downloadingLivePhoto : .downloadingVideo
                        try await downloadOnceAsync(sourceURL, to: temporaryURL, requestUserAgent: task.requestUserAgent,
                                                    progress: progress, transferPolicy: transferPolicy, stage: stage)
                        await DownloaderInfra.reportStatus(.checkingFile)
                        try await MediaFileUtilities.validateMedia(temporaryURL,
                            expectedSuffix: task.isImage ? "jpg" : task.destination.pathExtension)
                        let isOriginal = task.isLivePhoto && task.originalLivePhotoURLs.contains(sourceURL)
                        var hasAudio = task.isLivePhoto ? try await livePhotoHasAudio(at: temporaryURL) : false
                        var recoveredAudio = false
                        if task.isLivePhoto, !hasAudio {
                            recoveredAudio = try await recoverLivePhotoAudio(task, at: temporaryURL, excluding: sourceURL)
                            hasAudio = recoveredAudio
                        }
                        try Task.checkCancellation()
                        await DownloaderInfra.reportStatus(.savingFile)
                        let suffix = MediaFileUtilities.sniffSuffix(temporaryURL, defaultSuffix: task.destination.pathExtension.isEmpty ? "bin" : task.destination.pathExtension)
                        let finalURL = task.destination.deletingPathExtension().appendingPathExtension(suffix)
                        try? FileManager.default.removeItem(at: finalURL)
                        try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: finalURL.path)
                        if let videoHDRHint = task.videoHDRHint, finalURL.pathExtension.lowercased() == "mp4" {
                            try? await remuxHDRVideoIfNeeded(at: finalURL, hint: videoHDRHint)
                        }
                        task.displayOrder?.write(to: finalURL)
                        return DownloadResult(isLivePhoto: task.isLivePhoto, hasAudio: hasAudio,
                            usedOriginalLivePhoto: isOriginal, recoveredAudio: recoveredAudio,
                            sourceURL: sourceURL, fromAppCache: task.usesClientVideoSource)
                    } catch {
                        try Task.checkCancellation()
                        if DownloaderHTTPCompatibility.isCancellation(error) { throw error }
                        lastError = error
                        try? FileManager.default.removeItem(at: temporaryURL)
                    }
                }
            } catch {
                try Task.checkCancellation()
                if DownloaderHTTPCompatibility.isCancellation(error) { throw error }
                lastError = error
                try? FileManager.default.removeItem(at: task.destination.appendingPathExtension("part"))
            }
            try Task.checkCancellation()
            if attempt < retries {
                await DownloaderInfra.reportStatus(.retrying)
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        throw lastError ?? NSError(domain: "XHSDownloader", code: 7, userInfo: [NSLocalizedDescriptionKey: "下载失败：\(task.destination.lastPathComponent)"])
    }

    /// Ordinary videos try the upload first. Only a detail record bound to this
    /// exact note can supply a client fallback; public playback variants never do.
    static func downloadVideo(
        _ note: NoteInfo, task: DownloadTask, shareURL: URL,
        progress: DownloaderInfra.ProgressHandler? = nil,
        cacheLoader: (@Sendable () async throws -> NoteInfo?)? = nil
    ) async throws -> DownloadResult {
        try Task.checkCancellation()
        var cloudError: Error?
        if let original = note.originalVideoURL {
            var primary = task
            primary.urls = [original]
            primary.originalVideoURL = original
            primary.usesClientVideoSource = false
            primary.videoHDRHint = nil
            do { return try await download(primary, retries: 0, progress: progress) }
            catch {
                try Task.checkCancellation()
                if DownloaderHTTPCompatibility.isCancellation(error) { throw error }
                cloudError = error
                await DownloaderInfra.reportStatus(.readingClient)
            }
        }
        var cached: NoteInfo?
        if note.videoFromAppCache {
            var existing = note
            existing.videoURLs = note.videoURLs.filter { $0 != note.originalVideoURL }
            existing.videoURL = existing.videoURLs.first
            if existing.hasMedia { cached = existing }
        }
        if cached == nil {
            if let cacheLoader { cached = try await cacheLoader() }
            else { cached = try await loadClientVideo(noteID: note.noteID, shareURL: shareURL) }
        }
        try Task.checkCancellation()
        guard let cached, cached.noteID == note.noteID, cached.type == "video", cached.videoFromAppCache,
              !cached.videoURLs.isEmpty else {
            let detail = cloudError.map { "（\($0.localizedDescription)）" } ?? ""
            throw NSError(domain: "XHSDownloader", code: 8, userInfo: [NSLocalizedDescriptionKey: "云端原视频不可用\(detail)，客户端缓存也没有同笔记的可用视频来源。请在小红书客户端打开该笔记后重试。"])
        }
        var fallback = task
        fallback.urls = cached.videoURLs
        fallback.requestUserAgent = cached.requestUserAgent
        fallback.videoHDRHint = nil
        fallback.originalVideoURL = nil
        fallback.usesClientVideoSource = true
        if cloudError != nil { await DownloaderInfra.reportStatus(.tryingAlternative) }
        return try await download(fallback, progress: progress)
    }

    private static func loadClientVideo(noteID: String, shareURL: URL) async throws -> NoteInfo? {
        guard XHSAppCache.isNoteID(noteID) else { return nil }
        func readCache() -> NoteInfo? {
            preferredNote(XHSAppCache.notes(noteID: noteID, roots: XHSAppCache.cacheRoots()).compactMap {
                parseAppNote($0, expectedID: noteID, fallbackURL: shareURL)
            }.filter { $0.type == "video" })
        }
        try Task.checkCancellation()
        await DownloaderInfra.reportStatus(.readingClient)
        if let cached = readCache(), cached.hasMedia { return cached }
        await DownloaderInfra.reportStatus(.waitingClient)
        guard await XHSAppCache.openNote(noteID, shareURL: shareURL) else { return nil }
        for _ in 0..<8 {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
            if let cached = readCache(), cached.hasMedia { return cached }
        }
        try Task.checkCancellation()
        return nil
    }

    static func livePhotoHasAudio(at url: URL) async throws -> Bool {
        let suffix = MediaFileUtilities.sniffSuffix(url, defaultSuffix: "mp4")
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: suffix == "mov" ? "video/quicktime" : "video/mp4"])
        return try await !asset.loadTracks(withMediaType: .audio).isEmpty
    }

    static func recoverLivePhotoAudio(_ task: DownloadTask, at original: URL, excluding selectedURL: URL,
                                     cacheRoots: [URL]? = nil) async throws -> Bool {
        let candidates = orderedUniqueURLs(task.livePhotoAudioURLs + task.urls)
            .filter { !task.originalLivePhotoURLs.contains($0) }
        guard !candidates.isEmpty else { return false }
        let donor = task.destination.appendingPathExtension("audio-source.part")
        let merged = task.destination.appendingPathExtension("audio-merged.part")
        defer {
            try? FileManager.default.removeItem(at: donor)
            try? FileManager.default.removeItem(at: merged)
        }
        enum Source { case cloud, localCache }
        // Try every cloud donor before reading a local one. A successful download
        // can still lack usable audio; the selected client URL can have a cache
        // donor even when no other playback URL exists.
        for source in [Source.cloud, .localCache] {
            let urls: [URL]
            let roots: [URL]
            switch source {
            case .cloud:
                urls = candidates.filter { $0 != selectedURL }
                roots = []
            case .localCache:
                urls = candidates
                roots = cacheRoots ?? XHSAppCache.cacheRoots().map {
                    $0.deletingLastPathComponent().appendingPathComponent("com.xiaohongshu.livephoto_netcache")
                }
            }
            for url in urls {
                try Task.checkCancellation()
                defer {
                    try? FileManager.default.removeItem(at: donor)
                    try? FileManager.default.removeItem(at: merged)
                }
                do {
                    switch source {
                    case .cloud:
                        await DownloaderInfra.reportStatus(.recoveringAudio)
                        try await downloadOnceAsync(url, to: donor, requestUserAgent: task.requestUserAgent, stage: .recoveringAudio)
                    case .localCache:
                        await DownloaderInfra.reportStatus(.recoveringAudio)
                        guard try XHSCachedMotionReader.copyMotion(for: url, cacheRoots: roots, to: donor) else { continue }
                    }
                    try await MediaFileUtilities.validateMedia(donor, expectedSuffix: "mp4")
                    guard try await livePhotoHasAudio(at: donor) else { continue }
                    await DownloaderInfra.reportStatus(.recoveringAudio)
                    guard try await XHSLivePhotoAudioRecovery.addingAudio(from: donor, to: original, output: merged) else { continue }
                    try await MediaFileUtilities.validateMedia(merged, expectedSuffix: "mov")
                    guard try await livePhotoHasAudio(at: merged) else { continue }
                    try Task.checkCancellation()
                    _ = try FileManager.default.replaceItemAt(original, withItemAt: merged)
                    return true
                } catch {
                    try Task.checkCancellation()
                    if DownloaderHTTPCompatibility.isCancellation(error) { throw error }
                    // A failed donor never replaces the original visual track
                    // or makes a naturally silent Live Photo fail.
                }
            }
        }
        return false
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
        DownloaderNetworkPolicy.isXHSShortLinkHost(req.url?.host)
    }

    private static func downloadOnceAsync(
        _ url: URL,
        to destination: URL,
        requestUserAgent: String,
        progress: DownloaderInfra.ProgressHandler? = nil,
        transferPolicy: DownloaderHTTPCompatibility.TransferPolicy? = nil,
        stage: DownloaderInfra.DownloadStage = .downloadingFile
    ) async throws {
        let requestURL = secureXHSURL(url)
        try await DownloaderInfra.downloadOnceAsync(requestURL, to: destination, userAgent: requestUserAgent,
            session: networkSession, shouldUseDirectly: shouldUseDirectly,
            extraHeaders: ["Referer": "https://www.xiaohongshu.com/"], progress: progress, transferPolicy: transferPolicy, stage: stage)
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
