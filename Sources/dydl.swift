import Foundation
import AVFoundation

enum DouyinNativeDownloader {
    private static let debugEnabled: Bool = {
        ProcessInfo.processInfo.environment["HERMES_DEBUG"] == "1"
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.hermes_debug")
    }()
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 aweme"
    private static let maxConcurrentDownloads = DownloaderHTTPCompatibility.downloadConcurrencyLimit()
    private static let maxDouyinCacheWorkers = {
        if let value = Int(ProcessInfo.processInfo.environment["HERMES_DOUYIN_CACHE_WORKERS"] ?? "") {
            return min(max(value, 1), 12)
        }
        return min(max(ProcessInfo.processInfo.activeProcessorCount - 2, 2), 6)
    }()
    private static let networkSession: URLSession = DownloaderHTTPCompatibility.makeDownloadSession(timeoutResource: 14_400)
    private static let douyinCacheRootPaths = [
        NSHomeDirectory() + "/Library/Application Support/抖音/Cache/Cache_Data",
        NSHomeDirectory() + "/Library/Containers/com.bytedance.douyin.desktop/Data/Library/Application Support/抖音/Cache/Cache_Data",
        NSHomeDirectory() + "/Library/Group Containers/3JTPEA4UU7.com.bytedance.douyin.desktop/Library/Application Support/抖音/Cache/Cache_Data"
    ]
    private static let douyinCacheIndex = DouyinCacheIndex()

    struct AwemeInfo {
        var awemeID = ""
        var desc = ""
        var sourceVideoID: String?
        var didProbeSource = false
        var author = "unknown"
        var authorID = ""
        var images: [MediaItem] = []
        var videos: [VideoItem] = []

        var hasSourceMarkedHDRVideo: Bool {
            images.contains { $0.sourceMarkedHDR } || videos.contains { $0.sourceMarkedHDR }
        }

        var hasStreamMarkedHDRVideo: Bool {
            images.contains { $0.streamMarkedHDR } || videos.contains { $0.streamMarkedHDR }
        }
    }

    struct MediaItem {
        var index: Int
        var imageURL: URL
        var videoURL: URL?
        var sourceMarkedHDR: Bool
        var streamMarkedHDR: Bool
        var width: Int
        var height: Int
        var videoWidth: Int
        var videoHeight: Int
    }

    struct VideoItem {
        var index: Int
        var videoURL: URL
        var sourceMarkedHDR: Bool
        var streamMarkedHDR: Bool
        var width: Int
        var height: Int
        var fallbackVideoURL: URL? = nil
        var alternateURLs: [URL] = []
    }

    struct VideoSelection {
        var alternateURLs: [URL] = []
        var url: URL
        var width: Int
        var height: Int
        var sourceMarkedHDR: Bool
        var streamMarkedHDR: Bool
    }

    struct DownloadTask {
        var url: URL
        var destination: URL
        var fallbackURL: URL? = nil
        var alternateURLs: [URL] = []
    }

    struct DownloadOutcome: Sendable {
        var fileURL: URL
        var sourceHost: String
        var usedFallback = false
    }

    /// Seed info extracted from the Douyin share page HTML (_ROUTER_DATA / RENDER_DATA / __NEXT_DATA__).
    /// Used to supplement fetchAweme when the Web API returns empty or incomplete data.
	    private struct DouyinSeedInfo {
	        var desc: String?
	        var author: String?
	        var authorID: String?
	        var videoID: String?   // v0200fg... from play_addr URL
	        var width: Int?
	        var height: Int?
	        var fps: Int?          // frame rate from seed video (e.g. 60)
	        var playURL: URL?      // raw play_addr URL from seed data
	    }

    private struct DouyinCacheEntry: Codable {
        var url: URL
        var date: Date
        var priority: Int
        var size: Int
        var originalKey: String
        var key: String
        var decodedKey: String
        var compactKey: String
    }

    private struct DouyinCacheSnapshot: Codable {
        var date: Date
        var size: Int
        var entry: DouyinCacheEntry?
    }

    private struct DouyinCacheFileStages {
        var stages: [[URL]]
        var totalCandidateCount: Int
    }

	    private struct DouyinDirectMediaCandidate {
	        var url: URL
	        var cacheFile: URL
	        var score: Int64
	        var bitRate: Int
	        var byteRate: Int
	        var dataSize: Int
	        var fps: Int
	        var matchedAwemeID: String?
	        var matchedVideoID: String?
	        var width: Int
	        var height: Int
	        var dimensionSource: String
	    }

    private final class DouyinCacheIndex: @unchecked Sendable {
        private struct Store: Codable {
            var version: Int
            var snapshotsByPath: [String: DouyinCacheSnapshot]
            var rootSnapshotsByPath: [String: DouyinCacheRootSnapshot]
        }

        private struct DouyinCacheRootSnapshot: Codable, Equatable {
            var modificationDate: Date?
            var fileNames: [String]
        }

        private static let storeVersion = 7
        private let lock = NSLock()
        private var snapshotsByPath: [String: DouyinCacheSnapshot]
        private var rootSnapshotsByPath: [String: DouyinCacheRootSnapshot]
        private var loadedFromDisk = false
        private var dirty = false

        init() {
            snapshotsByPath = [:]
            rootSnapshotsByPath = [:]
        }

        func entries(in rootPaths: [String], progress: ((Double) -> Void)? = nil) -> [DouyinCacheEntry] {
            lock.lock()
            defer { lock.unlock() }

            loadFromDiskIfNeeded()
            progress?(0.02)
            var rootStates: [(rootPath: String, folder: URL, modificationDate: Date?)] = []
            for rootPath in rootPaths {
                let folder = URL(fileURLWithPath: rootPath, isDirectory: true)
                guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                let modificationDate = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                rootStates.append((rootPath, folder, modificationDate))
            }

            if canUseDirectoryFastPath(rootStates: rootStates) {
                // Quick integrity check: list *_0 file names and re-stat high-priority
                // files. Chromium may overwrite existing cache files without changing
                // the directory modification date, so directory mtime alone is not
                // sufficient to guarantee snapshot freshness.
                var needsSlowPath = false
                let rootPrefixes = rootStates.map { $0.folder.path + "/" }
                for rootState in rootStates {
                    guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: rootState.folder.path) else {
                        needsSlowPath = true; break
                    }
                    let currentNames = Set(fileNames.filter { $0.hasSuffix("_0") })
                    let storedNames = rootSnapshotsByPath[rootState.rootPath].map { Set($0.fileNames) } ?? []
                    guard currentNames == storedNames else {
                        needsSlowPath = true; break
                    }
                    // Re-stat high-priority files (aweme/detail, history/read, feed) to
                    // catch in-place overwrites that don't change directory mtime.
                    let rootPrefix = rootState.folder.path + "/"
                    for (path, snapshot) in snapshotsByPath where path.hasPrefix(rootPrefix) {
                        guard let entry = snapshot.entry, entry.priority <= 1 else { continue }
                        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                              let fileSize = values.fileSize, fileSize >= 32,
                              let modDate = values.contentModificationDate else {
                            needsSlowPath = true; break
                        }
                        guard snapshot.date == modDate, snapshot.size == fileSize else {
                            needsSlowPath = true; break
                        }
                    }
                    if needsSlowPath { break }
                }
                if !needsSlowPath {
                    progress?(1.0)
                    return snapshotsByPath.compactMap { path, snapshot in
                        guard rootPrefixes.contains(where: { path.hasPrefix($0) }) else { return nil }
                        return snapshot.entry
                    }
                }
                // Falls through to slow path below.
            }

            var rootFiles: [(rootPath: String, folder: URL, fileNames: [String], fileNameSet: Set<String>)] = []
            var activePaths = Set<String>()
            for rootState in rootStates {
                let folder = rootState.folder
                guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
                let cacheFileNames = fileNames.filter { $0.hasSuffix("_0") }.sorted()
                let fileNameSet = Set(cacheFileNames)
                rootFiles.append((rootState.rootPath, folder, cacheFileNames, fileNameSet))
                for name in cacheFileNames {
                    activePaths.insert(folder.appendingPathComponent(name).path)
                }
            }

            var result: [DouyinCacheEntry] = []
            let totalNamesToInspect = max(rootFiles.reduce(0) { $0 + $1.fileNames.count }, 1)
            var inspectedNameCount = 0
            for rootFile in rootFiles {
                let modificationDate = rootStates.first(where: { $0.rootPath == rootFile.rootPath })?.modificationDate
                let previousNames = rootSnapshotsByPath[rootFile.rootPath].map { Set($0.fileNames) }
                rootSnapshotsByPath[rootFile.rootPath] = DouyinCacheRootSnapshot(
                    modificationDate: modificationDate,
                    fileNames: rootFile.fileNames
                )
                dirty = true

                let rootPrefix = rootFile.folder.path + "/"
                let cachedNames = snapshotsByPath.keys.compactMap { path -> String? in
                    guard path.hasPrefix(rootPrefix) else { return nil }
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    return rootFile.fileNameSet.contains(name) ? name : nil
                }
                let namesToInspect: Set<String>
                if let previousNames {
                    namesToInspect = rootFile.fileNameSet.subtracting(previousNames).union(cachedNames)
                } else {
                    namesToInspect = rootFile.fileNameSet
                }
                var inspectedNames = Set<String>()

                for name in namesToInspect.sorted() {
                    inspectedNames.insert(name)
                    inspectedNameCount += 1
                    if inspectedNameCount == 1 || inspectedNameCount % 400 == 0 {
                        progress?(min(Double(inspectedNameCount) / Double(totalNamesToInspect), 0.98))
                    }
                    let folder = rootFile.folder
                    let file = folder.appendingPathComponent(name)
                    let path = file.path
                    activePaths.insert(path)

                    guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                          let fileSize = values.fileSize, fileSize >= 32, fileSize <= 20_000_000,
	                          let modDate = values.contentModificationDate else {
                        if snapshotsByPath.removeValue(forKey: path) != nil {
                            dirty = true
                        }
                        continue
                    }

                    if let cached = snapshotsByPath[path],
                       cached.size == fileSize,
                       cached.date == modDate {
                        if let entry = cached.entry {
                            result.append(entry)
                        }
                        continue
                    }

                    guard let refreshed = DouyinNativeDownloader.douyinCacheEntry(for: file, modDate: modDate, fileSize: fileSize) else {
                        if snapshotsByPath.removeValue(forKey: path) != nil {
                            dirty = true
                        }
                        continue
                    }
                    snapshotsByPath[path] = DouyinCacheSnapshot(date: modDate, size: fileSize, entry: refreshed)
                    dirty = true
                    result.append(refreshed)
                }

                for (path, snapshot) in snapshotsByPath where path.hasPrefix(rootPrefix) {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    guard rootFile.fileNameSet.contains(name), !inspectedNames.contains(name), let entry = snapshot.entry else {
                        continue
                    }
                    result.append(entry)
                }
            }

            let rootPrefixes = rootPaths.map { URL(fileURLWithPath: $0, isDirectory: true).path + "/" }
            let filteredSnapshots = snapshotsByPath.filter { path, _ in
                guard rootPrefixes.contains(where: { path.hasPrefix($0) }) else { return true }
                return activePaths.contains(path)
            }
            if filteredSnapshots.count != snapshotsByPath.count {
                snapshotsByPath = filteredSnapshots
                dirty = true
            }
            saveToDiskIfNeeded()
            progress?(1.0)
            return result
        }

        private func canUseDirectoryFastPath(rootStates: [(rootPath: String, folder: URL, modificationDate: Date?)]) -> Bool {
            guard !rootStates.isEmpty, !snapshotsByPath.isEmpty else { return false }
            for rootState in rootStates {
                guard let snapshot = rootSnapshotsByPath[rootState.rootPath],
                      snapshot.modificationDate == rootState.modificationDate else {
                    return false
                }
            }
            return true
        }

        private func loadFromDiskIfNeeded() {
            guard !loadedFromDisk else { return }
            loadedFromDisk = true
            guard let data = try? Data(contentsOf: Self.storeURL),
                  let store = try? JSONDecoder().decode(Store.self, from: data),
                  store.version == Self.storeVersion else {
                return
            }
            snapshotsByPath = store.snapshotsByPath
            rootSnapshotsByPath = store.rootSnapshotsByPath
        }

        private func saveToDiskIfNeeded() {
            guard dirty else { return }
            dirty = false
            let store = Store(
                version: Self.storeVersion,
                snapshotsByPath: snapshotsByPath,
                rootSnapshotsByPath: rootSnapshotsByPath
            )
            do {
                try FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(store)
                try data.write(to: Self.storeURL, options: [.atomic])
            } catch {
                if DouyinNativeDownloader.debugEnabled { print("[DouyinDebug] cache index store: \(error.localizedDescription)") }
            }
        }

