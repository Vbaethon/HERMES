import AppKit
import Foundation

enum DewuNativeDownloader {
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 dewu/5.93.5"
    private static let maxConcurrentDownloads = DownloaderHTTPCompatibility.downloadConcurrencyLimit()
    private static let networkSession: URLSession = DownloaderHTTPCompatibility.makeDownloadSession(timeoutResource: 120, includeCookieStorage: false)

    static func run(
        shareText: String,
        destinationRoot: URL,
        waitSeconds: TimeInterval = 12,
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async -> ToolRunResult {
        do {
            let shareURL = try extractShareURL(from: shareText)
            let pageInfo = try await parseSharePage(shareURL)
            fputs("[HERMES-DEWU] parseSharePage: contentID=\(pageInfo.contentID), images=\(pageInfo.images.count), videos=\(pageInfo.videos.count), isVideoPost=\(pageInfo.isVideoPost)\n", stderr)
            guard !pageInfo.contentID.isEmpty else {
                return .failure("未能从分享页解析 contentId/trendId。")
            }

            let author = FileNaming.sanitizeFileName(pageInfo.author.isEmpty ? "dewu" : pageInfo.author, fallback: "dewu")
            let userID = FileNaming.sanitizeFileName(pageInfo.userID.isEmpty ? "unknown" : pageInfo.userID, fallback: "unknown")
            let outputFolder = try FileNaming.userOutputFolder(root: destinationRoot, author: author, userID: userID, defaultName: "dewu")
            let folderName = outputFolder.lastPathComponent
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

            var lines = [
                "contentId: \(pageInfo.contentID)",
                "用户: \(folderName)",
                "分享链接: \(shareURL.absoluteString)",
                "输出目录: \(outputFolder.path)"
            ]

            var usedNames = Set<String>()
            let shareVideoURLs = bestVideoVariants(pageInfo.videos)
            var imageSources = pageInfo.isVideoPost ? [] : pageInfo.images
            var staticImageDownloadError: Error?
            if imageSources.isEmpty {
                lines.append(pageInfo.isVideoPost ? "视频帖跳过封面图，仅下载视频。" : "分享页没有暴露静态原图。")
            } else {
                lines.append("下载静态图: \(imageSources.count) 张（来源：分享页原图 URL）")
                var tasks: [DownloadTask] = []
                for source in imageSources {
                    let url = source.url
                    let destination = FileNaming.uniqueDestination(in: outputFolder, name: fileName(from: url), usedNames: &usedNames)
                    tasks.append(DownloadTask(url: url, destination: destination, fallbackURLs: source.fallbackURLs))
                }
                do {
                    try await download(tasks, progress: progress)
                } catch {
                    staticImageDownloadError = error
                    if DewuDownloadRecoveryPolicy.shouldContinueAfterStaticImageFailure(canStillReachVideoStage: true) {
                        lines.append("静态图下载未完成，继续尝试 Live Photo 视频。")
                    } else {
                        throw error
                    }
                }
            }

            var mediaPairs: [APIMediaPair] = []
            var videoURLs: [URL] = []
            var videoSource = "App 接口 JSON"
            let roots = DewuLogStore.dataRoots()
            fputs("[HERMES-DEWU] dataRoots count=\(roots.count)\n", stderr)
            let recentDatabaseLimit = 3
            let databases = DewuLogStore.logDatabases(roots: roots, limit: recentDatabaseLimit)
            fputs("[HERMES-DEWU] logDatabases count=\(databases.count)\n", stderr)
            var didFetchAPIDetail = false
            var didConfirmNoAPIVideo = false
            if !databases.isEmpty {
                let apiResult = await fetchAPIMediaResult(contentID: pageInfo.contentID, databases: databases)
                mediaPairs = apiResult.pairs
                didFetchAPIDetail = apiResult.didFetchDetail
                fputs("[HERMES-DEWU] fetchAPIMediaResult: didFetchDetail=\(didFetchAPIDetail), pairs=\(mediaPairs.count)\n", stderr)
                if !mediaPairs.isEmpty {
                    videoURLs = bestVideoVariants(mediaPairs.map(\.videoURL))
                    fputs("[HERMES-DEWU] API videoURLs count=\(videoURLs.count)\n", stderr)
                    videoSource = "App 接口 JSON"
                    lines.append(pageInfo.isVideoPost ? "已从本机得物 App 接口 JSON 找到视频源。" : "已从本机得物 App 接口 JSON 找到 Live Photo 视频。")
                } else if didFetchAPIDetail {
                    lines.append("得物 App 接口已返回，但未包含 Live Photo 视频。")
                } else {
                    lines.append("已找到得物 App 日志数据库（\(databases.count) 个），但未匹配到当前帖子的 API 记录。")
                }
            } else {
                lines.append(roots.isEmpty
                    ? "未找到得物 App 容器（macOS 27 可能限制了容器访问）。"
                    : "已找到得物 App 容器（\(roots.count) 个），但日志数据库为空（DB 路径：\(roots.first?.appendingPathComponent("Library/DUCaches/logger/sqlite3/never/com.shizhuang.Logger.v2", isDirectory: true).path ?? "无")）。")
            }

            if mediaPairs.isEmpty || videoURLs.isEmpty {
                let shouldSearchPlaybackLogs = DewuPlaybackLogVideoExtractor.shouldSearchPlaybackLogs(
                    didFetchAPIDetail: didFetchAPIDetail,
                    hasAPIMediaPairs: !mediaPairs.isEmpty,
                    hasVideoURLs: !videoURLs.isEmpty,
                    isVideoPost: pageInfo.isVideoPost,
                    hasImageSources: !imageSources.isEmpty,
                    hasShareVideoURLs: !shareVideoURLs.isEmpty
                )
                if didFetchAPIDetail, !shouldSearchPlaybackLogs, !pageInfo.isVideoPost, !imageSources.isEmpty, shareVideoURLs.isEmpty {
                    didConfirmNoAPIVideo = true
                    lines.append("App 接口已确认当前帖子没有 Live Photo 视频。")
                } else if roots.isEmpty {
                    lines.append("未找到得物 App 容器，使用分享页公开媒体兜底。")
                } else {
                    lines.append(didFetchAPIDetail ? "App 接口未返回 Live Photo 视频，继续读取播放日志..." : "本机没有当前帖子的详情接口记录，正在后台打开得物 App 生成签名请求...")
                    Task.detached { openDewuApp(shareURL) }
                    if !didFetchAPIDetail {
                        mediaPairs = await waitForAPIMediaPairs(contentID: pageInfo.contentID, roots: roots, databaseLimit: recentDatabaseLimit, timeout: waitSeconds)
                        if mediaPairs.isEmpty {
                            mediaPairs = await fetchAPIMediaPairs(contentID: pageInfo.contentID, databases: DewuLogStore.logDatabases(roots: roots))
                        }
                        videoURLs = bestVideoVariants(mediaPairs.map(\.videoURL))
                        videoSource = "App 接口 JSON"
                    }

                if videoURLs.isEmpty {
                    let recentDatabases = DewuLogStore.logDatabases(roots: roots, limit: recentDatabaseLimit)
                    fputs("[HERMES-DEWU] searching playback logs, recentDatabases=\(recentDatabases.count)\n", stderr)
                    videoURLs = bestVideoVariants(await waitForMediaVideoURLs(contentID: pageInfo.contentID, databases: recentDatabases, timeout: min(max(waitSeconds, 1), 8)))
                    fputs("[HERMES-DEWU] after waitForMediaVideoURLs: videoURLs=\(videoURLs.count)\n", stderr)
                    if videoURLs.isEmpty {
                        let allDatabases = DewuLogStore.logDatabases(roots: roots)
                        fputs("[HERMES-DEWU] trying all databases, count=\(allDatabases.count)\n", stderr)
                        videoURLs = bestVideoVariants(extractMediaVideoURLsFromLogs(contentID: pageInfo.contentID, databases: allDatabases))
                        fputs("[HERMES-DEWU] after extractMediaVideoURLsFromLogs: videoURLs=\(videoURLs.count)\n", stderr)
                    }
                        videoSource = "播放日志"
                    }
                }
            }

            if videoURLs.isEmpty, !shareVideoURLs.isEmpty {
                videoURLs = shareVideoURLs
                videoSource = "分享页视频"
                fputs("[HERMES-DEWU] fallback to shareVideoURLs: count=\(videoURLs.count)\n", stderr)
            }

            fputs("[HERMES-DEWU] final state: videoURLs=\(videoURLs.count), imageSources=\(imageSources.count), shareVideoURLs=\(shareVideoURLs.count)\n", stderr)

            if videoURLs.isEmpty, pageInfo.images.isEmpty {
                return .failure("没有可下载的帖子媒体。")
            }

            if imageSources.isEmpty, !pageInfo.isVideoPost {
                imageSources = mediaPairs.compactMap { pair in
                    pair.imageURL.map { ImageSource(url: $0) }
                }
                if !imageSources.isEmpty {
                    lines.append("下载静态图: \(imageSources.count) 张（来源：App 接口 JSON）")
                    var tasks: [DownloadTask] = []
                    for source in imageSources {
                        let url = source.url
                        let destination = FileNaming.uniqueDestination(in: outputFolder, name: fileName(from: url), usedNames: &usedNames)
                        tasks.append(DownloadTask(url: url, destination: destination, fallbackURLs: source.fallbackURLs))
                    }
                    try await download(tasks, progress: progress)
                }
            }

            if videoURLs.isEmpty {
                if !didConfirmNoAPIVideo {
                    lines.append("未在 App 日志中发现当前帖子的视频源。")
                }
                if let staticImageDownloadError,
                   DewuDownloadRecoveryPolicy.shouldFailAfterStaticImageFailure(downloadedVideoCount: 0) {
                    throw staticImageDownloadError
                }
            } else {
                lines.append(pageInfo.isVideoPost ? "下载视频: \(videoURLs.count) 个（来源：\(videoSource)）" : "下载 Live Photo/动态图视频: \(videoURLs.count) 个（来源：\(videoSource)）")
                var tasks: [DownloadTask] = []
                for (index, url) in videoURLs.enumerated() {
                    let stillURL = pageInfo.isVideoPost ? nil : (index < mediaPairs.count ? mediaPairs[index].imageURL : (index < imageSources.count ? imageSources[index].url : nil))
                    let destination = FileNaming.uniqueDestination(in: outputFolder, name: videoName(stillURL: stillURL, videoURL: url), usedNames: &usedNames)
                    tasks.append(DownloadTask(url: url, destination: destination))
                }
                try await download(tasks, progress: progress)
                if staticImageDownloadError != nil {
                    lines.append("部分静态图下载失败，已保留可下载的视频。")
                }
            }

            lines.append("完成。输出只保留媒体文件，不保存鉴权链接。")
            return .success(lines.joined(separator: "\n"))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private struct SharePageInfo {
        var contentID = ""
        var author = ""
        var userID = ""
        var images: [ImageSource] = []
        var videos: [URL] = []
        var isVideoPost = false
    }

    private struct ImageSource {
        var url: URL
        var fallbackURLs: [URL] = []
    }

    private struct APIMediaPair {
        var imageURL: URL?
        var videoURL: URL
    }

    private struct APIMediaResult {
        var pairs: [APIMediaPair]
        var didFetchDetail: Bool
    }

    private struct DownloadTask {
        var url: URL
        var destination: URL
        var fallbackURLs: [URL] = []
    }

    private static func extractShareURL(from text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'‘’“”"))
        let patterns = [
            #"https?://dw4\.co/t/A/[A-Za-z0-9]+"#,
            #"https?://(?:m\.dewu\.com|www\.dewu\.com)/[^\s，,。！!）)】'"‘’“”]+"#
        ]
        for pattern in patterns {
            if let match = RegexUtilities.firstMatch(pattern, in: trimmed),
               let url = URL(string: MediaFileUtilities.trimURLPunctuation(String(trimmed[match]))) {
                return url
            }
        }
        if let url = URL(string: MediaFileUtilities.trimURLPunctuation(trimmed)), url.scheme?.hasPrefix("http") == true {
            return url
        }
        throw NSError(domain: "DewuDownloader", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到可用的得物分享链接。"])
    }

    private static func parseSharePage(_ url: URL) async throws -> SharePageInfo {
        let page = String(data: try await requestAsync(url), encoding: .utf8) ?? ""
        var info = SharePageInfo()

        if let nextData = RegexUtilities.firstCapture(1, pattern: #"<script[^>]+id=["']__NEXT_DATA__["'][^>]*>(.*?)</script>"#, in: page, dotMatchesLineSeparators: true),
           let data = MediaFileUtilities.htmlDecode(nextData).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parseNextData(json, into: &info)
        }

        if info.contentID.isEmpty, let match = RegexUtilities.firstMatch(#"trendId[=/]([0-9]+)"#, in: page) {
            let fragment = String(page[match])
            if let idRange = RegexUtilities.firstMatch(#"[0-9]+"#, in: fragment) {
                info.contentID = String(fragment[idRange])
            }
        }

        if info.images.isEmpty {
            let matches = RegexUtilities.allMatches(#"https?://(?:image-cdn\.poizon\.com|imagex-cdn\.dewu\.com)/[^"\\<> ]+?\.(?:jpg|jpeg|png|heic|webp)(?:~[^"\\<> ]+)?"#, in: page)
            var seen = Set<String>()
            for value in matches {
                addPostImage(value, to: &info.images, seen: &seen)
            }
        }

        if info.videos.isEmpty {
            let matches = RegexUtilities.allMatches(#"https?://videocdn\.poizon\.com/[^"\\<> ]+?\.mp4[^"\\<> ]*"#, in: page)
            var seen = Set<String>()
            for value in matches {
                guard let normalizedURL = normalizedURL(value), !normalizedURL.path.contains("/algorithm/wm/") else { continue }
                if seen.insert(normalizedURL.absoluteString).inserted {
                    info.videos.append(normalizedURL)
                }
            }
        }
        if !info.videos.isEmpty {
            info.isVideoPost = true
        }

        if info.userID.isEmpty {
            info.userID = inferUserID(info.images.first?.url.absoluteString ?? "")
        }
        return info
    }

    private static func parseNextData(_ json: [String: Any], into info: inout SharePageInfo) {
        let props = (json["props"] as? [String: Any])?["pageProps"] as? [String: Any] ?? [:]
        info.contentID = JSONValueUtilities.string(props["trendId"]) ?? JSONValueUtilities.string((json["query"] as? [String: Any])?["trendId"]) ?? info.contentID
        let items = ((props["metaOGInfo"] as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        guard let item = items.first else { return }
        let content = item["content"] as? [String: Any] ?? [:]
        let user = item["userInfo"] as? [String: Any] ?? [:]
        info.author = JSONValueUtilities.string(user["userName"]) ?? ""
        info.userID = JSONValueUtilities.string(user["userId"]) ?? JSONValueUtilities.string(user["uid"]) ?? JSONValueUtilities.string(user["user_id"]) ?? JSONValueUtilities.string(user["duid"]) ?? ""
        info.contentID = JSONValueUtilities.string(content["contentId"]) ?? info.contentID
        let source = JSONValueUtilities.string(props["source"]) ?? JSONValueUtilities.string((props["routeQuery"] as? [String: Any])?["source"])
        if source == "videoTrend" {
            info.isVideoPost = true
        }

        var seenImages = Set<String>()
        var seenVideos = Set<String>()
        let media = (content["media"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        for item in media {
            if JSONValueUtilities.string(item["mediaType"]) == "img", let url = JSONValueUtilities.string(item["url"]) {
                addPostImage(url, to: &info.images, seen: &seenImages)
            } else if JSONValueUtilities.string(item["mediaType"]) == "video",
                      let value = JSONValueUtilities.string(item["url"]),
                      let url = normalizedURL(value),
                      !url.path.contains("/algorithm/wm/"),
                      seenVideos.insert(url.absoluteString).inserted {
                info.isVideoPost = true
                info.videos.append(url)
            }
        }

        if let cover = content["cover"] as? [String: Any],
           JSONValueUtilities.string(cover["mediaType"]) == "img",
           let coverURL = JSONValueUtilities.string(cover["url"]),
           let source = imageSource(from: coverURL),
           seenImages.insert(source.url.absoluteString).inserted {
            info.images.insert(source, at: 0)
        }

        if info.userID.isEmpty {
            info.userID = inferUserID(JSONValueUtilities.string(user["icon"]) ?? "", info.images.first?.url.absoluteString ?? "")
        }
    }

    private static func latestTrendDetailRequest(contentID: String, databases: [URL]) -> [String: Any]? {
        let sql = """
        select content from log_content
        where content like '%sns-cnt-center%trend-detail%'
          and (content like ? or content like ?)
        order by id desc
        limit 20
        """
        var totalChecked = 0
        for db in databases {
            let rows = DewuLogStore.query(db: db, sql: sql, bindings: ["%contentId=\(contentID)%", "%contentId%3D\(contentID)%"])
            totalChecked += rows.count
            for row in rows {
                guard let text = row.first,
                      let data = text.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      payload["pre_request_url"] != nil,
                      payload["pre_request_header"] != nil else {
                    continue
                }
                fputs("[HERMES-DEWU] latestTrendDetailRequest: found matching request\n", stderr)
                return payload
            }
        }
        fputs("[HERMES-DEWU] latestTrendDetailRequest: checked \(totalChecked) rows across \(databases.count) DBs, no match\n", stderr)
        return nil
    }

    private static func fetchAPIMediaPairs(contentID: String, databases: [URL]) async -> [APIMediaPair] {
        await fetchAPIMediaResult(contentID: contentID, databases: databases).pairs
    }

    private static func fetchAPIMediaResult(contentID: String, databases: [URL]) async -> APIMediaResult {
        guard let requestInfo = latestTrendDetailRequest(contentID: contentID, databases: databases),
              let urlText = requestInfo["pre_request_url"] as? String,
              let url = URL(string: urlText) else {
            fputs("[HERMES-DEWU] fetchAPIMediaResult: no trend-detail request info found in DB\n", stderr)
            return APIMediaResult(pairs: [], didFetchDetail: false)
        }
        fputs("[HERMES-DEWU] fetchAPIMediaResult: requesting \(urlText.prefix(120))...\n", stderr)
        let headers = requestInfo["pre_request_header"] as? [String: Any] ?? [:]
        let headerStrings = headers.compactMapValues { value -> String? in
            let text = JSONValueUtilities.string(value)
            guard let text else { return nil }
            return text
        }
        guard let data = try? await requestAsync(url, headers: headerStrings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fputs("[HERMES-DEWU] fetchAPIMediaResult: API request failed or invalid JSON\n", stderr)
            return APIMediaResult(pairs: [], didFetchDetail: false)
        }
        let pairs = extractAPIMediaPairs(json)
        fputs("[HERMES-DEWU] fetchAPIMediaResult: success, extracted \(pairs.count) media pairs\n", stderr)
        return APIMediaResult(pairs: pairs, didFetchDetail: true)
    }

    private static func waitForAPIMediaPairs(contentID: String, databases: [URL], timeout: TimeInterval) async -> [APIMediaPair] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let pairs = await fetchAPIMediaPairs(contentID: contentID, databases: databases)
            if !pairs.isEmpty || Date() >= deadline {
                return pairs
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private static func waitForAPIMediaPairs(contentID: String, roots: [URL], databaseLimit: Int, timeout: TimeInterval) async -> [APIMediaPair] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let databases = DewuLogStore.logDatabases(roots: roots, limit: databaseLimit)
            let pairs = await fetchAPIMediaPairs(contentID: contentID, databases: databases)
            if !pairs.isEmpty || Date() >= deadline {
                return pairs
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func extractAPIMediaPairs(_ json: [String: Any]) -> [APIMediaPair] {
        let mediaList = collectMediaDictionaries(in: json)
        var imagePairIndexes: [String: Int] = [:]
        var imagePairs: [(pair: APIMediaPair, score: Int)] = []
        for media in mediaList {
            guard let imageURL = mediaImageURL(media),
                  let videoURL = bestLivePhotoURL(media) else {
                continue
            }
            let key = imageURL.standardizedFileURL.path
            let candidate = APIMediaPair(imageURL: mediaImageURL(media), videoURL: videoURL)
            let candidateScore = videoScore(videoURL, meta: media)
            if let index = imagePairIndexes[key] {
                let current = imagePairs[index]
                if candidateScore > current.score {
                    imagePairs[index] = (candidate, candidateScore)
                }
            } else {
                imagePairIndexes[key] = imagePairs.count
                imagePairs.append((candidate, candidateScore))
            }
        }

        if !imagePairs.isEmpty {
            return imagePairs.map(\.pair)
        }

        var bestVideoPairs: [String: (pair: APIMediaPair, score: Int)] = [:]
        for media in mediaList {
            guard let videoURL = bestLivePhotoURL(media) else { continue }
            let key = videoVariantKey(videoURL)
            let candidate = APIMediaPair(imageURL: nil, videoURL: videoURL)
            let candidateScore = videoScore(videoURL, meta: media)
            if let current = bestVideoPairs[key] {
                if candidateScore > current.score {
                    bestVideoPairs[key] = (candidate, candidateScore)
                }
            } else {
                bestVideoPairs[key] = (candidate, candidateScore)
            }
        }

        return bestVideoPairs.values.sorted {
            $0.score > $1.score
        }
        .map(\.pair)
    }

    private static func collectMediaDictionaries(in value: Any, depth: Int = 0) -> [[String: Any]] {
        guard depth <= 8 else { return [] }
        if let values = value as? [Any] {
            return values.flatMap { collectMediaDictionaries(in: $0, depth: depth + 1) }
        }
        guard let dict = value as? [String: Any] else { return [] }

        var media: [[String: Any]] = []
        if isMediaDictionary(dict) {
            media.append(dict)
        }
        for nestedValue in dict.values {
            media.append(contentsOf: collectMediaDictionaries(in: nestedValue, depth: depth + 1))
        }
        return media
    }

    private static func isMediaDictionary(_ dict: [String: Any]) -> Bool {
        let type = JSONValueUtilities.string(dict["mediaType"])?.lowercased() ?? ""
        if type == "img" || type == "image" || type == "video" {
            return true
        }
        if JSONValueUtilities.string(dict["url"])?.contains(".mp4") == true {
            return true
        }
        if dict["mcFormat"] != nil || dict["mcTemplate"] != nil || dict["qualityType"] != nil || dict["videoCodec"] != nil {
            return true
        }
        return dict["livePhoto"] != nil || dict["livePhotos"] != nil
    }

    private static func waitForMediaVideoURLs(contentID: String, databases: [URL], timeout: TimeInterval) async -> [URL] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let urls = extractMediaVideoURLsFromLogs(contentID: contentID, databases: databases)
            if !urls.isEmpty || Date() >= deadline {
                return urls
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private static func extractMediaVideoURLsFromLogs(contentID: String, databases: [URL]) -> [URL] {
        let sql = """
        select coalesce(content, '') || ' ' || coalesce(attribute_text, '')
        from log_content
        where (content like ? or attribute_text like ?)
          and (content like '%.mp4?auth_key=%' or attribute_text like '%.mp4?auth_key=%')
        order by id desc
        limit 500
        """
        var urls: [URL] = []
        var seen = Set<String>()
        var totalRows = 0
        for db in databases {
            for row in DewuLogStore.query(db: db, sql: sql, bindings: ["%\(contentID)%", "%\(contentID)%"]) {
                totalRows += 1
                let text = MediaFileUtilities.htmlDecode((row.first ?? "").replacingOccurrences(of: "\\/", with: "/"))
                let before = urls.count
                for url in DewuPlaybackLogVideoExtractor.videoURLs(in: text) {
                    let key = url.path
                    if seen.insert(key).inserted {
                        urls.append(url)
                    }
                }
                if urls.count > before {
                    fputs("[HERMES-DEWU] extractMediaVideoURLsFromLogs: found \(urls.count - before) URL(s) in row\n", stderr)
                }
            }
        }
        fputs("[HERMES-DEWU] extractMediaVideoURLsFromLogs: scanned \(totalRows) rows, extracted \(urls.count) unique URLs\n", stderr)
        return urls
    }

    private static func bestLivePhotoURL(_ media: [String: Any]) -> URL? {
        var candidates: [(Int, URL)] = []
        for item in media["livePhotos"] as? [[String: Any]] ?? [] {
            candidates.append(contentsOf: collectVideoURLs(item).map { (videoScore($0, meta: item), $0) })
        }
        if candidates.isEmpty, let item = media["livePhoto"] as? [String: Any] {
            candidates.append(contentsOf: collectVideoURLs(item).map { (videoScore($0, meta: item), $0) })
        }
        if candidates.isEmpty {
            candidates.append(contentsOf: collectVideoURLs(media).map { (videoScore($0, meta: media), $0) })
        }
        return candidates.max { $0.0 < $1.0 }?.1
    }

    private static func collectVideoURLs(_ value: Any) -> [URL] {
        if let urlText = value as? String,
           urlText.contains(".mp4"),
           let url = normalizedURL(urlText) {
            return [url]
        }
        if let values = value as? [Any] {
            return values.flatMap(collectVideoURLs)
        }
        guard let dict = value as? [String: Any] else { return [] }
        var urls: [URL] = []
        for item in dict.values {
            urls.append(contentsOf: collectVideoURLs(item))
        }
        return urls
    }

    private static func mediaImageURL(_ media: [String: Any]) -> URL? {
        for key in ["url", "imageUrl", "originUrl", "originalUrl"] {
            if let value = media[key] as? String,
               let url = normalizedURL(value),
               isImageURL(url) {
                return url
            }
        }
        return nil
    }

    private static func isImageURL(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "heic", "heif", "webp"].contains(url.pathExtension.lowercased())
    }

    private static let directHosts = Set(["dw4.co"])

    private static func shouldUseDirectly(_ req: URLRequest) -> Bool {
        if let host = req.url?.host?.lowercased(), directHosts.contains(host) { return true }
        return DownloaderHTTPCompatibility.shouldUseDirectly(for: req)
    }

    private static func requestAsync(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        try await DownloaderInfra.requestAsync(url, headers: headers, userAgent: userAgent, session: networkSession, shouldUseDirectly: shouldUseDirectly)
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
        progress: DownloaderInfra.ProgressHandler? = nil
    ) async throws {
        try await DownloaderInfra.downloadWithRetriesAsync(task.url, to: task.destination, fallbackURLs: task.fallbackURLs, userAgent: userAgent, session: networkSession, shouldUseDirectly: shouldUseDirectly, progress: progress)
    }

    private static func openDewuApp(_ url: URL) {
        let runningNames = ["DUApp", "得物"]
        let alreadyRunning = runningNames.contains { name in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", name]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        guard !alreadyRunning else { return }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.siwuai.duapp") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.siwuai.duapp.DUNotificationService") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", "-b", "com.siwuai.duapp", url.absoluteString]
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let process2 = Process()
                process2.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process2.arguments = ["-g", "-a", "得物", url.absoluteString]
                try? process2.run()
                process2.waitUntilExit()
            }
        }
        Thread.sleep(forTimeInterval: 2)
    }

    private static func addPostImage(_ value: String, to images: inout [ImageSource], seen: inout Set<String>) {
        guard let source = imageSource(from: value), seen.insert(source.url.absoluteString).inserted else { return }
        images.append(source)
    }

    private static func isPostImageURL(_ url: URL) -> Bool {
        guard isDewuImageHost(url.host) else { return false }
        return !url.path.contains("/other/") && url.path.contains("/app/") && url.path.contains("/community/")
    }

    private static func normalizedURL(_ value: String) -> URL? {
        guard let url = decodedURL(value) else { return nil }
        if isDewuImageHost(url.host), let originalURL = originalDewuImageURL(url) {
            return originalURL
        }
        return url
    }

    private static func decodedURL(_ value: String) -> URL? {
        let decoded = MediaFileUtilities.htmlDecode(value)
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\/", with: "/")
        return URL(string: decoded)
    }

    private static func imageSource(from value: String) -> ImageSource? {
        guard let rawURL = decodedURL(value) else { return nil }
        let primaryURL = isDewuImageHost(rawURL.host) ? (originalDewuImageURL(rawURL) ?? rawURL) : rawURL
        guard isPostImageURL(primaryURL) else { return nil }
        let fallbackURLs = rawURL.absoluteString == primaryURL.absoluteString ? [] : [rawURL]
        return ImageSource(url: primaryURL, fallbackURLs: fallbackURLs)
    }

    private static func isDewuImageHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "image-cdn.poizon.com" || host == "imagex-cdn.dewu.com"
    }

    private static func originalDewuImageURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        for imageExtension in [".jpg", ".jpeg", ".png", ".heic", ".webp"] {
            guard let range = path.range(of: imageExtension, options: [.caseInsensitive]) else { continue }
            let suffix = path[range.upperBound...]
            if suffix.hasPrefix("~") || suffix.hasPrefix("%7E") || suffix.hasPrefix("%7e") {
                components.percentEncodedPath = String(path[..<range.upperBound])
                components.percentEncodedQuery = nil
                return components.url
            }
        }
        return url
    }

    private static func inferUserID(_ values: String...) -> String {
        for value in values where !value.isEmpty {
            if let range = RegexUtilities.firstMatch(#"/app/\d+/(?:community|other|third-avatar)/(\d+)[_/]"#, in: value) {
                let text = String(value[range])
                if let idRange = RegexUtilities.firstMatch(#"\d{6,}"#, in: text) {
                    return String(text[idRange])
                }
            }
            if let range = RegexUtilities.firstMatch(#"https?://[^/]+/[^?]*?(\d{6,})[_/]"#, in: value) {
                let text = String(value[range])
                if let idRange = RegexUtilities.firstMatch(#"\d{6,}"#, in: text) {
                    return String(text[idRange])
                }
            }
        }
        return "unknown"
    }

    private static func fileName(from url: URL) -> String {
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return name.isEmpty ? "media" : name
    }

    private static func videoName(stillURL: URL?, videoURL: URL) -> String {
        if let stillURL {
            let stem = URL(fileURLWithPath: fileName(from: stillURL)).deletingPathExtension().lastPathComponent
            if !stem.isEmpty {
                return "\(stem).mp4"
            }
        }
        return fileName(from: videoURL)
    }

    private static func bestVideoVariants(_ urls: [URL]) -> [URL] {
        var best: [String: URL] = [:]
        for url in urls {
            let key = videoVariantKey(url)
            if let current = best[key] {
                if videoScore(url, meta: [:]) > videoScore(current, meta: [:]) {
                    best[key] = url
                }
            } else {
                best[key] = url
            }
        }
        return best.values.sorted { videoScore($0, meta: [:]) > videoScore($1, meta: [:]) }
    }

    private static func videoVariantKey(_ url: URL) -> String {
        let name = fileName(from: url)
        let hash = RegexUtilities.allMatches(#"[0-9a-f]{24,32}"#, in: name).first?.lowercased()
        let duration = RegexUtilities.allMatches(#"_dur(\d+)"#, in: name).first.flatMap { text in
            RegexUtilities.firstMatch(#"\d+"#, in: text).map { String(text[$0]) }
        }
        if let hash, let duration {
            return "\(duration)_\(hash)"
        }
        return hash ?? URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }

    private static func videoScore(_ url: URL, meta: [String: Any]) -> Int {
        let path = url.path.lowercased()
        let name = fileName(from: url)
        var score = 0
        let fps = videoFPSHint(url: url, meta: meta)
        if fps >= 120 {
            score += 7_000_000
        } else if fps >= 60 {
            score += 5_000_000
        }
        if path.contains("/sns-og/") { score += 10_000_000 }
        let qualityText = [
            path,
            JSONValueUtilities.string(meta["mcFormat"]) ?? "",
            JSONValueUtilities.string(meta["mcTemplate"]) ?? "",
            JSONValueUtilities.string(meta["qualityType"]) ?? "",
            JSONValueUtilities.string(meta["videoCodec"]) ?? "",
            JSONValueUtilities.string(meta["type"]) ?? ""
        ]
        .joined(separator: " ")
        .lowercased()
        if qualityText.contains("wz265") || qualityText.contains("h265") || qualityText.contains("hevc") {
            score += 3_000_000
        }
        if qualityText.contains("enh_opt") || qualityText.contains("enhance") {
            score += 1_500_000
        }
        if path.contains("wz265_1080p") { score += 2_000_000 }
        if path.contains("dw264") { score += 500_000 }
        if (JSONValueUtilities.string(meta["mcFormat"]) ?? "").lowercased() == "origin"
            || (JSONValueUtilities.string(meta["mcTemplate"]) ?? "").lowercased() == "origin" {
            score += 20_000_000
        }
        let width = Int(JSONValueUtilities.string(meta["width"]) ?? "") ?? 0
        let height = Int(JSONValueUtilities.string(meta["height"]) ?? "") ?? 0
        let dimensions = width > 0 && height > 0 ? (width, height) : videoDimensions(from: name)
        score += dimensions.0 * dimensions.1
        if let byteText = RegexUtilities.allMatches(#"_byte(\d+)"#, in: name).first,
           let numberRange = RegexUtilities.firstMatch(#"\d+"#, in: byteText),
           let bytes = Int(byteText[numberRange]) {
            score += bytes
        }
        return score
    }

    private static func videoFPSHint(url: URL, meta: [String: Any]) -> Int {
        let text = ([url.path, JSONValueUtilities.string(meta["fps"]) ?? "", JSONValueUtilities.string(meta["frameRate"]) ?? "", JSONValueUtilities.string(meta["frame_rate"]) ?? ""]).joined(separator: " ").lowercased()
        var values = RegexUtilities.allMatches(#"\d{2,3}\s*fps"#, in: text).compactMap { Int($0.filter(\.isNumber)) }
        for key in ["fps", "frameRate", "frame_rate"] {
            if let value = Double(JSONValueUtilities.string(meta[key]) ?? ""), value > 0 {
                values.append(Int(value))
            }
        }
        return values.max() ?? 0
    }

    private static func videoDimensions(from name: String) -> (Int, Int) {
        guard let match = RegexUtilities.allMatches(#"w\d+[_h]\d+|w\d+h\d+"#, in: name).first else { return (0, 0) }
        let numbers = RegexUtilities.allMatches(#"\d+"#, in: match).compactMap(Int.init)
        guard numbers.count >= 2 else { return (0, 0) }
        return (numbers[numbers.count - 2], numbers[numbers.count - 1])
    }

}