        private static var storeURL: URL {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
            return root
                .appendingPathComponent("HERMES", isDirectory: true)
                .appendingPathComponent("DouyinCacheIndex-v1.json")
        }
    }

    static func run(
        shareText: String,
        destinationRoot: URL,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async -> ToolRunResult {
        do {
            let links = try extractLinks(from: shareText)
            guard !links.isEmpty else {
                if debugEnabled { print("[DouyinDebug] run: no links extracted from share text") }
                return .failure("没有提取到抖音作品链接。")
            }
            if debugEnabled { print("[DouyinDebug] run: extracted \(links.count) link(s): \(links.map(\.absoluteString))") }

            try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            var lines: [String] = []
            for (linkIndex, link) in links.enumerated() {
                let linkFraction = Double(linkIndex) / Double(links.count)
                let linkWidth = 1.0 / Double(links.count)
                /// 媒体解析阶段占每个链接的 20% 工作量。
                let scanRatio = 0.2

                if let progress {
                    await progress(linkFraction + 0.01 * linkWidth)
                }
                let (resolvedURL, seedInfo) = try await resolveURL(link)
                if debugEnabled { print("[DouyinDebug] run: resolved URL = \(resolvedURL.absoluteString)") }
                if let progress {
                    await progress(linkFraction + 0.02 * linkWidth)
                }
                let awemeID = try extractAwemeID(from: resolvedURL)
                if debugEnabled { print("[DouyinDebug] run: awemeID = \(awemeID)") }
                if let progress {
                    await progress(linkFraction + 0.04 * linkWidth)
                }
                let scanProgress: DownloaderInfra.ProgressHandler?
                if let progress {
                    scanProgress = { fraction in
                        await progress(linkFraction + (0.04 + fraction * (scanRatio - 0.04)) * linkWidth)
                    }
                } else {
                    scanProgress = nil
                }
                var info = try await fetchAweme(awemeID: awemeID, referer: resolvedURL, seedInfo: seedInfo, progress: scanProgress)
                if info.images.isEmpty, info.videos.count == 1, !info.didProbeSource {
                    if info.sourceVideoID == nil, let seedID = seedInfo.videoID,
                       DouyinSourceResolver.sourceURL(videoID: seedID) != nil { info.sourceVideoID = seedID }
                    if let resolved = await resolveSourceVideo(info) { info = resolved }
                }
                if debugEnabled { print("[DouyinDebug] run: fetched info - images=\(info.images.count) videos=\(info.videos.count)") }
                guard !info.images.isEmpty || !info.videos.isEmpty else {
                    throw NSError(domain: "DouyinDownloader", code: 4, userInfo: [NSLocalizedDescriptionKey: "没有可下载的抖音媒体。"])
                }

                let author = FileNaming.sanitizeFileName(info.author.isEmpty ? "unknown" : info.author, fallback: "unknown")
                let authorID = FileNaming.sanitizeFileName(info.authorID.isEmpty ? "unknown" : info.authorID, fallback: "unknown")
                let outputFolder = try FileNaming.userOutputFolder(root: destinationRoot, author: author, userID: authorID, defaultName: "douyin")
                let folderName = outputFolder.lastPathComponent
                try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

                var usedNames = Set<String>()
                var tasks: [DownloadTask] = []
                let usesIndexedNames = info.images.count > 1
                for item in info.images {
                    let stem = usesIndexedNames
                        ? "\(info.awemeID)_\(String(format: "%02d", item.index))"
                        : info.awemeID
                    tasks.append(DownloadTask(
                        url: item.imageURL,
                        destination: FileNaming.uniqueDestination(in: outputFolder, name: "\(stem).jpg", usedNames: &usedNames)
                    ))
                    if let videoURL = item.videoURL {
                        tasks.append(DownloadTask(
                            url: videoURL,
                            destination: FileNaming.uniqueDestination(in: outputFolder, name: "\(stem).mp4", usedNames: &usedNames)
                        ))
                    }
                }
                let usesIndexedVideoNames = info.videos.count > 1
                for item in info.videos {
                    let stem = usesIndexedVideoNames
                        ? "\(info.awemeID)_\(String(format: "%02d", item.index))"
                        : info.awemeID
                    tasks.append(DownloadTask(
                        url: item.videoURL,
                        destination: FileNaming.uniqueDestination(in: outputFolder, name: "\(stem).mp4", usedNames: &usedNames),
                        fallbackURL: item.fallbackVideoURL,
                        alternateURLs: item.alternateURLs
                    ))
                }

                let downloadProgress: DownloaderInfra.ProgressHandler?
                if let progress {
                    downloadProgress = { fraction in
                        await progress(linkFraction + scanRatio * linkWidth + fraction * (1 - scanRatio) * linkWidth)
                    }
                } else {
                    downloadProgress = nil
                }
                let outcomes = try await download(tasks, progress: downloadProgress)
                let liveCount = info.images.filter { $0.videoURL != nil }.count
                var summary = [
                    "awemeId: \(info.awemeID)",
                    "用户: \(folderName)",
                    "下载无水印图片: \(info.images.count) 张",
                    "下载普通视频: \(info.videos.count) 个",
                    "下载 Live Photo 视频: \(liveCount) 个",
                    "输出目录: \(outputFolder.path)"
                ]
                if !info.images.isEmpty, liveCount < info.images.count {
                    summary.append("部分图片未取得动态视频；本次结果不代表已确认这些图片均为普通照片。")
                }
                for outcome in outcomes where ["mp4", "mov", "m4v"].contains(outcome.fileURL.pathExtension.lowercased()) {
                    let asset = AVURLAsset(url: outcome.fileURL)
                    if let track = try? await asset.loadTracks(withMediaType: .video).first,
                       let size = try? await track.load(.naturalSize),
                       let fps = try? await track.load(.nominalFrameRate) {
                        summary.append("实际视频: \(Int(size.width))×\(Int(size.height)), \(String(format: "%.2f", fps)) fps；\(outcome.usedFallback ? "已使用备用流" : "首选候选")；来源: \(outcome.sourceHost)")
                    }
                }
                if info.hasSourceMarkedHDRVideo {
                    summary.append(info.hasStreamMarkedHDRVideo
                        ? "HDR: 已优先选择带 HDR 标识的视频流"
                        : "HDR: 源视频标记为 HDR，但公开接口未返回带 HDR 标识的视频流，已保留本次可下载候选流，未验证 HDR")
                }
                lines.append(summary.joined(separator: "\n"))
            }
            lines.append("完成。输出只保留媒体文件，不下载背景音乐。")
            return .success(lines.joined(separator: "\n\n"))
        } catch {
            if debugEnabled { print("[DouyinDebug] run: ERROR - \(error.localizedDescription)") }
            return .failure(error.localizedDescription)
        }
    }

    private static func extractLinks(from text: String) throws -> [URL] {
        let patterns = [
            #"https?://v\.douyin\.com/[^\s"<>\\^`{|}，。；！？、【】《》]+"#,
            #"https?://(?:www\.)?douyin\.com/[^\s"<>\\^`{|}，。；！？、【】《》]+"#,
            #"https?://(?:www\.)?iesdouyin\.com/[^\s"<>\\^`{|}，。；！？、【】《》]+"#
        ]
        var links: [URL] = []
        var seen = Set<String>()
        for pattern in patterns {
            for rawValue in RegexUtilities.allMatches(pattern, in: text) {
                let cleaned = MediaFileUtilities.trimURLPunctuation(rawValue)
                guard let url = URL(string: cleaned), seen.insert(url.absoluteString).inserted else { continue }
                links.append(url)
            }
        }
        let trimmedText = MediaFileUtilities.trimURLPunctuation(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmedText.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           let url = URL(string: trimmedText),
           let host = url.host?.lowercased(),
           host.contains("douyin.com") || host.contains("iesdouyin.com") {
            if seen.insert(url.absoluteString).inserted {
                links.append(url)
            }
        }
        return links
    }

    private static func resolveURL(_ url: URL) async throws -> (resolvedURL: URL, seedInfo: DouyinSeedInfo) {
        do {
            let (data, responseURL) = try await requestAsync(url, referer: nil, readsBody: true)
            let finalURL = responseURL ?? url
            let pageHTML = String(data: data, encoding: .utf8) ?? ""
            let seedInfo = parseDouyinSeedInfo(pageHTML)
	        if debugEnabled, seedInfo.videoID != nil || seedInfo.desc != nil {
	            print("[DouyinDebug] resolveURL: seedInfo videoID=\(seedInfo.videoID ?? "nil") desc=\(seedInfo.desc?.prefix(50) ?? "nil") width=\(seedInfo.width.map(String.init) ?? "nil") height=\(seedInfo.height.map(String.init) ?? "nil") fps=\(seedInfo.fps.map(String.init) ?? "nil")")
	        }
            return (finalURL, seedInfo)
        } catch {
            if let fallback = try? await resolveURLWithCompatibilityCurl(url) {
                if debugEnabled {
                    print("[DouyinDebug] resolveURL: URLSession failed (\(error.localizedDescription)); curl resolved \(fallback.resolvedURL.absoluteString)")
                }
                return fallback
            }
            throw error
        }
    }

    private static func resolveURLWithCompatibilityCurl(_ url: URL) async throws -> (resolvedURL: URL, seedInfo: DouyinSeedInfo) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.assumesHTTP3Capable = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, responseURL) = try await DownloaderHTTPCompatibility.dataAsync(for: request, readsBody: true)
        let finalURL = responseURL ?? url
        let pageHTML = String(data: data, encoding: .utf8) ?? ""
        return (finalURL, parseDouyinSeedInfo(pageHTML))
    }

    /// Parse the Douyin share page HTML to extract embedded JSON seed data.
    /// Looks for `window._ROUTER_DATA` first, then RENDER_DATA / __NEXT_DATA__ fallback.
    private static func parseDouyinSeedInfo(_ html: String) -> DouyinSeedInfo {
        var info = DouyinSeedInfo()

        if let routerText = RegexUtilities.firstCapture(
            1,
            pattern: #"<script[^>]*>.*?window\._ROUTER_DATA\s*=\s*(\{.*?\})\s*;?\s*</script>"#,
            in: html,
            dotMatchesLineSeparators: true
        ),
           let routerJSON = jsonDictionary(from: routerText) {
            for seed in awemeSeedCandidates(from: routerJSON) {
                applyDouyinSeed(seed, to: &info)
            }
        }

        let fallbackPatterns = [
            #"<script[^>]+id=["']RENDER_DATA["'][^>]*\stype=["']application/json["'][^>]*>(.*?)</script>"#,
            #"<script[^>]+id=["']__NEXT_DATA__["'][^>]*\stype=["']application/json["'][^>]*>(.*?)</script>"#
        ]
        for pattern in fallbackPatterns {
            guard let jsonText = RegexUtilities.firstCapture(1, pattern: pattern, in: html, dotMatchesLineSeparators: true),
                  let json = jsonDictionary(from: jsonText) else {
                continue
            }
            for seed in awemeSeedCandidates(from: json) {
                applyDouyinSeed(seed, to: &info)
            }
        }
        return info
    }

    private static func jsonDictionary(from jsonText: String) -> [String: Any]? {
        guard let data = jsonText.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func awemeSeedCandidates(from json: [String: Any]) -> [[String: Any]] {
        var seeds: [[String: Any]] = []
        if isAwemeSeed(json) {
            seeds.append(json)
        }
        appendVideoInfoSeeds(from: json, to: &seeds)
        if let props = json["props"] as? [String: Any],
           let pageProps = props["pageProps"] as? [String: Any] {
            if let awemeDetail = pageProps["awemeDetail"] as? [String: Any] {
                seeds.append(awemeDetail)
            }
            if let awemeDetail = pageProps["aweme_detail"] as? [String: Any] {
                seeds.append(awemeDetail)
            }
            if isAwemeSeed(pageProps) {
                seeds.append(pageProps)
            }
            appendVideoInfoSeeds(from: pageProps, to: &seeds)
        }
        if let loaderData = json["loaderData"] as? [String: Any] {
            for (_, value) in loaderData {
                guard let routeData = value as? [String: Any] else { continue }
                if isAwemeSeed(routeData) {
                    seeds.append(routeData)
                }
                appendVideoInfoSeeds(from: routeData, to: &seeds)
            }
        }
        return seeds
    }

    private static func appendVideoInfoSeeds(from container: [String: Any], to seeds: inout [[String: Any]]) {
        if let videoInfoRes = container["videoInfoRes"] as? [String: Any],
           let itemList = videoInfoRes["item_list"] as? [[String: Any]] {
            seeds.append(contentsOf: itemList)
        }
        if let itemList = container["item_list"] as? [[String: Any]] {
            seeds.append(contentsOf: itemList)
        }
    }

    private static func isAwemeSeed(_ value: [String: Any]) -> Bool {
        value["awemeId"] != nil
            || value["aweme_id"] != nil
            || value["group_id"] != nil
            || value["video"] != nil
    }

    private static func applyDouyinSeed(_ seed: [String: Any], to info: inout DouyinSeedInfo) {
        if info.desc == nil {
            info.desc = JSONValueUtilities.nonEmptyString(seed["desc"]) ?? JSONValueUtilities.nonEmptyString(seed["caption"])
        }
        if info.author == nil, let author = seed["author"] as? [String: Any] {
            info.author = JSONValueUtilities.nonEmptyString(author["nickname"])
                ?? JSONValueUtilities.nonEmptyString(author["unique_id"])
                ?? JSONValueUtilities.nonEmptyString(author["short_id"])
        }
        if info.authorID == nil, let author = seed["author"] as? [String: Any] {
            info.authorID = JSONValueUtilities.nonEmptyString(author["unique_id"])
                ?? JSONValueUtilities.nonEmptyString(author["short_id"])
                ?? JSONValueUtilities.nonEmptyString(author["uid"])
                ?? JSONValueUtilities.nonEmptyString(author["sec_uid"])
        }
	        guard let video = seed["video"] as? [String: Any] else { return }
	        if info.width == nil {
	            let width = JSONValueUtilities.intValue(video["width"])
	            if width > 0 { info.width = width }
	        }
	        if info.height == nil {
	            let height = JSONValueUtilities.intValue(video["height"])
	            if height > 0 { info.height = height }
	        }
	        if info.fps == nil {
	            let fps = JSONValueUtilities.intValue(video["fps"]) != 0 ? JSONValueUtilities.intValue(video["fps"]) : JSONValueUtilities.intValue(video["FPS"]) != 0 ? JSONValueUtilities.intValue(video["FPS"]) : JSONValueUtilities.intValue(video["frame_rate"])
	            if fps > 0 { info.fps = fps }
	        }
        for playAddr in douyinPlayAddrDictionaries(from: video) {
            if info.videoID == nil,
               let uri = JSONValueUtilities.nonEmptyString(playAddr["uri"]),
               isLikelyDouyinVideoID(uri) {
                info.videoID = uri
            }
            for urlString in stringArray(playAddr["url_list"]) {
                guard let playURL = URL(string: MediaFileUtilities.formatURL(urlString)) else { continue }
                if info.playURL == nil {
                    info.playURL = playURL
                }
                if info.videoID == nil,
                   let components = URLComponents(url: playURL, resolvingAgainstBaseURL: false),
                   let vid = components.queryItems?.first(where: { $0.name == "video_id" })?.value,
                   isLikelyDouyinVideoID(vid) {
                    info.videoID = vid
                }
            }
        }
    }

    private static func douyinPlayAddrDictionaries(from video: [String: Any]) -> [[String: Any]] {
        var playAddrs: [[String: Any]] = []
        if let playAddr = video["play_addr"] as? [String: Any] {
            playAddrs.append(playAddr)
        }
        if let bitRates = video["bit_rate"] as? [[String: Any]] {
            for bitRate in bitRates {
                if let playAddr = bitRate["play_addr"] as? [String: Any] {
                    playAddrs.append(playAddr)
                } else if bitRate["url_list"] != nil || bitRate["uri"] != nil {
                    playAddrs.append(bitRate)
                }
            }
        }
        return playAddrs
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] {
            return values
        }
        if let values = value as? [Any] {
            return values.compactMap { JSONValueUtilities.string($0) }
        }
        return []
    }

    private static func isLikelyDouyinVideoID(_ value: String) -> Bool {
        !value.isEmpty
            && value.count > 6
            && !value.contains("/")
            && !value.contains(":")
            && !value.contains("?")
            && !value.contains("&")
    }

    private static func extractAwemeID(from url: URL) throws -> String {
        let text = url.absoluteString
        let patterns = [
            #"/(?:note|video|slides)/([0-9]{16,20})"#,
            #"aweme_id=([0-9]{16,20})"#,
            #"item_id=([0-9]{16,20})"#,
            #"modal_id=([0-9]{16,20})"#,
            #"([0-9]{16,20})"#
        ]
        for pattern in patterns {
            if let value = RegexUtilities.firstCapture(1, pattern: pattern, in: text) {
                return value
            }
        }
        throw NSError(domain: "DouyinDownloader", code: 2, userInfo: [NSLocalizedDescriptionKey: "未能从抖音链接提取作品 ID。"])
    }

    private static func fetchAweme(awemeID: String, referer: URL, seedInfo: DouyinSeedInfo = DouyinSeedInfo(), progress: DownloaderInfra.ProgressHandler? = nil) async throws -> AwemeInfo {
        if debugEnabled { print("[DouyinDebug] fetchAweme: awemeID=\(awemeID)") }
        var publicInfo: AwemeInfo?
        if let progress { await progress(0.02) }
        let detailURL = URL(string: "https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=\(awemeID)&aid=6383&device_platform=webapp")!
        if let info = try? await parseAwemeResponse(from: detailURL, referer: referer), !info.images.isEmpty || !info.videos.isEmpty {
            if debugEnabled { print("[DouyinDebug] fetchAweme: got data from web aweme detail API") }
            if hasCompleteLivePhotoData(info), !hasSuspiciousLivePhotoVideo(info) {
                if let progress { await progress(1.0) }
                return info
            }
            publicInfo = info
        }
        if let progress { await progress(0.08) }
        // Preserve the fast source path before the expensive desktop cache scan.
        if publicInfo == nil, referer.path.lowercased().contains("/video/") || seedInfo.videoID != nil {
            let mobileURL = URL(string: "https://api5-normal-c-lf.amemv.com/aweme/v1/feed/?aweme_id=\(awemeID)&version_code=170400&version_name=17.4.0&count=1")!
            publicInfo = try? await parseMobileFeedResponse(from: mobileURL, targetAwemeID: awemeID)
        }
        if var info = publicInfo, info.images.isEmpty, info.videos.count == 1 {
            if info.sourceVideoID == nil { info.sourceVideoID = seedInfo.videoID }
            if let resolved = await resolveSourceVideo(info) {
                if resolved.videos[0].videoURL != info.videos[0].videoURL {
                    await progress?(1)
                    return resolved
                }
                publicInfo = resolved
            } else {
                info.didProbeSource = true
                publicInfo = info
            }
        }
        // The web app identity preserves per-image motion video fields. Without aid,
        // this endpoint can return the same work with every image.video omitted.
        // Resolve authoritative pairs before consulting the optional desktop cache.
        if publicInfo == nil || publicInfo?.images.isEmpty == false {
            let slidesURL = URL(string: "https://www.iesdouyin.com/web/api/v2/aweme/slidesinfo/?aweme_ids=%5B\(awemeID)%5D&request_source=200&aid=6383")!
            if let info = try? await parseAwemeResponse(from: slidesURL, referer: referer, quickTimeout: true),
               info.awemeID == awemeID, !info.images.isEmpty {
                if debugEnabled { print("[DouyinDebug] fetchAweme: got image pairs from slides API (web app)") }
                if hasCompleteLivePhotoData(info), !hasSuspiciousLivePhotoVideo(info) {
                    await progress?(1)
                    return info
                }
                publicInfo = await preferredInfo(info, over: publicInfo)
            }
        }
        // Desktop cache is expensive, but it is the source that can expose Live
        // Photo videos and the multi-quality bit_rate list when public APIs are
        // empty or incomplete.
        let isVideoOnly = publicInfo.map { !$0.videos.isEmpty && $0.images.isEmpty } ?? false
        let isResolvedVideoPage = referer.path.lowercased().contains("/video/")
        var needsLivePhotoVideo = isMissingLivePhotoVideo(publicInfo)
        let hasSuspiciousLivePhoto = publicInfo.map(hasSuspiciousLivePhotoVideo) ?? false
        var directCacheInfo: AwemeInfo?
        // Collect video IDs from both public API and seed info (share page).
        var publicVideoIDs = publicInfo.map(videoIDs) ?? []
        if let seedVID = seedInfo.videoID, !publicVideoIDs.contains(seedVID) {
            publicVideoIDs.append(seedVID)
        }
        if debugEnabled {
            if publicVideoIDs.isEmpty {
                print("[DouyinDebug] fetchAweme: public video_id needles EMPTY (no video_id query params found)")
            } else {
                print("[DouyinDebug] fetchAweme: public video_id needles \(publicVideoIDs)")
            }
        }
        // Use seedInfo.desc as fallback description for cache matching.
        let effectiveDesc = publicInfo?.desc ?? seedInfo.desc
        let needsDesktopCache = needsLivePhotoVideo || hasSuspiciousLivePhoto || publicInfo == nil || isVideoOnly

        if needsDesktopCache {
            if debugEnabled { print("[DouyinDebug] fetchAweme: trying desktop cache (need hidden quality, LivePhoto video, or no public data)") }
            if (publicInfo?.images.isEmpty ?? true),
               let directInfo = await cachedDirectMediaAweme(awemeID: awemeID, seedInfo: seedInfo, fallbackInfo: publicInfo, videoIDs: publicVideoIDs, progress: { fraction in
                   if let progress { await progress(0.08 + fraction * 0.72) }
               }),
               !directInfo.videos.isEmpty {
                if debugEnabled { print("[DouyinDebug] fetchAweme: got direct media from Douyin desktop cache") }
                directCacheInfo = directInfo
                if isResolvedVideoPage {
                    if let progress { await progress(1.0) }
                    return await preferredInfo(directInfo, over: publicInfo)
                }
            }
            if let publicInfo, !publicInfo.images.isEmpty,
               let timelineInfo = await cachedTimelineLivePhotoVideos(
                    awemeID: awemeID,
                    publicInfo: publicInfo,
                    progress: { fraction in
                        if let progress { await progress(0.08 + fraction * 0.18) }
                    }
               ),
               hasCompleteLivePhotoData(timelineInfo),
               !hasSuspiciousLivePhotoVideo(timelineInfo) {
                if debugEnabled { print("[DouyinDebug] fetchAweme: merged Live Photo videos from Douyin timeline cache") }
                if let progress { await progress(1.0) }
                return timelineInfo
            }
            if let progress { await progress(0.14) }
            // Cache scan uses 0%–80% of the scan phase progress budget.
            let cacheProgress: DownloaderInfra.ProgressHandler?
            if let progress {
                cacheProgress = { f in await progress(0.14 + min(f, 1) * 0.66) }
            } else {
                cacheProgress = nil
            }
            if let info = await cachedDesktopAweme(awemeID: awemeID, description: effectiveDesc, videoIDs: publicVideoIDs, progress: cacheProgress),
               !info.images.isEmpty || !info.videos.isEmpty {
                if let publicInfo, !publicInfo.images.isEmpty {
                    let merged = mergeLivePhotoVideos(from: info, into: publicInfo)
                    if hasCompleteLivePhotoData(merged), !hasSuspiciousLivePhotoVideo(merged) {
                        if debugEnabled { print("[DouyinDebug] fetchAweme: merged Live Photo video from Douyin desktop cache") }
                        if let progress { await progress(1.0) }
                        return merged
                    }
                }
                if debugEnabled { print("[DouyinDebug] fetchAweme: got full media from Douyin desktop cache") }
                if let progress { await progress(1.0) }
                return info
            }
            if debugEnabled { print("[DouyinDebug] fetchAweme: desktop cache returned no media") }
            // Advance progress past cache scan phase.
            if let progress { await progress(0.8) }
            // Live Electron-based request — uses the Douyin desktop app's network
            // stack which may bypass transparent proxies or DNS blocks that cause
            // the URLSession-based request to fail.
            // Live Electron uses 80%–95% of the scan phase progress budget.
            let liveProgress: DownloaderInfra.ProgressHandler?
            if let progress {
                liveProgress = { f in await progress(0.8 + f * 0.15) }
            } else {
                liveProgress = nil
            }
            if let electronURL = douyinElectronURL(),
               let info = await liveDesktopAweme(awemeID: awemeID, electronURL: electronURL, progress: liveProgress),
               !info.images.isEmpty || !info.videos.isEmpty {
                if let publicInfo, !publicInfo.images.isEmpty {
                    let merged = mergeLivePhotoVideos(from: info, into: publicInfo)
                    if hasCompleteLivePhotoData(merged), !hasSuspiciousLivePhotoVideo(merged) {
                        if debugEnabled { print("[DouyinDebug] fetchAweme: merged Live Photo video from live Electron request") }
                        return merged
                    }
                }
                if debugEnabled { print("[DouyinDebug] fetchAweme: got full media from live Electron request") }
                return info
            }
            // Advance progress past live Electron phase.
            if let progress { await progress(0.95) }
        } else if debugEnabled {
            print("[DouyinDebug] fetchAweme: skipping desktop cache (public data is complete)")
        }

        // Mobile feed API — sometimes returns data when the web API is blocked.
        // Uses the same endpoint the mobile app uses, which may have different CDN routing.
        if publicInfo == nil || needsLivePhotoVideo || isVideoOnly {
            if debugEnabled { print("[DouyinDebug] fetchAweme: trying mobile feed API") }
            let mobileURL = URL(string: "https://api5-normal-c-lf.amemv.com/aweme/v1/feed/?aweme_id=\(awemeID)&version_code=170400&version_name=17.4.0&count=1")!
            if let info = try? await parseMobileFeedResponse(from: mobileURL, targetAwemeID: awemeID),
               !info.images.isEmpty || !info.videos.isEmpty {
                if debugEnabled { print("[DouyinDebug] fetchAweme: got data from mobile feed API") }
                if hasCompleteLivePhotoData(info) {
                    return info
                }
                publicInfo = await preferredInfo(info, over: publicInfo)
                needsLivePhotoVideo = isMissingLivePhotoVideo(publicInfo)
            }
        }
        // Scan phase complete — report 100% of scan budget before final return/throw.
        if let progress { await progress(1.0) }
        if let publicInfo {
            if let directCacheInfo, !publicInfo.images.isEmpty {
                let merged = mergeLivePhotoVideos(from: directCacheInfo, into: publicInfo)
                if !hasSuspiciousLivePhotoVideo(merged) {
                    return merged
                }
            }
            return publicInfo
        }
        if let directCacheInfo {
            return directCacheInfo
        }
        if debugEnabled { print("[DouyinDebug] fetchAweme: ALL sources failed, throwing error") }

        throw NSError(domain: "DouyinDownloader", code: 3, userInfo: [NSLocalizedDescriptionKey: "未能从公开接口提取抖音媒体。"])
    }

    private static func resolveSourceVideo(_ info: AwemeInfo) async -> AwemeInfo? {
        guard info.images.isEmpty, info.videos.count == 1, let videoID = info.sourceVideoID else { return nil }
        do {
            guard let source = try await DouyinSourceResolver.resolve(videoID: videoID, userAgent: userAgent, session: networkSession) else { return nil }
            let old = info.videos[0]
            guard source.url != old.videoURL else { return nil }
            var upgraded = info
            upgraded.didProbeSource = true
            let oldDimensions = try? await DouyinSourceResolver.probe(url: old.videoURL, userAgent: userAgent, session: networkSession)
            let oldPixels = oldDimensions.map { Int64($0.width) * Int64($0.height) }
            let sourcePixels = Int64(source.width) * Int64(source.height)
            guard let oldPixels, sourcePixels > oldPixels, !old.streamMarkedHDR else {
                // Equal, unknown, or HDR-incomparable streams remain usable candidates.
                upgraded.videos[0].alternateURLs.append(source.url)
                return upgraded
            }
            upgraded.videos[0].fallbackVideoURL = old.videoURL
            upgraded.videos[0].videoURL = source.url
            upgraded.videos[0].width = source.width
            upgraded.videos[0].height = source.height
            // The source probe verifies dimensions, not HDR transfer characteristics.
            upgraded.videos[0].streamMarkedHDR = false
            if debugEnabled { print("[DouyinDebug] verified source video: \(source.width)x\(source.height), no desktop cache required") }
            return upgraded
        } catch {
            if debugEnabled { print("[DouyinDebug] source probe failed; preserving existing download fallbacks: \(error.localizedDescription)") }
            return nil
        }
    }

    private static func isMissingLivePhotoVideo(_ info: AwemeInfo?) -> Bool {
        guard let info, !info.images.isEmpty else { return false }
        return !hasCompleteLivePhotoData(info)
    }

    private static func hasSuspiciousLivePhotoVideo(_ info: AwemeInfo) -> Bool {
        info.images.contains { item in
            guard let url = item.videoURL else { return false }
            return hasSuspiciousLivePhotoURL(url)
        }
    }

    private static func hasSuspiciousLivePhotoURL(_ url: URL) -> Bool {
        let text = url.absoluteString.lowercased()
        guard text.contains("/aweme/v1/play") else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let videoID = components.queryItems?.first(where: { $0.name == "video_id" })?.value?.lowercased() else {
            return false
        }
        return videoID.hasPrefix("http://") || videoID.hasPrefix("https://")
    }

    private static func hasCompleteLivePhotoData(_ info: AwemeInfo) -> Bool {
        if !info.images.isEmpty {
            return info.images.allSatisfy {
                guard let videoURL = $0.videoURL else { return false }
                return isUsableVideoURL(videoURL)
            }
        }
        // For video-only posts: share page data typically lacks bit_rate
        // (multi-quality) options.  Return false so the desktop cache gets a
        // chance to supply higher-quality streams when available.
        if !info.videos.isEmpty {
            return false
        }
        return true
    }

    private static func preferredInfo(_ candidate: AwemeInfo, over current: AwemeInfo?) async -> AwemeInfo {
        guard let current else { return candidate }
        guard !current.awemeID.isEmpty, current.awemeID == candidate.awemeID else { return current }
        if current.images.isEmpty, candidate.images.isEmpty,
           current.videos.count == 1, candidate.videos.count == 1 {
            let old = current.videos[0], new = candidate.videos[0]
            guard new.videoURL != old.videoURL else { return current }
            let oldSize = try? await DouyinSourceResolver.probe(url: old.videoURL, userAgent: userAgent, session: networkSession)
            let newSize = try? await DouyinSourceResolver.probe(url: new.videoURL, userAgent: userAgent, session: networkSession)
            var selected = current
            // Compare measured values only. Keep ambiguous/HDR-incomparable candidates as fallbacks.
            if let oldSize, let newSize, (!old.streamMarkedHDR || new.streamMarkedHDR),
               Int64(newSize.width) * Int64(newSize.height) > Int64(oldSize.width) * Int64(oldSize.height) {
                selected = candidate
                selected.videos[0].width = newSize.width
                selected.videos[0].height = newSize.height
                selected.videos[0].fallbackVideoURL = old.videoURL
                selected.videos[0].alternateURLs = orderedVideoURLs(new.alternateURLs + old.alternateURLs)
            } else {
                selected.videos[0].alternateURLs = orderedVideoURLs(old.alternateURLs + [new.videoURL] + new.alternateURLs)
            }
            selected.didProbeSource = current.didProbeSource || candidate.didProbeSource
            return selected
        }
        let candidateScore = candidate.images.count * 10 + candidate.videos.count
        let currentScore = current.images.count * 10 + current.videos.count
        return candidateScore > currentScore ? candidate : current
    }

    static func mergeLivePhotoVideos(from cached: AwemeInfo, into publicInfo: AwemeInfo) -> AwemeInfo {
        // Only image entries retain an image ordinal. A flat video list has no safe pairing identity.
        guard !publicInfo.awemeID.isEmpty, cached.awemeID == publicInfo.awemeID else { return publicInfo }
        var merged = publicInfo
        for index in merged.images.indices {
            let current = merged.images[index].videoURL
            guard current == nil || hasSuspiciousLivePhotoURL(current!) else { continue }
            let matches = cached.images.filter { $0.index == merged.images[index].index }
            guard matches.count == 1, let video = matches[0].videoURL,
                  isUsableVideoURL(video), !hasSuspiciousLivePhotoURL(video) else { continue }
            merged.images[index].videoURL = video
            merged.images[index].videoWidth = matches[0].videoWidth
            merged.images[index].videoHeight = matches[0].videoHeight
            merged.images[index].streamMarkedHDR = matches[0].streamMarkedHDR
        }
        return merged
    }

    private static func videoIDs(in info: AwemeInfo) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for url in info.videos.map(\.videoURL) + info.images.compactMap(\.videoURL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let value = components.queryItems?.first(where: { $0.name == "video_id" })?.value,
                  isLikelyDouyinVideoID(value),
                  seen.insert(value).inserted else {
                continue
            }
            result.append(value)
        }
        return result
    }

	    private static func cachedDirectMediaAweme(
	        awemeID: String,
	        seedInfo: DouyinSeedInfo,
	        fallbackInfo: AwemeInfo?,
	        videoIDs: [String],
	        progress: DownloaderInfra.ProgressHandler? = nil
	    ) async -> AwemeInfo? {
	        await progress?(0.02)

	        // Direct filesystem scan of _0 cache files — avoids the persistent
	        // index which would otherwise bloat with 70K+ douyinvod.com entries.
	        // Only the key bytes (~100–200 B) are read from each file.
	        var candidates: [DouyinDirectMediaCandidate] = []
	        var totalFiles = 0
	        var douyinvodMatches = 0

	        for rootPath in douyinCacheRootPaths {
	            let folder = URL(fileURLWithPath: rootPath, isDirectory: true)
	            guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
	            let cacheNames = fileNames.filter { $0.hasSuffix("_0") }
	            for name in cacheNames {
	                totalFiles += 1
	                let file = folder.appendingPathComponent(name)
	                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
	                let header = handle.readData(ofLength: 24)
	                guard header.count == 24 else { try? handle.close(); continue }
	                let keyLength = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }.littleEndian)
	                guard keyLength > 0, keyLength < 16_384 else { try? handle.close(); continue }
	                let keyData = handle.readData(ofLength: keyLength)
	                try? handle.close()
	                let originalKey = String(decoding: keyData, as: UTF8.self)
	                let lowerKey = originalKey.lowercased()

	                // Quick-reject: must be a douyinvod video key
	                guard lowerKey.contains("douyinvod.com") else { continue }
	                guard lowerKey.contains("mime_type=video_mp4") || lowerKey.contains(".mp4") || lowerKey.contains("/video/")
	                    || lowerKey.contains("media-video") else { continue }
	                douyinvodMatches += 1

	                // Strip Chromium simple-cache key prefix and parse URL
	                var urlText = originalKey
	                if urlText.hasPrefix("1/0/") { urlText.removeFirst(4) }
	                guard let url = URL(string: urlText), isDirectDouyinVideoURL(url) else { continue }

	                // Get file size for scoring tiebreaker
	                let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

	                guard let candidate = directMediaCandidate(
	                    url: url,
	                    cacheFile: file,
	                    originalKey: originalKey,
	                    fileSize: fileSize,
	                    awemeID: awemeID,
	                    seedInfo: seedInfo,
	                    videoIDs: videoIDs
	                ) else { continue }
	                candidates.append(candidate)
	            }
	        }

	        candidates.sort { lhs, rhs in
	            if lhs.score != rhs.score { return lhs.score > rhs.score }
	            return lhs.cacheFile.path < rhs.cacheFile.path
	        }
	        await progress?(0.62)

	        if debugEnabled {
	            print("[DouyinDebug] direct media cache scan: total _0 files=\(totalFiles) douyinvodMatches=\(douyinvodMatches) candidates=\(candidates.count) for awemeID=\(awemeID) videoIDs=\(videoIDs)")
	        }
	        let candidatesToCheck = Array(candidates.prefix(8))
	        for (index, candidate) in candidatesToCheck.enumerated() {
	            if debugEnabled {
	                print("[DouyinDebug] direct media cache key hit br=\(candidate.bitRate) bt=\(candidate.byteRate) size=\(candidate.dataSize) fps=\(candidate.fps) __vid=\(candidate.matchedAwemeID ?? "nil") video_id=\(candidate.matchedVideoID ?? "nil") dimensions=\(candidate.dimensionSource) score=\(candidate.score) url=\(candidate.url.absoluteString)")
	            }
	            await progress?(0.62 + Double(index) / Double(max(candidatesToCheck.count, 1)) * 0.32)
	            guard await isReachableDirectMediaURL(candidate.url) else {
	                if debugEnabled { print("[DouyinDebug] direct media cache URL not reachable, continuing fallback: \(candidate.url.absoluteString)") }
	                continue
	            }
	            await progress?(1.0)
	            var info = AwemeInfo()
	            info.awemeID = fallbackInfo?.awemeID.isEmpty == false ? fallbackInfo!.awemeID : awemeID
	            info.desc = fallbackInfo?.desc.isEmpty == false ? fallbackInfo!.desc : (seedInfo.desc ?? "")
	            info.author = fallbackInfo?.author.isEmpty == false ? fallbackInfo!.author : (seedInfo.author ?? "unknown")
	            info.authorID = fallbackInfo?.authorID.isEmpty == false ? fallbackInfo!.authorID : (seedInfo.authorID ?? "")
	            info.videos.append(VideoItem(
	                index: 1,
	                videoURL: candidate.url,
	                sourceMarkedHDR: false,
	                streamMarkedHDR: false,
	                width: candidate.width,
	                height: candidate.height
	            ))
	            return info
	        }
	        await progress?(1.0)
	        if debugEnabled { print("[DouyinDebug] direct media cache miss for awemeID=\(awemeID)") }
	        return nil
	    }

    private static func cachedTimelineLivePhotoVideos(
        awemeID: String,
        publicInfo: AwemeInfo,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async -> AwemeInfo? {
        guard !publicInfo.images.isEmpty, isMissingLivePhotoVideo(publicInfo) else { return nil }
        await progress?(0.02)
        let entries = douyinCacheIndex.entries(in: douyinCacheRootPaths) { fraction in
            Task { @Sendable in await progress?(0.02 + min(max(fraction, 0), 1) * 0.40) }
        }
        await progress?(0.44)

        let imageNeedlesByIndex = publicInfo.images.map { douyinImageCacheNeedles(from: $0.imageURL) }
        let imageEntriesByIndex = imageNeedlesByIndex.map { needles in
            entries.filter { entry in
                needles.contains { needle in
                    entry.key.contains(needle) || entry.decodedKey.contains(needle)
                }
            }
        }
        let imageKeyHitCount = imageEntriesByIndex.reduce(0) { $0 + $1.count }
        guard imageKeyHitCount > 0 else {
            if debugEnabled { print("[DouyinDebug] timeline LivePhoto cache: no cached image key match") }
            await progress?(1.0)
            return nil
        }

        guard let imageCluster = douyinImageCacheCluster(matchesByIndex: imageEntriesByIndex) else {
            if debugEnabled { print("[DouyinDebug] timeline LivePhoto cache: no tight image cache cluster") }
            await progress?(1.0)
            return nil
        }
        let imageDates = imageCluster.map(\.date)
        guard let firstImageDate = imageDates.min(), let lastImageDate = imageDates.max() else {
            await progress?(1.0)
            return nil
        }
        let lowerBound = firstImageDate.addingTimeInterval(-0.25)
        let upperBound = lastImageDate.addingTimeInterval(3.75)
        let missingCount = publicInfo.images.filter {
            guard let videoURL = $0.videoURL else { return true }
            return hasSuspiciousLivePhotoURL(videoURL) || !isLikelyDouyinVideoPlaybackURL(videoURL)
        }.count
        let neededCount = max(missingCount, publicInfo.images.count)

	        var seen = Set<String>()
	        let candidates = entries.compactMap { entry -> (entry: DouyinCacheEntry, url: URL, score: Int64)? in
	            guard entry.date >= lowerBound, entry.date <= upperBound else { return nil }
	            // Inline timelineLivePhotoVideoURL logic
	            guard let url = directMediaURL(from: entry), isLikelyDouyinVideoPlaybackURL(url) else { return nil }
	            let lower = url.absoluteString.lowercased()
	            let decoded = (lower.removingPercentEncoding ?? lower)
	            guard !decoded.contains("media-audio"), !decoded.contains("mime_type=audio") else { return nil }
	            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
	               let vid = components.queryItems?.first(where: { $0.name == "__vid" })?.value,
	               vid != awemeID { return nil }
	            guard !decoded.contains("eid=45312") else { return nil }
	            let key = canonicalDouyinMediaURLKey(url)
	            guard seen.insert(key).inserted else { return nil }
	            // Inline timelineLivePhotoVideoScore logic
	            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
	            let queryItems = components?.queryItems ?? []
	            let bitRate = Int(queryItems.first { $0.name == "br" }?.value ?? "") ?? 0
	            let byteRate = Int(queryItems.first { $0.name == "bt" }?.value ?? "") ?? 0
	            let distance = abs(entry.date.timeIntervalSince(firstImageDate))
	            var score = Int64(max(0, 10_000 - Int(distance * 1_000))) * 1_000_000
	            score += Int64(max(bitRate, byteRate)) * 10_000
	            if lower.contains("media-video") { score += 2_000_000_000 }
	            if lower.contains("cquery=100o") { score += 1_000_000_000 }
	            if lower.contains("__vid=") { score -= 5_000_000_000 }
	            return (entry, url, score)
	        }.sorted { lhs, rhs in
	            if lhs.score != rhs.score { return lhs.score > rhs.score }
	            return lhs.entry.date < rhs.entry.date
	        }

	        if debugEnabled {
            print("[DouyinDebug] timeline LivePhoto cache: imageKeyHits=\(imageKeyHitCount) imageCluster=\(imageCluster.map { $0.date }) candidates=\(candidates.count) window=\(lowerBound)...\(upperBound)")
            for candidate in candidates.prefix(8) {
                print("[DouyinDebug] timeline LivePhoto cache candidate score=\(candidate.score) date=\(candidate.entry.date) url=\(candidate.url.absoluteString)")
            }
        }
        guard !candidates.isEmpty else {
            await progress?(1.0)
            return nil
        }

        var verified: [URL] = []
        let candidatesToCheck = Array(candidates.prefix(max(neededCount * 2, neededCount)))
        for (index, candidate) in candidatesToCheck.enumerated() {
            await progress?(0.44 + Double(index) / Double(max(candidatesToCheck.count, 1)) * 0.50)
            guard await isReachableDirectMediaURL(candidate.url) else {
                if debugEnabled { print("[DouyinDebug] timeline LivePhoto cache URL not reachable: \(candidate.url.absoluteString)") }
                continue
            }
            verified.append(candidate.url)
            if verified.count >= neededCount { break }
        }
        guard !verified.isEmpty else {
            await progress?(1.0)
            return nil
        }

        var merged = publicInfo
        var videoIndex = 0
        for index in merged.images.indices {
            let current = merged.images[index].videoURL
            let shouldReplace = current == nil
                || hasSuspiciousLivePhotoURL(current!)
                || !isLikelyDouyinVideoPlaybackURL(current!)
            guard shouldReplace, videoIndex < verified.count else { continue }
            merged.images[index].videoURL = verified[videoIndex]
            videoIndex += 1
        }
        await progress?(1.0)
        return videoIndex > 0 ? merged : nil
    }

    private static func douyinImageCacheCluster(matchesByIndex: [[DouyinCacheEntry]]) -> [DouyinCacheEntry]? {
        guard !matchesByIndex.isEmpty else { return nil }
        let requiredCount = matchesByIndex.count
        let allEntries = matchesByIndex.flatMap { $0 }
        guard !allEntries.isEmpty else { return nil }

        var clusters: [(entries: [DouyinCacheEntry], range: TimeInterval, maxDate: Date)] = []
        for anchor in allEntries {
            var cluster: [DouyinCacheEntry] = []
            for matches in matchesByIndex {
                guard let nearest = matches.min(by: {
                    abs($0.date.timeIntervalSince(anchor.date)) < abs($1.date.timeIntervalSince(anchor.date))
                }) else {
                    break
                }
                guard abs(nearest.date.timeIntervalSince(anchor.date)) <= 4.0 else {
                    break
                }
                cluster.append(nearest)
            }
            guard cluster.count == requiredCount else { continue }
            let dates = cluster.map(\.date)
            guard let minDate = dates.min(), let maxDate = dates.max() else { continue }
            let range = maxDate.timeIntervalSince(minDate)
            guard range <= 4.0 else { continue }
            clusters.append((cluster, range, maxDate))
        }

        let best = clusters.sorted { lhs, rhs in
            if lhs.maxDate != rhs.maxDate { return lhs.maxDate > rhs.maxDate }
            return lhs.range < rhs.range
        }.first
        return best?.entries
    }

    private static func douyinImageCacheNeedles(from url: URL) -> [String] {
        let text = url.absoluteString.lowercased()
        let decoded = (text.removingPercentEncoding ?? text).lowercased()
        var needles: [String] = []
        func add(_ value: String) {
            let cleaned = value.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "/?&=#"))
            guard cleaned.count >= 12, !needles.contains(cleaned) else { return }
            needles.append(cleaned)
        }
        add(decoded)
        let lastPath = url.lastPathComponent
        let objectID = lastPath
            .split(separator: "~", maxSplits: 1)
            .first
            .map(String.init) ?? lastPath
        add(objectID)
        if let match = RegexUtilities.firstCapture(1, pattern: #"/([^/?~]+)~tplv-dy-aweme-images"#, in: decoded) {
            add(match)
        }
        return needles
    }

	    private static func canonicalDouyinMediaURLKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.queryItems = components.queryItems?.filter { $0.name != "testst" && $0.name != "dy_q" && $0.name != "l" }
        return components.url?.absoluteString ?? url.absoluteString
    }

	    private static func directMediaCandidate(
	        url: URL,
	        cacheFile: URL,
	        originalKey: String,
	        fileSize: Int,
	        awemeID: String,
	        seedInfo: DouyinSeedInfo,
	        videoIDs: [String]
	    ) -> DouyinDirectMediaCandidate? {
	        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
	        let queryItems = components?.queryItems ?? []
	        let queryValue: (String) -> String? = { name in
	            queryItems.first { $0.name.lowercased() == name.lowercased() }?.value
	        }
	        let lowerKey = originalKey.lowercased()
	        let decodedKey = (originalKey.removingPercentEncoding ?? originalKey)
	            .replacingOccurrences(of: "+", with: " ")
	        let lowerDecoded = decodedKey.lowercased()
	        let lowerURL = url.absoluteString.lowercased()
	        let targetVideoIDs = videoIDs.map { $0.lowercased() }
	        let awemeNeedle = awemeID.lowercased()
	        let matchedAwemeID = queryValue("__vid") ?? queryValue("aweme_id") ?? queryValue("item_id") ?? queryValue("group_id")
	        let matchedVideoID = queryValue("video_id")
	        let matchesAweme = matchedAwemeID == awemeID
	            || lowerKey.contains(awemeNeedle)
	            || lowerDecoded.contains(awemeNeedle)
	            || lowerURL.contains(awemeNeedle)
	        let matchesVideoID = targetVideoIDs.contains { needle in
	            guard !needle.isEmpty else { return false }
	            return matchedVideoID?.lowercased() == needle
	                || lowerKey.contains(needle)
	                || lowerDecoded.contains(needle)
	                || lowerURL.contains(needle)
	        }
	        guard matchesAweme || matchesVideoID else { return nil }

	        let bitRate = Int(queryValue("br") ?? "") ?? 0
	        let byteRate = Int(queryValue("bt") ?? "") ?? 0
	        let dataSize = Int(queryValue("size") ?? "") ?? Int(queryValue("content_size") ?? "") ?? 0
	        let width = seedInfo.width ?? 0
	        let height = seedInfo.height ?? 0
	        let fps = seedInfo.fps ?? 0
	        let dimensionSource = width > 0 && height > 0 ? "seed \(width)x\(height)" : "unknown"
	        var score = Int64(max(width * height, 0)) * 1_000
	        score += Int64(max(bitRate, byteRate)) * 1_000_000
	        score += Int64(dataSize) * 10
	        if fps >= 55 { score += 60_000_000 }
	        else if fps >= 45 { score += 30_000_000 }
	        score += Int64(fps) * 100_000_000
	        score += Int64(fileSize)
	        if matchesAweme { score += 10_000_000_000 }
	        if matchesVideoID { score += 5_000_000_000 }
	        if url.host?.lowercased().contains("-web.") == true { score += 100_000_000 }
	        if lowerURL.contains("media-audio") || lowerURL.contains("mime_type=audio") {
	            score -= 20_000_000_000
	        }
	        if lowerURL.contains("media-video") {
	            score += 1_000_000_000
	        }
	        if lowerURL.contains("hvc1") || lowerURL.contains("bvc2") {
	            score += 500_000_000
	        }
	        return DouyinDirectMediaCandidate(
	            url: url,
	            cacheFile: cacheFile,
	            score: score,
	            bitRate: bitRate,
	            byteRate: byteRate,
	            dataSize: dataSize,
	            fps: fps,
	            matchedAwemeID: matchedAwemeID,
	            matchedVideoID: matchedVideoID,
	            width: width,
	            height: height,
	            dimensionSource: dimensionSource
	        )
	    }

	    private static func directMediaURL(from entry: DouyinCacheEntry) -> URL? {
        var text = entry.originalKey
        if text.hasPrefix("1/0/") {
            text.removeFirst(4)
        }
        guard let url = URL(string: text), isDirectDouyinVideoURL(url) else { return nil }
        let lower = text.lowercased()
        guard lower.contains("mime_type=video_mp4") || lower.contains(".mp4") || lower.contains("/video/") || lower.contains("media-video") else {
            return nil
        }
        return url
    }

    private static func isDirectMediaCacheEntry(_ entry: DouyinCacheEntry) -> Bool {
        directMediaURL(from: entry) != nil
    }

    private static func isReachableDirectMediaURL(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        request.assumesHTTP3Capable = false
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        do {
            let (_, response) = try await networkSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            guard (200..<400).contains(httpResponse.statusCode) else {
                throw NSError(domain: "DouyinDownloader", code: httpResponse.statusCode)
            }
            return true
        } catch {
            guard (error as NSError).code == 405 || DownloaderHTTPCompatibility.shouldFallback(after: error, for: request) else {
                if debugEnabled { print("[DouyinDebug] direct media HEAD failed: \(error.localizedDescription)") }
                return false
            }
            do {
                var fallbackRequest = request
                fallbackRequest.httpMethod = "GET"
                fallbackRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                _ = try await DownloaderHTTPCompatibility.dataAsync(for: fallbackRequest, readsBody: false)
                return true
            } catch {
                if debugEnabled { print("[DouyinDebug] direct media HEAD fallback failed: \(error.localizedDescription)") }
                return false
            }
        }
    }

    private static func cachedDesktopAweme(awemeID: String, description: String?, videoIDs: [String] = [], progress: DownloaderInfra.ProgressHandler? = nil) async -> AwemeInfo? {
        guard let electronURL = douyinElectronURL() else {
            if debugEnabled { print("[DouyinDebug] desktop cache: Douyin Electron executable not found") }
            return nil
        }
		let fileStages = douyinCacheFileStages(matching: awemeID, description: description, videoIDs: videoIDs) { fraction in
            Task { @Sendable in await progress?(min(max(fraction, 0), 1) * 0.12) }
        }
        if let progress { await progress(0.12) }
        guard !fileStages.stages.isEmpty else {
            if debugEnabled { print("[DouyinDebug] desktop cache: no matching cache entries") }
            return nil
        }
        if debugEnabled { print("[DouyinDebug] desktop cache: inspecting \(fileStages.totalCandidateCount) matching entries") }

        let script = """
        const fs = require("fs");
        const zlib = require("zlib");
        const args = process.argv.slice(1);
        const debug = process.env.HERMES_DEBUG === "1";
        const outputPath = process.env.HERMES_DOUYIN_CACHE_OUTPUT || "";
        const stopPath = process.env.HERMES_DOUYIN_CACHE_STOP || "";
        const workerPriority = Number.parseInt(process.env.HERMES_DOUYIN_CACHE_PRIORITY || "0", 10);
        const targets = args.filter(function(arg) { return /^\\d{16,20}$/.test(arg) || /^v[a-zA-Z0-9_-]{8,}$/.test(arg); });
        const cachePaths = args.filter(function(arg) {
          try { return targets.indexOf(arg) < 0 && arg.endsWith("_0") && fs.existsSync(arg) && fs.statSync(arg).isFile(); } catch(e) { return false; }
        });
        if (debug) console.error("targets=" + JSON.stringify(targets) + " cachePaths=" + cachePaths.length);
        function shouldStop() {
          if (!stopPath) return false;
          try {
            if (!fs.existsSync(stopPath)) return false;
            const winnerPriority = Number.parseInt(fs.readFileSync(stopPath, "utf8"), 10);
            return Number.isFinite(winnerPriority) && winnerPriority <= workerPriority;
          } catch(e) {
            return false;
          }
        }
        function looksLikeAweme(value) {
          return !!(value && typeof value === "object" &&
            (value.aweme_id || value.group_id || value.group_id_str || value.comment_gid || value.item_id) &&
            (value.images || value.image_list || value.image_infos || value.video));
        }
        function targetMatches(value) {
          if (!value || typeof value !== "object") return false;
          const ids = [value.aweme_id, value.group_id, value.group_id_str, value.comment_gid, value.item_id].filter(Boolean).map(String);
          if (ids.some(function(id) { return targets.indexOf(id) >= 0; })) return true;
          if (value.video) {
            const serialized = JSON.stringify(value);
            return targets.some(function(item) { return serialized.indexOf(item) >= 0; });
          }
          return false;
        }
        function find(value) {
          if (!value || typeof value !== "object") return null;
          if (looksLikeAweme(value) && targetMatches(value)) return value;
          if (Array.isArray(value)) {
            for (var i = 0; i < value.length; i++) { var found = find(value[i]); if (found) return found; }
          } else if (typeof value === "object") {
            var keys = Object.keys(value);
            for (var i = 0; i < keys.length; i++) { var found = find(value[keys[i]]); if (found) return found; }
          }
          return null;
        }
        function chunks(data) {
          const values = [];
          let offset = 0;
          while (offset < data.length) {
            const end = data.indexOf("\\r\\n", offset);
            if (end < 0) break;
            const size = Number.parseInt(data.subarray(offset, end).toString(), 16);
            if (!Number.isFinite(size) || size <= 0 || end + 2 + size > data.length) break;
            offset = end + 2;
            values.push(data.subarray(offset, offset + size));
            offset += size;
            if (data.subarray(offset, offset + 2).toString() === "\\r\\n") offset += 2;
          }
          return values.length ? values : [data];
        }
        for (var i = 0; i < cachePaths.length; i++) {
          if (shouldStop()) process.exit(2);
          var path = cachePaths[i];
          try {
            var cache = fs.readFileSync(path);
            if (cache.length < 24) continue;
            var bodyOffset = 24 + cache.readUInt32LE(12);
            if (bodyOffset >= cache.length) continue;
            var body;
            try {
              body = zlib.brotliDecompressSync(cache.subarray(bodyOffset));
            } catch(e) {
              // Body may be in companion *_1 file (Chromium simple cache splits large
              // responses: *_0 = headers, *_1 = brotli-compressed body).
              var path1 = path.replace(/_0$/, "_1");
              if (path1 !== path && fs.existsSync(path1)) {
                try {
                  var cache1 = fs.readFileSync(path1);
                  // *_1 file has an 8-byte SimpleFileHeader prefix; skip it.
                  body = zlib.brotliDecompressSync(cache1.subarray(8));
                  if (debug) console.error("read body from " + path1 + " bytes=" + body.length);
                } catch(e2) {
                  // Try uncompressed *_1 body as last resort.
                  try {
                    body = cache1.subarray(8);
                    if (debug) console.error("read uncompressed body from " + path1 + " bytes=" + body.length);
                  } catch(e3) {
                    console.error("cache failed " + path + ": " + e.message + " (_1 also failed: " + e2.message + ")");
                    continue;
                  }
                }
              } else {
                console.error("cache failed " + path + ": " + e.message + " (no _1 companion)");
                continue;
              }
            }
            var chunksList = chunks(body);
            var chunkMatched = false;
            for (var j = 0; j < chunksList.length; j++) {
              if (shouldStop()) process.exit(2);
              try {
                var text = chunksList[j].toString();
                if (!targets.some(function(item) { return text.indexOf(item) >= 0; })) continue;
                chunkMatched = true;
                var found = find(JSON.parse(text));
                if (debug) console.error("target text in " + path + " chunk=" + j + " found=" + !!found + " bytes=" + text.length);
                if (found) {
                  const json = JSON.stringify(found);
                  if (outputPath) {
                    fs.writeFileSync(outputPath, json);
                    process.stdout.write("OK");
                  } else {
                    process.stdout.write(json);
                  }
                  process.exit(0);
                }
              } catch(e) { console.error("parse failed in " + path + ": " + e.message); }
            }
            if (debug && chunkMatched) console.error("targets matched text but find() returned null in " + path);
          } catch(e) { console.error("cache failed " + path + ": " + e.message); }
        }
        if (debug) console.error("scanned " + cachePaths.length + " cache files, targets=" + JSON.stringify(targets) + ", no hit");
        process.exit(1);
        """

        let totalFiles = fileStages.totalCandidateCount
        var cumulativeProcessed = 0
        for cacheFiles in fileStages.stages {
            let stageOffset = cumulativeProcessed
            let stageFileCount = cacheFiles.count
            let stageProgress: DownloaderInfra.ProgressHandler?
            if let prog = progress {
                stageProgress = { fraction in
                    let globalFraction = Double(stageOffset) / Double(totalFiles)
                        + fraction * Double(stageFileCount) / Double(totalFiles)
                    await prog(0.12 + min(globalFraction, 1) * 0.88)
                }
            } else {
                stageProgress = nil
            }
            guard let data = await cachedDesktopAwemeDataParallel(in: cacheFiles, electronURL: electronURL, script: script, awemeID: awemeID, videoIDs: videoIDs, progress: stageProgress) else {
                cumulativeProcessed += cacheFiles.count
                if let prog = progress {
                    let fraction = min(Double(cumulativeProcessed) / Double(totalFiles), 1)
                    await prog(0.12 + fraction * 0.88)
                }
                continue
            }
            guard let aweme = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return parseAweme(aweme)
        }
        return nil
    }

    private static func cachedDesktopAwemeDataParallel(in cacheFiles: [URL], electronURL: URL, script: String, awemeID: String, videoIDs: [String], progress: DownloaderInfra.ProgressHandler? = nil) async -> Data? {
        let totalCount = cacheFiles.count
        let fastPathCount = min(cacheFiles.count, max(12, maxDouyinCacheWorkers * 4))
        if fastPathCount > 0 {
            let fastPathFiles = Array(cacheFiles.prefix(fastPathCount))
            if let data = cachedDesktopAwemeData(in: fastPathFiles, electronURL: electronURL, script: script, awemeID: awemeID, videoIDs: videoIDs) {
                if let progress {
                    await progress(min(Double(fastPathCount) / Double(totalCount), 1))
                }
                return data
            }
            if let progress {
                await progress(min(Double(fastPathCount) / Double(totalCount), 1))
            }
            if fastPathCount == cacheFiles.count {
                return nil
            }
        }

        let workerCount = min(maxDouyinCacheWorkers, cacheFiles.count)
        let filesPerWorker = max(1, min(32, Int(ceil(Double(cacheFiles.count) / Double(workerCount)))))
        var start = fastPathCount
        var batchIndex = 0
        while start < cacheFiles.count {
            let batchEnd = min(start + workerCount * filesPerWorker, cacheFiles.count)
            let resultBox = DouyinAwemeDataBox()
            let stopURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("hermes-douyin-cache-stop-\(UUID().uuidString)")
            let group = DispatchGroup()
            var offset = 0
            var chunkStart = start
            while chunkStart < batchEnd {
                let chunkEnd = min(chunkStart + filesPerWorker, batchEnd)
                let files = Array(cacheFiles[chunkStart..<chunkEnd])
                let priority = offset
                offset += 1
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    guard !resultBox.hasWinner(atOrBefore: priority) else { return }
                    if let data = cachedDesktopAwemeData(in: files, electronURL: electronURL, script: script, awemeID: awemeID, videoIDs: videoIDs, cancellationURL: stopURL, priority: priority) {
                        if resultBox.set(data, priority: priority) {
                            writeDouyinCacheStop(priority: priority, to: stopURL)
                        }
                    }
                }
                chunkStart = chunkEnd
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    group.wait()
                    continuation.resume()
                }
            }
            if let prog = progress {
                let fraction = min(Double(batchEnd) / Double(totalCount), 1)
                await prog(fraction)
            }
            try? FileManager.default.removeItem(at: stopURL)
            if let data = resultBox.bestData {
                return data
            }
            start = batchEnd
            batchIndex += 1
        }
        return nil
    }

    private static func writeDouyinCacheStop(priority: Int, to url: URL) {
        try? String(priority).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func cachedDesktopAwemeData(in cacheFiles: [URL], electronURL: URL, script: String, awemeID: String, videoIDs: [String], cancellationURL: URL? = nil, priority: Int = 0) -> Data? {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-douyin-cache-\(UUID().uuidString).js")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-douyin-cache-\(UUID().uuidString).json")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            if debugEnabled { print("[DouyinDebug] desktop cache script: \(error.localizedDescription)") }
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        environment["HERMES_DOUYIN_CACHE_OUTPUT"] = outputURL.path
        if let cancellationURL {
            environment["HERMES_DOUYIN_CACHE_STOP"] = cancellationURL.path
            environment["HERMES_DOUYIN_CACHE_PRIORITY"] = String(priority)
        }
        do {
            let captured = try SubprocessRunner.run(
                executable: electronURL,
                arguments: [scriptURL.path, awemeID] + videoIDs + cacheFiles.map(\.path),
                environment: environment,
                timeout: 45
            )
            let data = captured.stdout
            let errorData = captured.stderr
            guard captured.status == 0 else {
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                let stderrPreview = stderr.prefix(1000)
                if debugEnabled {
                    print("[DouyinDebug] desktop cache script exit=\(captured.status) files=\(cacheFiles.count) stdout=\(data.count) stderr=\(stderrPreview)")
                }
                return nil
            }
            let resultData = (try? Data(contentsOf: outputURL)) ?? data
            if debugEnabled {
                let stderr = String(data: errorData, encoding: .utf8) ?? ""
                print("[DouyinDebug] desktop cache script hit files=\(cacheFiles.count) stdout=\(data.count) result=\(resultData.count) stderr=\(stderr.prefix(1000))")
            }
            return resultData
        } catch {
            if debugEnabled { print("[DouyinDebug] desktop cache: \(error.localizedDescription)") }
            return nil
        }
    }

	    /// Use Electron to make a live HTTPS request to the Douyin web API.
	    /// Uses desktop-identifying parameters and User-Agent that may cause the
	    /// API to return richer data (including Live Photo video URLs) compared
	    /// to the mobile-identified URLSession path.
	    /// Retries with an alternative configuration on PARSE_ERROR / NET_ERROR / TIMEOUT.
	    private static func liveDesktopAweme(awemeID: String, electronURL: URL, progress: DownloaderInfra.ProgressHandler? = nil) async -> AwemeInfo? {
	        // Two configurations: primary (pc_client_type=3, Chrome UA) and fallback (pc_client_type=1, Safari UA).
	        let configs: [(label: String, url: String, userAgent: String)] = [
	            ("primary", "https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=\(awemeID)&aid=6383&device_platform=webapp&version_code=170400&version_name=17.4.0&pc_client_type=3&pc_libra_divert=Mac&support_h265=1&support_dash=1", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.7103.59 Safari/537.36"),
	            ("fallback", "https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=\(awemeID)&aid=6383&device_platform=webapp&version_code=170400&version_name=17.4.0&pc_client_type=1&pc_libra_divert=Mac&support_h265=1&support_dash=1", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15")
	        ]
	        let totalAttempts = configs.count
	        for (attemptIndex, config) in configs.enumerated() {
	            let configProgress = Double(attemptIndex) / Double(totalAttempts)
	            if let progress { await progress(configProgress) }
	            if debugEnabled { print("[DouyinDebug] liveDesktopAweme: trying \(config.label) config") }
	            let script = """
	        const https = require("https");
	        const target = process.argv[1];
	        const url = "\(config.url)";
	        const options = {
	          headers: {
	            "User-Agent": "\(config.userAgent)",
	            "Referer": "https://www.douyin.com/",
	            "Accept": "application/json"
	          },
	          timeout: 15000
	        };
	        https.get(url, options, function(res) {
	          var body = "";
	          res.on("data", function(chunk) { body += chunk; });
	          res.on("end", function() {
	            try {
	              var data = JSON.parse(body);
	              var aweme = data.aweme_detail;
	              if (aweme) {
	                process.stdout.write(JSON.stringify(aweme));
	              } else {
	                process.stdout.write("NO_AWEME");
	              }
	            } catch(e) {
	              process.stdout.write("PARSE_ERROR:" + body.substring(0, 500));
	            }
	            process.exit(0);
	          });
	        }).on("error", function(e) {
	          process.stdout.write("NET_ERROR:" + e.message);
	          process.exit(1);
	        }).on("timeout", function() {
	          process.stdout.write("TIMEOUT");
	          process.exit(1);
	        });
	        """

	            do {
                    let captured = try await Task.detached(priority: .userInitiated) {
                        try SubprocessRunner.run(
                            executable: electronURL,
                            arguments: ["-e", script, awemeID],
                            environment: ["ELECTRON_RUN_AS_NODE": "1"],
                            timeout: 20
                        )
                    }.value
                    guard captured.status == 0 else { continue }
                    let output = String(data: captured.stdout, encoding: .utf8) ?? ""
	                if debugEnabled { print("[DouyinDebug] liveDesktopAweme[\(config.label)]: Electron output (\(output.count) chars): \(output.prefix(200))") }
	                if output.hasPrefix("PARSE_ERROR") {
	                    let bodyText = String(output.dropFirst("PARSE_ERROR:".count))
	                    if debugEnabled { print("[DouyinDebug] liveDesktopAweme[\(config.label)]: PARSE_ERROR body: \(bodyText.prefix(200))") }
	                    continue // try fallback config
	                }
	                if output.hasPrefix("NET_ERROR") {
	                    if debugEnabled { print("[DouyinDebug] liveDesktopAweme[\(config.label)]: NET_ERROR, trying fallback") }
	                    continue // try fallback config
	                }
	                if output.hasPrefix("TIMEOUT") {
	                    if debugEnabled { print("[DouyinDebug] liveDesktopAweme[\(config.label)]: TIMEOUT, trying fallback") }
	                    continue // try fallback config
	                }
	                guard !output.isEmpty,
	                      !output.hasPrefix("NO_AWEME"),
	                      let data = output.data(using: .utf8),
	                      let aweme = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
	                    return nil
	                }
	                return parseAweme(aweme)
	            } catch {
	                if debugEnabled { print("[DouyinDebug] liveDesktopAweme[\(config.label)]: Electron process error: \(error.localizedDescription)") }
	                continue // try fallback config
	            }
	        }
	        if let progress { await progress(1.0) }
	        return nil
	    }

    private static func douyinElectronURL() -> URL? {
        let appPaths = [
            "/Applications/抖音.app",
            NSHomeDirectory() + "/Applications/抖音.app"
        ]
        for appPath in appPaths {
            let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
            let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
            let executableName = (NSDictionary(contentsOf: infoURL)?["CFBundleExecutable"] as? String) ?? "抖音"
            let executableURL = appURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
                .appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: executableURL.path) {
                return executableURL
            }
        }
        return nil
    }

	private static func douyinCacheFileStages(
        matching awemeID: String,
        description: String?,
        videoIDs: [String] = [],
        progress: ((Double) -> Void)? = nil
    ) -> DouyinCacheFileStages {
		let descriptionNeedles = douyinCacheDescriptionNeedles(description)
		// Only apply time cutoff to description-based matches (speculative).
		// awemeID / videoID matches are always relevant regardless of age.
		let cutoff = Date().addingTimeInterval(-48 * 3600)
		var entries: [(url: URL, date: Date, priority: Int, size: Int)] = []
		var recentFallbackEntries: [(url: URL, date: Date, priority: Int, size: Int)] = []
		if debugEnabled {
			print("[DouyinDebug] douyinCacheFileStages: awemeID=\(awemeID) videoIDs=\(videoIDs) description=\(description?.prefix(40) ?? "nil")")
		}
		let totalEntries = douyinCacheIndex.entries(in: douyinCacheRootPaths, progress: progress)
		if debugEnabled {
			let matchingKeys = totalEntries.filter { entry in entry.key.contains(awemeID) || videoIDs.contains(where: { vid in entry.key.contains(vid) }) }
			print("[DouyinDebug] douyinCacheFileStages: total cache entries=\(totalEntries.count), awemeID matches=\(totalEntries.filter { $0.key.contains(awemeID) }.count), videoID matches=\(totalEntries.filter { entry in videoIDs.contains(where: { vid in entry.key.contains(vid) }) }.count), unique matching=\(matchingKeys.count)")
		}
		for entry in totalEntries {
            guard !isDirectMediaCacheEntry(entry) else { continue }
			let matchesID = entry.key.contains(awemeID) || videoIDs.contains(where: { entry.key.contains($0) })
			let matchesDescription = descriptionNeedles.contains {
				entry.decodedKey.contains($0) || entry.compactKey.contains($0)
			}
            if (entry.date >= cutoff || entry.priority == 1), entry.priority < Int.max {
                recentFallbackEntries.append((entry.url, entry.date, entry.priority, entry.size))
            }
            guard matchesID || matchesDescription else { continue }
            // awemeID matches are always relevant; description matches need recency.
            guard matchesID || entry.date >= cutoff else { continue }
            entries.append((entry.url, entry.date, entry.priority, entry.size))
        }
        if entries.isEmpty, !totalEntries.isEmpty {
            // No cache key matched — print sample keys for diagnosis.
            let sampleKeys = totalEntries.prefix(8).map { $0.key.prefix(120) }
            let needles: [String] = [awemeID] + videoIDs
            if debugEnabled {
                print("[DouyinDebug] douyinCacheFileStages: NO MATCH for needles \(needles) among \(totalEntries.count) cache entries. Sample keys:")
                for key in sampleKeys { print("[DouyinDebug]   \(key)") }
            }
        }
        // Sort: detail entries first, then by size descending, then by date.
        entries.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.size != rhs.size { return lhs.size > rhs.size }
            return lhs.date > rhs.date
        }
        recentFallbackEntries.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.size > rhs.size
        }

        let exactEntries = entries.prefix(4)
        var stages: [[URL]] = []
        var lastStagePaths = Set<String>()

        func appendStage(_ urls: [URL]) {
            var seen = Set<String>()
            let stage = urls.compactMap { url -> URL? in
                guard seen.insert(url.path).inserted else { return nil }
                return url
            }
            let stagePaths = Set(stage.map(\.path))
            guard !stage.isEmpty, stagePaths != lastStagePaths else { return }
            stages.append(stage)
            lastStagePaths = stagePaths
        }

        // When no cache key matches exactly, add a targeted body-scan stage from
        // recent rich JSON entries.  Douyin often stores the useful aweme object
        // inside aweme/favorite or feed response bodies whose cache key does not
        // include the current aweme ID.
        // These entries are most likely to contain aweme detail data in their
        // decompressed body even when the cache key doesn't include the aweme ID.
        if !recentFallbackEntries.isEmpty {
            let bodyScanLimit = entries.isEmpty ? 384 : 160
            let targetedEntries = recentFallbackEntries
                .filter { $0.priority <= 4 && $0.size >= 512 }
                .sorted { lhs, rhs in
                    if lhs.date != rhs.date { return lhs.date > rhs.date }
                    if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                    return lhs.size > rhs.size
                }
                .prefix(bodyScanLimit)
            if !targetedEntries.isEmpty {
                appendStage(targetedEntries.map(\.url))
                if debugEnabled {
                    print("[DouyinDebug] douyinCacheFileStages: added targeted body stage with \(targetedEntries.count) recent rich JSON entries")
                }
            }
        }

        let fallbackLimits = [64, 128, 256]
        for limit in fallbackLimits {
            var stage: [URL] = []
            var seen = Set<String>()
            for entry in exactEntries {
                if seen.insert(entry.url.path).inserted {
                    stage.append(entry.url)
                }
            }
            for entry in recentFallbackEntries.prefix(limit) {
                if seen.insert(entry.url.path).inserted {
                    stage.append(entry.url)
                }
            }
            appendStage(stage)
        }
        if stages.isEmpty, !entries.isEmpty {
            appendStage(entries.map(\.url))
        }
        return DouyinCacheFileStages(
            stages: stages,
            totalCandidateCount: max(stages.reduce(0) { $0 + $1.count }, stages.last?.count ?? 0)
        )
    }

    private static func douyinCacheEntry(for file: URL, modDate: Date, fileSize: Int) -> DouyinCacheEntry? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let header = handle.readData(ofLength: 24)
        guard header.count == 24 else { return nil }
        let keyLength = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }.littleEndian)
        guard keyLength > 0, keyLength < 16_384 else { return nil }

        let originalKey = String(decoding: handle.readData(ofLength: keyLength), as: UTF8.self)
        let key = originalKey.lowercased()
        let isUseless = key.contains("web_shorten")
            || key.contains("/danmaku/")
            || key.contains("danmaku/get")
        guard !isUseless else { return nil }

        let decodedKey = (key.removingPercentEncoding ?? key)
            .replacingOccurrences(of: "+", with: " ")
        let priority = douyinCachePriority(for: key)
        guard priority < Int.max else { return nil }
        return DouyinCacheEntry(
            url: file,
            date: modDate,
            priority: priority,
            size: fileSize,
            originalKey: originalKey,
            key: key,
            decodedKey: decodedKey,
            compactKey: compactDouyinCacheText(decodedKey)
        )
    }

	    private static func douyinCachePriority(for key: String) -> Int {
	        // Direct media CDN entries — indexed so cachedTimelineLivePhotoVideos
	        // can find motion videos near image cache entries.  They are skipped
	        // by douyinCacheFileStages so the Electron body scan stays lean.
	        if key.contains("douyinvod.com") && (key.contains("mime_type=video_mp4") || key.contains(".mp4") || key.contains("/video/")
	            || key.contains("media-video")) {
	            return 7
	        }
	        if key.contains("douyinpic.com") && key.contains("biz_tag=aweme_images") {
            return 6
        }
        if key.contains("aweme/detail") { return 0 }
        if key.contains("web/tab/feed") && key.contains("aweme/v1") { return 1 }
        if key.contains("history/read") && key.contains("aweme/v1") { return 1 }
        if key.contains("aweme/favorite") { return 2 }
        if key.contains("slidesinfo") { return 3 }
        if key.contains("/aweme/v1/feed") { return 4 }
        if key.contains("/share/video/") { return 5 }
        return Int.max
    }

    private static func douyinCacheDescriptionNeedles(_ description: String?) -> [String] {
        guard let description else { return [] }
        let normalized = description
            .replacingOccurrences(of: #"#.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return [] }

        var needles = [normalized]
        let compact = compactDouyinCacheText(normalized)
        if compact.count >= 8 {
            needles.append(String(compact.prefix(16)))
        }
        return Array(Set(needles))
    }

    private static func compactDouyinCacheText(_ value: String) -> String {
        let ignoredCharacters = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        return value.lowercased().unicodeScalars
            .filter { !ignoredCharacters.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func parseAwemeResponse(from url: URL, referer: URL, quickTimeout: Bool = false) async throws -> AwemeInfo? {
        let (data, _) = try await requestAsync(url, referer: referer, readsBody: true, quickTimeout: quickTimeout)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let aweme = (json["aweme_detail"] as? [String: Any])
            ?? ((json["aweme_details"] as? [[String: Any]])?.first)
            ?? ((json["item_list"] as? [[String: Any]])?.first)
        guard let aweme else { return nil }
        return parseAweme(aweme)
    }

    /// Parse the mobile feed API response (`aweme/v1/feed/`).
    /// The feed returns a list of awemes; we search for the one matching `targetAwemeID`.
    private static func parseMobileFeedResponse(from url: URL, targetAwemeID: String) async throws -> AwemeInfo? {
        var req = URLRequest(url: url)
        req.setValue("com.ss.android.ugc.aweme/170400 (Linux; U; Android 14; zh_CN; SM-S9080; Build/UP1A.231005.007; Cronet/TTNetVersion:01572e73 2024-06-19 QuicVersion:4660e50f 2024-06-19)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await requestAsync(url, referer: nil, readsBody: true, customRequest: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let awemeList = json["aweme_list"] as? [[String: Any]] else {
            return nil
        }
        guard let aweme = awemeList.first(where: { ($0["aweme_id"] as? String) == targetAwemeID }) else {
            return nil
        }
        return parseAweme(aweme)
    }

    static func parseAweme(_ aweme: [String: Any]) -> AwemeInfo {
        let author = aweme["author"] as? [String: Any] ?? [:]
        var info = AwemeInfo()
        info.awemeID = JSONValueUtilities.nonEmptyString(aweme["aweme_id"]) ?? JSONValueUtilities.nonEmptyString(aweme["group_id"]) ?? ""
        info.desc = JSONValueUtilities.nonEmptyString(aweme["desc"]) ?? JSONValueUtilities.nonEmptyString(aweme["caption"]) ?? ""
        info.author = JSONValueUtilities.nonEmptyString(author["nickname"]) ?? JSONValueUtilities.nonEmptyString(author["unique_id"]) ?? JSONValueUtilities.nonEmptyString(author["uid"]) ?? "unknown"
        info.authorID = JSONValueUtilities.nonEmptyString(author["unique_id"])
            ?? JSONValueUtilities.nonEmptyString(author["short_id"])
            ?? JSONValueUtilities.nonEmptyString(author["uid"])
            ?? JSONValueUtilities.nonEmptyString(author["sec_uid"])
            ?? ""

        let images = aweme["images"] as? [[String: Any]]
            ?? aweme["image_list"] as? [[String: Any]]
            ?? aweme["original_images"] as? [[String: Any]]
            ?? []
        // image_infos may contain per-image video data (Live Photo videos) that is
        // absent from the top-level images array, especially for aweme_type=2 posts.
        let imageInfos = aweme["image_infos"] as? [[String: Any]] ?? []
        let awemeLivePhotoVideos = livePhotoVideosInAweme(aweme, imageCount: max(images.count, imageInfos.count))
        var imageCandidates: [(index: Int, image: [String: Any], imageURL: URL, video: VideoSelection?)] = []
        for (offset, image) in images.enumerated() {
            guard let imageURL = bestImageURL(from: image) else { continue }
            var imageLevelVideo = bestLivePhotoVideo(from: image)
            // Supplement with video data from image_infos when the image dict lacks it.
            if imageLevelVideo == nil, offset < imageInfos.count {
                imageLevelVideo = bestLivePhotoVideo(from: imageInfos[offset])
            }
            let awemeLevelVideo = offset < awemeLivePhotoVideos.count ? awemeLivePhotoVideos[offset] : (images.count == 1 ? awemeLivePhotoVideos.first : nil)
            let bestVideo = imageLevelVideo ?? awemeLevelVideo
            if debugEnabled, imageLevelVideo == nil, awemeLevelVideo != nil {
                print("[DouyinDebug] Live Photo video attached from aweme-level fallback for image index \(offset + 1)")
            }
            imageCandidates.append((offset + 1, image, imageURL, bestVideo))
        }
        // If the top-level images array is empty, try image_infos as the primary source.
        if images.isEmpty, !imageInfos.isEmpty {
            for (offset, imageInfo) in imageInfos.enumerated() {
                guard let imageDict = imageInfo["image"] as? [String: Any],
                      let imageURL = bestImageURL(from: imageDict) else {
                    // Some image_infos entries carry video only; search the info dict
                    // for any usable video and pair it with whatever image we can find.
                    if let imageURL = bestImageURL(from: imageInfo),
                       let video = bestLivePhotoVideo(from: imageInfo) {
                        imageCandidates.append((offset + 1, imageInfo, imageURL, video))
                    }
                    continue
                }
                let imageLevelVideo = bestLivePhotoVideo(from: imageDict)
                    ?? bestLivePhotoVideo(from: imageInfo)
                let awemeLevelVideo = offset < awemeLivePhotoVideos.count ? awemeLivePhotoVideos[offset] : (imageInfos.count == 1 ? awemeLivePhotoVideos.first : nil)
                let bestVideo = imageLevelVideo ?? awemeLevelVideo
                imageCandidates.append((offset + 1, imageDict, imageURL, bestVideo))
            }
        }
        let metaWidth = JSONValueUtilities.intValue(aweme["width"])
        let metaHeight = JSONValueUtilities.intValue(aweme["height"])
        var bestByIndex: [Int: (image: [String: Any], imageURL: URL, video: VideoSelection?)] = [:]
        for candidate in imageCandidates {
            let score = imageURLScore(candidate.imageURL, metaWidth: JSONValueUtilities.intValue(candidate.image["width"]) != 0 ? JSONValueUtilities.intValue(candidate.image["width"]) : metaWidth, metaHeight: JSONValueUtilities.intValue(candidate.image["height"]) != 0 ? JSONValueUtilities.intValue(candidate.image["height"]) : metaHeight)
            if let existing = bestByIndex[candidate.index] {
                let existingScore = imageURLScore(existing.imageURL, metaWidth: JSONValueUtilities.intValue(existing.image["width"]) != 0 ? JSONValueUtilities.intValue(existing.image["width"]) : metaWidth, metaHeight: JSONValueUtilities.intValue(existing.image["height"]) != 0 ? JSONValueUtilities.intValue(existing.image["height"]) : metaHeight)
                if score <= existingScore { continue }
            }
            bestByIndex[candidate.index] = (candidate.image, candidate.imageURL, candidate.video)
        }
        for index in bestByIndex.keys.sorted() {
            guard let best = bestByIndex[index] else { continue }
            info.images.append(MediaItem(
                index: index,
                imageURL: best.imageURL,
                videoURL: best.video?.url,
                sourceMarkedHDR: best.video?.sourceMarkedHDR ?? false,
                streamMarkedHDR: best.video?.streamMarkedHDR ?? false,
                width: JSONValueUtilities.intValue(best.image["width"]),
                height: JSONValueUtilities.intValue(best.image["height"]),
                videoWidth: best.video?.width ?? 0,
                videoHeight: best.video?.height ?? 0
            ))
        }
        if images.isEmpty,
           let video = aweme["video"] as? [String: Any],
           let bestVideo = bestVideoURL(from: video) {
            info.sourceVideoID = ["play_addr", "play_addr_h264", "play_addr_265", "download_addr"]
                .compactMap { (video[$0] as? [String: Any])?["uri"] as? String }
                .first { DouyinSourceResolver.sourceURL(videoID: $0) != nil }
            info.videos.append(VideoItem(
                index: 1,
                videoURL: bestVideo.url,
                sourceMarkedHDR: bestVideo.sourceMarkedHDR,
                streamMarkedHDR: bestVideo.streamMarkedHDR,
                width: bestVideo.width,
                height: bestVideo.height,
                alternateURLs: bestVideo.alternateURLs
            ))
        }
        return info
    }

    private static func imageDimensionHint(from urlText: String) -> (width: Int, height: Int, isOrigin: Bool, format: String) {
        let lowercased = urlText.lowercased()
        let isOrigin = lowercased.contains("~tplv-dy-origin")
            || lowercased.contains("/origin")
            || lowercased.contains("_origin")
        var width = 0
        var height = 0
        if let match = RegexUtilities.firstCapture(1, pattern: #"~tplv-dy-resize:(\d+):(\d+)"#, in: urlText),
           let w = Int(match) {
            width = w
        }
        if let match = RegexUtilities.firstCapture(2, pattern: #"~tplv-dy-resize:(\d+):(\d+)"#, in: urlText),
           let h = Int(match) {
            height = h
        }
        if width == 0 || height == 0,
           let match = RegexUtilities.firstCapture(1, pattern: #"~tplv-dy-water-v2:[^:]+:(\d+):(\d+)"#, in: urlText),
           let w = Int(match) {
            width = w
        }
        if height == 0,
           let match = RegexUtilities.firstCapture(2, pattern: #"~tplv-dy-water-v2:[^:]+:(\d+):(\d+)"#, in: urlText),
           let h = Int(match) {
            height = h
        }
        if width == 0,
           let match = RegexUtilities.firstCapture(1, pattern: #"~tplv-dy-resize-walign-adapt-aq:(\d+):"#, in: urlText),
           let w = Int(match) {
            width = w
        }
        if width == 0 || height == 0,
           let match = RegexUtilities.firstCapture(1, pattern: #"~tplv-dy-(?:resize|origin|aweme-images|water-v2|crop):(?:[^:]+:)?(\d+):(\d+)"#, in: urlText),
           let w = Int(match) {
            width = w
        }
        if height == 0,
           let match = RegexUtilities.firstCapture(2, pattern: #"~tplv-dy-(?:resize|origin|aweme-images|water-v2|crop):(?:[^:]+:)?(\d+):(\d+)"#, in: urlText),
           let h = Int(match) {
            height = h
        }
        for param in ["width", "w"] {
            if width == 0, let value = RegexUtilities.firstCapture(1, pattern: "(?i)[?&]\(param)=(\\d+)", in: urlText), let w = Int(value) {
                width = w
            }
        }
        for param in ["height", "h"] {
            if height == 0, let value = RegexUtilities.firstCapture(1, pattern: "(?i)[?&]\(param)=(\\d+)", in: urlText), let h = Int(value) {
                height = h
            }
        }
        let format: String = {
            if lowercased.hasSuffix(".jpeg") || lowercased.contains(".jpeg?") || lowercased.contains(".jpeg&") { return "jpeg" }
            if lowercased.hasSuffix(".jpg") || lowercased.contains(".jpg?") || lowercased.contains(".jpg&") { return "jpg" }
            if lowercased.hasSuffix(".webp") || lowercased.contains(".webp?") || lowercased.contains(".webp&") { return "webp" }
            if lowercased.hasSuffix(".heic") || lowercased.contains(".heic?") || lowercased.contains(".heic&") { return "heic" }
            if lowercased.hasSuffix(".png") || lowercased.contains(".png?") || lowercased.contains(".png&") { return "png" }
            if lowercased.hasSuffix(".avif") || lowercased.contains(".avif?") || lowercased.contains(".avif&") { return "avif" }
            return ""
        }()
        return (width, height, isOrigin, format)
    }

    private static func imageURLScore(_ url: URL, metaWidth: Int, metaHeight: Int) -> Int64 {
        let hint = imageDimensionHint(from: url.absoluteString)
        let width = hint.width != 0 ? hint.width : metaWidth
        let height = hint.height != 0 ? hint.height : metaHeight
        let text = url.absoluteString.lowercased()
        var score = Int64(width * height) * 1_000
        if hint.isOrigin {
            score += 100_000_000
        }
        switch hint.format {
        case "jpeg", "jpg":
            score += 50_000_000
        case "heic":
            score += 30_000_000
        case "webp":
            score += 10_000_000
        case "png":
            score += 5_000_000
        default:
            break
        }
        if text.contains("p3-sign") || text.contains("p9-sign") || text.contains("p26-sign")
            || text.contains("douyinpic.com") {
            score += 1_000_000
        }
        if text.contains("thumb") || text.contains("thumbnail") || text.contains("small")
            || text.contains("preview") || text.contains("cover") {
            score -= 50_000_000
        }
        if text.contains("water-v2") || text.contains("watermark=1") {
            score -= 200_000_000
        }
        return score
    }

    private static func bestImageURL(from image: [String: Any]) -> URL? {
        let metaWidth = JSONValueUtilities.intValue(image["width"])
        let metaHeight = JSONValueUtilities.intValue(image["height"])
        var candidates: [(score: Int64, url: URL)] = []
        let urlList = (image["url_list"] as? [String] ?? [])
            .filter { !$0.contains("water-v2") }
        let downloadList = image["download_url_list"] as? [String] ?? []
        let allRaw = urlList.isEmpty ? downloadList : urlList
        var seen = Set<String>()
        for raw in allRaw {
            let formatted = MediaFileUtilities.formatURL(raw)
            guard !formatted.isEmpty, seen.insert(formatted).inserted,
                  let url = URL(string: formatted) else { continue }
            let score = imageURLScore(url, metaWidth: metaWidth, metaHeight: metaHeight)
            candidates.append((score, url))
        }
        if candidates.isEmpty {
            return nil
        }
        return candidates.max { $0.score < $1.score }?.url
    }

    private static func livePhotoVideosInAweme(_ aweme: [String: Any], imageCount: Int) -> [VideoSelection] {
        // Only a single-image work has an unambiguous top-level video pairing.
        // Flattening nested videos shifts indices when a mixed album omits a motion.
        guard imageCount == 1,
              let video = aweme["video"] as? [String: Any],
              let selection = bestVideoURL(from: video),
              isLikelyDouyinVideoPlaybackURL(selection.url) else { return [] }
        return [selection]
    }

    private static func livePhotoVideoScore(_ url: URL) -> Int {
        guard isLikelyDouyinVideoPlaybackURL(url) else { return Int.min }
        let text = url.absoluteString.lowercased()
        var score = 0
        if isDirectDouyinVideoURL(url) { score += 1000 }
        if text.contains("/aweme/v1/play") { score += 800 }
        if text.contains("douyinvod.com") { score += 700 }
        if text.contains("live") { score += 300 }
        if text.contains("motion") { score += 250 }
        if text.contains("photo") { score += 150 }
        if text.contains(".mp4") { score += 120 }
        if text.contains(".mov") { score += 100 }
        if text.contains("cover") || text.contains("thumb") || text.contains("preview") { score -= 500 }
        if text.contains("watermark=1") || text.contains("playwm") { score -= 300 }
        return score
    }

    private static func bestVideoURL(from video: [String: Any]) -> VideoSelection? {
        var candidates: [(score: Int64, selection: VideoSelection)] = []
        if let bitRates = video["bit_rate"] as? [[String: Any]] {
            for item in bitRates {
                if let playAddr = item["play_addr"] as? [String: Any] {
                    candidates.append(contentsOf: videoCandidates(from: playAddr, meta: item, inheritedMeta: video))
                }
                if item["url_list"] != nil {
                    candidates.append(contentsOf: videoCandidates(from: item, meta: item, inheritedMeta: video))
                }
            }
        }
        let playAddrKeys = [
            "play_addr_h264", "play_addr", "play_addr_bytevc1", "play_addr_265", "play_addr_lowbr",
            "play_addr_h265", "play_addr_266", "play_addr_av1", "play_addr_origin",
            "play_addr_uhdr", "play_addr_hdr", "play_addr_origin_hdr",
            "download_addr"
        ]
        for key in playAddrKeys {
            if let playAddr = video[key] as? [String: Any] {
                candidates.append(contentsOf: videoCandidates(from: playAddr, meta: video, inheritedMeta: nil))
            }
        }
        if candidates.isEmpty {
            candidates = nestedVideoCandidates(in: video, meta: video, inheritedMeta: nil)
        }
        if candidates.isEmpty {
            let fallbackWidth = JSONValueUtilities.intValue(video["width"])
            let fallbackHeight = JSONValueUtilities.intValue(video["height"])
            let urls = douyinVideoURLsInStrings(video, width: fallbackWidth, height: fallbackHeight)
            if let firstURL = urls.first {
                candidates = [(0, VideoSelection(
                    url: firstURL, width: fallbackWidth, height: fallbackHeight,
                    sourceMarkedHDR: false, streamMarkedHDR: false
                ))]
            }
        }
        if debugEnabled {
            if candidates.isEmpty {
                print("[DouyinDebug] bestVideoURL: no candidates in video dict keys \(video.keys)")
            } else {
                for (i, candidate) in candidates.enumerated() {
                    print("[DouyinDebug] bestVideoURL candidate[\(i)]: score=\(candidate.score), url=\(candidate.selection.url.absoluteString), size=\(candidate.selection.width)x\(candidate.selection.height)")
                }
                if let best = candidates.max(by: { $0.score < $1.score }) {
                    print("[DouyinDebug] bestVideoURL selected: score=\(best.score), url=\(best.selection.url.absoluteString)")
                }
            }
        }
        return candidates.max { $0.score < $1.score }?.selection
    }

    private static func nestedVideoCandidates(in value: Any, meta: [String: Any], inheritedMeta: [String: Any]?, depth: Int = 0) -> [(score: Int64, selection: VideoSelection)] {
        guard depth <= 8 else { return [] }
        if let values = value as? [Any] {
            return values.flatMap { nestedVideoCandidates(in: $0, meta: meta, inheritedMeta: inheritedMeta, depth: depth + 1) }
        }
        guard let dictionary = value as? [String: Any] else { return [] }
        var candidates: [(score: Int64, selection: VideoSelection)] = []
        if dictionary["url_list"] != nil {
            candidates.append(contentsOf: videoCandidates(from: dictionary, meta: dictionary, inheritedMeta: inheritedMeta))
        }
        let playAddrKeys = [
            "play_addr_h264", "play_addr", "play_addr_bytevc1", "play_addr_265", "play_addr_lowbr",
            "play_addr_h265", "play_addr_266", "play_addr_av1", "play_addr_origin",
            "play_addr_uhdr", "play_addr_hdr", "play_addr_origin_hdr",
            "download_addr"
        ]
        for key in playAddrKeys {
            if let playAddr = dictionary[key] as? [String: Any] {
                candidates.append(contentsOf: videoCandidates(from: playAddr, meta: dictionary, inheritedMeta: inheritedMeta))
            }
        }
        if let bitRates = dictionary["bit_rate"] as? [[String: Any]] {
            for item in bitRates {
                if let playAddr = item["play_addr"] as? [String: Any] {
                    candidates.append(contentsOf: videoCandidates(from: playAddr, meta: item, inheritedMeta: inheritedMeta ?? dictionary))
                }
                if item["url_list"] != nil {
                    candidates.append(contentsOf: videoCandidates(from: item, meta: item, inheritedMeta: inheritedMeta ?? dictionary))
                }
            }
        }
        for nestedValue in dictionary.values {
            candidates.append(contentsOf: nestedVideoCandidates(in: nestedValue, meta: dictionary, inheritedMeta: inheritedMeta, depth: depth + 1))
        }
        return candidates
    }

    private static func douyinVideoURLsInStrings(_ value: Any, width: Int, height: Int, depth: Int = 0) -> [URL] {
        guard depth <= 8 else { return [] }
        if let text = value as? String {
            let urls = videoURLsInText(text).filter { url in
                let lowercased = url.absoluteString.lowercased()
                return lowercased.contains("douyinvod.com")
                    || lowercased.contains("douyin.com/aweme/v1/play")
                    || lowercased.contains("douyin.com/aweme/v1/playwm")
            }
            return urls.map { preferredDouyinPlaybackURL($0, width: width, height: height) }
        }
        if let values = value as? [Any] {
            return values.flatMap { douyinVideoURLsInStrings($0, width: width, height: height, depth: depth + 1) }
        }
        guard let dictionary = value as? [String: Any] else { return [] }
        return dictionary.values.flatMap { douyinVideoURLsInStrings($0, width: width, height: height, depth: depth + 1) }
    }

    private static func isImageCDNURL(_ url: URL) -> Bool {
        let text = url.absoluteString.lowercased()
        let path = url.path.lowercased()
        if let host = url.host?.lowercased(), host.contains("douyinpic.com") {
            return true
        }
        let imageExtensions = [".webp", ".jpg", ".jpeg", ".png", ".heic", ".avif", ".gif"]
        if imageExtensions.contains(where: { path.hasSuffix($0) || text.contains("\($0)?") || text.contains("\($0)&") }) {
            return true
        }
        if text.contains("douyinpic.com") && text.contains("tplv-dy-") {
            return true
        }
        return false
    }

    private static func isUsableVideoURL(_ url: URL) -> Bool {
        guard !isImageCDNURL(url) else { return false }
        let text = url.absoluteString.lowercased()
        let decoded = (text.removingPercentEncoding ?? text)
            .replacingOccurrences(of: "\\/", with: "/")
        let rejectedMarkers = [
            ".mp3", ".m4a", ".aac", ".wav", ".flac", ".ogg",
            "/music/", "ies-music", "audio_id=", "music_id="
        ]
        return !rejectedMarkers.contains { decoded.contains($0) }
    }

    private static func isLikelyDouyinVideoPlaybackURL(_ url: URL) -> Bool {
        guard isUsableVideoURL(url) else { return false }
        let text = url.absoluteString.lowercased()
        let decoded = (text.removingPercentEncoding ?? text)
            .replacingOccurrences(of: "\\/", with: "/")
        let path = url.path.lowercased()
        let rejectedMarkers = [
            "logo_type=", "/logo/", "watermark=1",
            "mime_type=audio", "media-audio", "/audio/", "ies-music",
            "onsets", "beats", "beat_info", "music_info"
        ]
        guard !rejectedMarkers.contains(where: { decoded.contains($0) }) else {
            return false
        }
        if decoded.contains("mime_type=video_mp4") || decoded.contains("media-video") {
            return true
        }
        if isDirectDouyinVideoURL(url) {
            return true
        }
        if decoded.contains("/aweme/v1/play") {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let videoID = components.queryItems?.first(where: { $0.name == "video_id" })?.value {
                return isLikelyDouyinVideoID(videoID)
            }
            return true
        }
        if path.hasSuffix(".mp4") || text.contains(".mp4?") || text.contains(".mp4&") {
            return true
        }
        if path.hasSuffix(".mov") || text.contains(".mov?") || text.contains(".mov&") {
            return true
        }
        return false
    }

    private static func bestLivePhotoVideo(from image: [String: Any]) -> VideoSelection? {
        let videoKeys = [
            "video", "live_photo", "motion_video", "dynamic_cover", "live_photo_video",
            "image_video", "imageVideo", "live_video", "liveVideo",
            "animated_image", "animatedImage", "animation",
            "live_photo_url", "livePhotoUrl", "livePhotoURL",
            "motion", "motion_photo"
        ]
        for key in videoKeys {
            if let videoDict = image[key] as? [String: Any],
               let best = bestVideoURL(from: videoDict) {
                if debugEnabled {
                    print("[DouyinDebug] Live Photo video found via key '\(key)' (dict)")
                }
                return best
            }
            if let urlString = image[key] as? String,
               let url = URL(string: MediaFileUtilities.formatURL(urlString)) {
                let width = JSONValueUtilities.intValue(image["width"])
                let height = JSONValueUtilities.intValue(image["height"])
                if debugEnabled {
                    print("[DouyinDebug] Live Photo video found via key '\(key)' (string url: \(url))")
                }
                return VideoSelection(url: url, width: width, height: height, sourceMarkedHDR: false, streamMarkedHDR: false)
            }
        }
        let candidates = nestedVideoCandidates(in: image, meta: image, inheritedMeta: nil)
            .filter { isUsableVideoURL($0.selection.url) }
        if let best = candidates.max(by: { $0.score < $1.score })?.selection {
            if debugEnabled {
                print("[DouyinDebug] Live Photo video found via nested search")
            }
            return best
        }
        let width = JSONValueUtilities.intValue(image["width"])
        let height = JSONValueUtilities.intValue(image["height"])
        let urls = douyinVideoURLsInStrings(image, width: width, height: height)
        if let firstURL = urls.first {
            if debugEnabled {
                print("[DouyinDebug] Live Photo video found via URL fallback: \(firstURL)")
            }
            return VideoSelection(url: firstURL, width: width, height: height, sourceMarkedHDR: false, streamMarkedHDR: false)
        }
        let anyVideoURLs = anyVideoURLsInStrings(image)
        if let firstURL = preferredLivePhotoURL(from: anyVideoURLs) {
            if debugEnabled {
                print("[DouyinDebug] Live Photo video found via loose video URL fallback: \(firstURL)")
            }
            return VideoSelection(url: firstURL, width: width, height: height, sourceMarkedHDR: false, streamMarkedHDR: false)
        }
        if debugEnabled {
            print("[DouyinDebug] Live Photo video NOT found in image keys \(image.keys)")
        }
        return nil
    }

    private static func anyVideoURLsInStrings(_ value: Any, depth: Int = 0) -> [URL] {
        guard depth <= 10 else { return [] }
        if let text = value as? String {
            return videoURLsInText(text)
        }
        if let values = value as? [Any] {
            return values.flatMap { anyVideoURLsInStrings($0, depth: depth + 1) }
        }
        guard let dictionary = value as? [String: Any] else { return [] }
        return dictionary.values.flatMap { anyVideoURLsInStrings($0, depth: depth + 1) }
    }

    private static func videoURLsInText(_ text: String) -> [URL] {
        let decoded = MediaFileUtilities.formatURL(text)
            .replacingOccurrences(of: "&amp;", with: "&")
        let percentDecoded = decoded.removingPercentEncoding ?? decoded
        let normalizedValues = [
            decoded,
            percentDecoded,
            percentDecoded.replacingOccurrences(of: "\\/", with: "/")
        ]
        var urls: [URL] = []
        var seen = Set<String>()
        let pattern = #"https?:\\?/\\?/(?:[^\s\"'<>\\]|\\/)+"#
        for value in normalizedValues {
            for rawMatch in RegexUtilities.allMatches(pattern, in: value) {
                let cleaned = MediaFileUtilities.trimURLPunctuation(MediaFileUtilities.formatURL(rawMatch))
                    .replacingOccurrences(of: "\\/", with: "/")
                guard let url = URL(string: cleaned) else { continue }
                guard isLikelyDouyinVideoPlaybackURL(url) else { continue }
                guard !isImageCDNURL(url), seen.insert(url.absoluteString).inserted else { continue }
                urls.append(url)
            }
        }
        if urls.isEmpty,
           let url = URL(string: decoded),
           isLikelyDouyinVideoPlaybackURL(url) {
            urls.append(url)
        }
        return urls
    }

    private static func preferredLivePhotoURL(from urls: [URL]) -> URL? {
        let filtered = urls.filter(isLikelyDouyinVideoPlaybackURL)
        return filtered.first { isDirectDouyinVideoURL($0) }
            ?? filtered.first { $0.absoluteString.lowercased().contains("/aweme/v1/play") }
            ?? filtered.first { $0.path.lowercased().contains(".mp4") }
            ?? filtered.first { $0.path.lowercased().contains(".mov") }
            ?? filtered.first
    }

    private static func orderedVideoURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }

    private static func videoCandidates(from playAddr: [String: Any], meta: [String: Any], inheritedMeta: [String: Any]?) -> [(score: Int64, selection: VideoSelection)] {
        let urls = playAddr["url_list"] as? [String] ?? []
        let width = JSONValueUtilities.intValue(playAddr["width"]) != 0
            ? JSONValueUtilities.intValue(playAddr["width"])
            : (JSONValueUtilities.intValue(meta["width"]) != 0 ? JSONValueUtilities.intValue(meta["width"]) : JSONValueUtilities.intValue(inheritedMeta?["width"]))
        let height = JSONValueUtilities.intValue(playAddr["height"]) != 0
            ? JSONValueUtilities.intValue(playAddr["height"])
            : (JSONValueUtilities.intValue(meta["height"]) != 0 ? JSONValueUtilities.intValue(meta["height"]) : JSONValueUtilities.intValue(inheritedMeta?["height"]))
        let dataSize = JSONValueUtilities.intValue(playAddr["data_size"])
        let bitRate = JSONValueUtilities.intValue(meta["bit_rate"])
        let fps = JSONValueUtilities.intValue(meta["FPS"]) != 0 ? JSONValueUtilities.intValue(meta["FPS"]) : JSONValueUtilities.intValue(meta["fps"])
        let format = (JSONValueUtilities.string(meta["format"]) ?? "").lowercased()
        let definition = (
            (JSONValueUtilities.string(meta["gear_name"]) ?? "") + " " +
            (JSONValueUtilities.string(meta["quality_type"]) ?? "") + " " +
            (JSONValueUtilities.string(meta["video_extra"]) ?? "")
        ).lowercased()
        var score = Int64(width * height) * 1_000_000_000
            + Int64(fps) * 100_000_000
            + Int64(bitRate) * 10_000
            + Int64(dataSize)
        if format == "mp4" {
            score += 10_000_000_000
        }
        if fps >= 55 {
            score += 6_000_000_000
        } else if fps >= 45 {
            score += 3_000_000_000
        }
        if definition.contains("4k") {
            score += 8_000_000_000
        } else if definition.contains("1440") {
            score += 4_000_000_000
        } else if definition.contains("1080") {
            score += 2_000_000_000
        }
        if JSONValueUtilities.boolValue(meta["is_h265"]) || JSONValueUtilities.boolValue(meta["is_bytevc1"]) {
            score += 1_000_000_000
        }
        let streamHDRText = [
            JSONValueUtilities.string(meta["HDR_bit"]) ?? "",
            JSONValueUtilities.string(meta["HDR_type"]) ?? "",
            JSONValueUtilities.string(meta["hdr_bit"]) ?? "",
            JSONValueUtilities.string(meta["hdr_type"]) ?? "",
            JSONValueUtilities.string(meta["video_extra"]) ?? ""
        ].joined(separator: " ").lowercased()
        let inheritedHDRText = [
            JSONValueUtilities.string(inheritedMeta?["HDR_bit"]) ?? "",
            JSONValueUtilities.string(inheritedMeta?["HDR_type"]) ?? "",
            JSONValueUtilities.string(inheritedMeta?["hdr_bit"]) ?? "",
            JSONValueUtilities.string(inheritedMeta?["hdr_type"]) ?? "",
            JSONValueUtilities.string(inheritedMeta?["video_extra"]) ?? ""
        ].joined(separator: " ").lowercased()
        let combinedHDRText = "\(streamHDRText) \(inheritedHDRText)"
        let streamMarkedHDR = isHDRText(streamHDRText)
        let sourceMarkedHDR = streamMarkedHDR
            || isHDRText(inheritedHDRText)
            || JSONValueUtilities.boolValue(meta["is_source_HDR"])
            || JSONValueUtilities.boolValue(inheritedMeta?["is_source_HDR"])
        if combinedHDRText.contains("dolby") || combinedHDRText.contains("dovi") || combinedHDRText.contains("dvhe") {
            score += 3_000_000_000
        } else if isHDRText(combinedHDRText) {
            score += 2_000_000_000
        }
        if sourceMarkedHDR {
            score += 500_000_000
        }
        let parsedURLs = urls.compactMap { value -> URL? in
            guard let url = URL(string: MediaFileUtilities.formatURL(value)) else {
                return nil
            }
            let preferredURL = preferredDouyinPlaybackURL(url, width: width, height: height)
            return isLikelyDouyinVideoPlaybackURL(preferredURL) ? preferredURL : nil
        }
        let preferred = parsedURLs.first { $0.host?.contains("douyin.com") == true && $0.path.contains("/aweme/v1/play") }
            ?? parsedURLs.first { isDirectDouyinVideoURL($0) }
            ?? parsedURLs.first
        guard let preferred else { return [] }
        var finalScore = score
        // Play URLs (aweme/v1/play) redirect to CDN's best quality for the
        // requested ratio.  When all bit_rate entries share the same inherited
        // resolution (e.g. 1440×2560 inherited from the video dict even though
        // each stream is 720p), boost the play URL so it can beat the 720p
        // CDN entries and deliver the resolution the seed data advertises.
        let preferredText = preferred.absoluteString.lowercased()
        if preferredText.contains("/aweme/v1/play") {
            finalScore += 6_000_000_000
        }
        return [(finalScore, VideoSelection(
            alternateURLs: orderedVideoURLs(parsedURLs + urls.compactMap { URL(string: MediaFileUtilities.formatURL($0)) }).filter { $0 != preferred },
            url: preferred,
            width: width,
            height: height,
            sourceMarkedHDR: sourceMarkedHDR,
            streamMarkedHDR: streamMarkedHDR
        ))]
    }

    static func preferredDouyinPlaybackURL(_ url: URL, width: Int, height: Int) -> URL {
        guard url.path.contains("/aweme/v1/play"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = parts.queryItems ?? []
        if items.contains(where: { ["signature", "x-signature", "a_bogus", "msToken"].contains($0.name) }) { return url }
        if items.contains(where: { ($0.name == "ratio" && $0.value == "default") || $0.name == "improve_bitrate" }) { return url }
        parts.path = parts.path.replacingOccurrences(of: "/playwm", with: "/play")
        // Resolution tiers use the short side for portrait as well as landscape.
        let shortSide = min(width, height)
        let ratio = shortSide >= 2160 ? "4k" : shortSide >= 1080 ? "1080p" : "720p"
        items.removeAll { $0.name == "ratio" || $0.name == "watermark" }
        items.append(URLQueryItem(name: "ratio", value: ratio))
        items.append(URLQueryItem(name: "watermark", value: "0"))
        parts.queryItems = items
        return parts.url ?? url
    }

    private static func isHDRText(_ text: String) -> Bool {
        text.contains("hdr")
            || text.contains("hlg")
            || text.contains("dolby")
            || text.contains("dovi")
            || text.contains("dvhe")
            || text.contains("10bit")
            || text.contains("10-bit")
    }

    private static func isDirectDouyinVideoURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host.contains("douyinvod.com") else {
            return false
        }
        let text = url.absoluteString.lowercased()
        return !text.contains("/logo/") && !text.contains("watermark=1") && !text.contains("logo_type=")
    }

    private static func requestAsync(_ url: URL, referer: URL?, readsBody: Bool, customRequest: URLRequest? = nil, quickTimeout: Bool = false) async throws -> (Data, URL?) {
        var request = customRequest ?? URLRequest(url: url)
        if customRequest == nil {
            request.url = url
            request.httpMethod = "GET"
            request.timeoutInterval = quickTimeout ? 5 : 8
            request.assumesHTTP3Capable = false
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            if let referer {
                request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            }
        } else {
            request.timeoutInterval = quickTimeout ? 5 : 8
            request.assumesHTTP3Capable = false
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
        }
        if DownloaderHTTPCompatibility.shouldUseDirectly(for: request) {
            return try await DownloaderHTTPCompatibility.dataAsync(for: request, readsBody: readsBody)
        }
        return try await DownloaderHTTPCompatibility.requestData(
            for: request, session: networkSession, readsBody: readsBody
        )
    }

    static func download(
        _ tasks: [DownloadTask],
        maxConcurrentDownloads requestedMaxConcurrentDownloads: Int? = nil,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async throws -> [DownloadOutcome] {
        guard !tasks.isEmpty else { return [] }
        let limit = max(1, requestedMaxConcurrentDownloads ?? maxConcurrentDownloads)
        let progressAggregator = DownloaderInfra.DownloadProgressAggregator(totalCount: tasks.count, handler: progress)
        return try await withThrowingTaskGroup(of: DownloadOutcome.self) { group in
            var outcomes: [DownloadOutcome] = []
            var iter = Array(tasks.enumerated()).makeIterator()
            for _ in 0..<min(limit, tasks.count) {
                guard let t = iter.next() else { break }
                group.addTask {
                    let outcome = try await download(t.element) { fraction in
                        await progressAggregator.update(index: t.offset, fraction: fraction)
                    }
                    await progressAggregator.complete(index: t.offset)
                    return outcome
                }
            }
            for try await outcome in group {
                outcomes.append(outcome)
                guard let t = iter.next() else { continue }
                group.addTask {
                    let outcome = try await download(t.element) { fraction in
                        await progressAggregator.update(index: t.offset, fraction: fraction)
                    }
                    await progressAggregator.complete(index: t.offset)
                    return outcome
                }
            }
            return outcomes.sorted { $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent }
        }
    }

    static func download(
        _ task: DownloadTask,
        retries: Int = 3,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async throws -> DownloadOutcome {
        try Task.checkCancellation()
        var lastError: Error?
        for attempt in 0...retries {
            do {
                try FileManager.default.createDirectory(at: task.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporaryURL = task.destination.appendingPathExtension("part")
                try await downloadOnceAsync(task.url, to: temporaryURL, progress: progress)
                try await MediaFileUtilities.validateMedia(temporaryURL, expectedSuffix: task.destination.pathExtension)
                let suffix = MediaFileUtilities.sniffSuffix(temporaryURL, defaultSuffix: task.destination.pathExtension.isEmpty ? "bin" : task.destination.pathExtension)
                let finalURL = task.destination.deletingPathExtension().appendingPathExtension(suffix)
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: finalURL.path)
                print("[HERMES] 媒体校验通过: \(finalURL.lastPathComponent), 来源主机: \(task.url.host ?? "unknown")")
                return DownloadOutcome(fileURL: finalURL, sourceHost: task.url.host ?? "unknown")
            } catch {
                try Task.checkCancellation()
                lastError = error
                try? FileManager.default.removeItem(at: task.destination.appendingPathExtension("part"))
                if attempt < retries {
                    try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
                }
            }
        }
        for alternate in task.alternateURLs where alternate != task.url {
            do {
                var outcome = try await download(DownloadTask(url: alternate, destination: task.destination), retries: 0, progress: progress)
                outcome.usedFallback = true
                return outcome
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        if let fallback = task.fallbackURL {
            print("[HERMES] 当前候选失败，回退到保留的视频流。")
            var outcome = try await download(DownloadTask(url: fallback, destination: task.destination), retries: 1, progress: progress)
            outcome.usedFallback = true
            return outcome
        }
        throw lastError ?? NSError(domain: "DouyinDownloader", code: 8, userInfo: [NSLocalizedDescriptionKey: "下载失败：\(task.destination.lastPathComponent)"])
    }

    private static func downloadOnceAsync(
        _ url: URL,
        to destination: URL,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async throws {
        try await DownloaderInfra.downloadOnceAsync(url, to: destination, userAgent: userAgent, session: networkSession, shouldUseDirectly: shouldUseDirectly, extraHeaders: ["Referer": "https://www.douyin.com/"], progress: progress)
    }

    private static func shouldUseDirectly(_ req: URLRequest) -> Bool {
        DownloaderHTTPCompatibility.shouldUseDirectly(for: req)
    }

}

private final class DouyinAwemeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (priority: Int, data: Data)?

    var bestData: Data? {
        lock.lock()
        let result = value?.data
        lock.unlock()
        return result
    }

    func hasWinner(atOrBefore priority: Int) -> Bool {
        lock.lock()
        let result = value.map { $0.priority <= priority } ?? false
        lock.unlock()
        return result
    }

    @discardableResult
    func set(_ data: Data, priority: Int) -> Bool {
        lock.lock()
        let didSet: Bool
        if value == nil || priority < value!.priority {
            value = (priority, data)
            didSet = true
        } else {
            didSet = false
        }
        lock.unlock()
        return didSet
    }
}
