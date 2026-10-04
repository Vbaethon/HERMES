import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Read-only local information for the native inspector. The caller supplies
/// composition state from its verified record; filenames never establish it.
enum MediaInspection {
    enum Section: String, CaseIterable, Equatable, Sendable {
        case common, image, video, post, sourceDetails, imageDetails, videoDetails

        var title: String {
            switch self {
            case .common: "信息"
            case .image: "图片"
            case .video: "视频"
            case .post: "帖子信息"
            case .sourceDetails: "来源详情"
            case .imageDetails: "图片技术信息"
            case .videoDetails: "视频技术信息"
            }
        }
    }

    struct Request: Hashable, Sendable {
        let name: String
        let sourceURLs: [URL]
        let displayedURLs: [URL]
        let kind: String
        let compositionState: String
        var isCompositionOutput = false
        var importedToPhotos: Bool? = nil
    }

    struct Row: Equatable, Sendable {
        let key: String
        let value: String
        let section: Section

        init(key: String, value: String, section: Section = .common) {
            self.key = key
            self.value = value
            // Keep useful media properties ahead of identifiers and codec data.
            if ["帖子标题/描述", "来源帖子"].contains(key) {
                self.section = .post
            } else if ["帖子 ID", "博主 ID", "下载时间", "Live Photo 配对标识"].contains(key) {
                self.section = .sourceDetails
            } else if ["编码尺寸", "图像编码", "色深", "颜色配置", "方向元数据", "Live Photo 标识",
                       "来源记录", "媒体来源主机", "源字段", "图片资源 ID", "媒体资源标识", "下载时 SHA-256",
                       "视频轨数", "视频码率", "视频编码", "视频色彩原色", "视频传递函数",
                       "音频编码", "声道数", "采样率"].contains(key) {
                self.section = section == .video ? .videoDetails : .imageDetails
            } else {
                self.section = section
            }
        }
    }

    static func load(_ request: Request) async -> [Row] {
        let reader = Task.detached(priority: .userInitiated) { await rows(for: request) }
        return await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
    }

    /// Changes to extended attributes update ctime even when the media bytes and
    /// mtime stay unchanged. Include it so attribution updates invalidate caches.
    static func revision(for request: Request) -> String {
        unique(request.displayedURLs + request.sourceURLs).map { url in
            var info = stat()
            guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else { return "missing" }
            return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }.joined(separator: "\n")
    }

    /// Only reads small local filesystem receipts. Image/video parsing stays on
    /// the background reader; unknown properties never borrow the old selection.
    static func preview(_ request: Request) -> [Row] {
        var result = commonRows(for: request)
        for url in unique(request.displayedURLs) {
            let section: Section = FileSystemUtilities.isImage(url) ? .image : .video
            for key in section == .image ? ["显示尺寸", "HDR"] : ["显示尺寸", "时长", "HDR", "帧率", "音轨"] {
                result.append(Row(key: key, value: "读取中…", section: section))
            }
            if let revision = MediaFileRevision(url) {
                result.append(Row(key: "大小", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: revision.size), countStyle: .file), section: section))
            }
            result.append(Row(key: "格式", value: UTType(filenameExtension: url.pathExtension)?.localizedDescription
                ?? url.pathExtension.uppercased(), section: section))
        }
        return ordered(result)
    }

    private static func commonRows(for request: Request) -> [Row] {
        let displayedURLs = unique(request.displayedURLs)
        let sourceURLs = unique(request.sourceURLs)
        let evidenceURLs = sourceURLs.isEmpty ? displayedURLs : sourceURLs
        var result = [Row(key: "素材类型", value: request.kind)]
        if request.compositionState != "不适用" {
            result.append(Row(key: "合成状态", value: request.compositionState))
        }
        if let imported = request.importedToPhotos {
            result.append(Row(key: "照片图库", value: imported ? "已导入" : "未导入"))
        }
        result.append(Row(key: "原始文件", value: request.isCompositionOutput
            ? "合成产物（非云端原始文件）" : sourceSummary(for: evidenceURLs)))
        if request.isCompositionOutput {
            result.append(Row(key: "源文件原始状态", value: sourceURLs.isEmpty
                ? "未记录，无法确认" : sourceSummary(for: sourceURLs)))
        }
        result += attributionRows(evidenceURLs: evidenceURLs, displayedURLs: displayedURLs)
        if let order = unique(evidenceURLs + displayedURLs).compactMap({ MediaDisplayOrder.read(from: $0) }).first {
            result.append(Row(key: "帖子内序号", value: String(order.index)))
            result.append(Row(key: "下载时间", value: formattedDate(Date(timeIntervalSince1970: order.downloadedAt))))
        }
        return result
    }

    private static func rows(for request: Request) async -> [Row] {
        let displayedURLs = unique(request.displayedURLs)
        var result = commonRows(for: request)

        var identifiers: [(image: Bool, value: String?)] = []
        let files = await withTaskGroup(of: (Int, [Row], String?).self) { group in
            for (index, url) in displayedURLs.enumerated() {
                group.addTask {
                    let section: Section = FileSystemUtilities.isImage(url) ? .image
                        : FileSystemUtilities.isVideo(url) ? .video : .common
                    let details = await fileRows(url, section: section)
                    return (index, details.rows, details.livePhotoIdentifier)
                }
            }
            var results: [(Int, [Row], String?)] = []
            for await file in group { results.append(file) }
            return results.sorted { $0.0 < $1.0 }
        }
        guard !Task.isCancelled else { return [] }
        for (index, fileRows, identifier) in files {
            result += fileRows
            identifiers.append((FileSystemUtilities.isImage(displayedURLs[index]), identifier))
        }
        let imageIdentifiers = identifiers.filter(\.image).compactMap(\.value)
        let videoIdentifiers = identifiers.filter { !$0.image }.compactMap(\.value)
        if displayedURLs.count == 2,
           displayedURLs.contains(where: FileSystemUtilities.isImage),
           displayedURLs.contains(where: FileSystemUtilities.isVideo) {
            let value: String
            if imageIdentifiers.count == 1, videoIdentifiers.count == 1 {
                value = imageIdentifiers[0] == videoIdentifiers[0] ? "照片与视频标识一致" : "照片与视频标识不一致"
            } else { value = "尚未读取到完整的照片与视频配对标识" }
            result.append(Row(key: "Live Photo 配对标识", value: value))
        }
        return ordered(result)
    }

    private static func ordered(_ rows: [Row]) -> [Row] {
        let common = ["素材类型", "合成状态", "照片图库", "来源平台", "博主",
                      "帖子内序号", "原始文件", "源文件原始状态"]
        let media = ["显示尺寸", "时长", "HDR", "帧率", "音轨", "大小", "格式", "文件状态", "媒体信息"]
        return Section.allCases.flatMap { section in
            let priority = section == .common ? common : section == .post ? ["帖子标题/描述", "来源帖子"] : media
            return rows.filter { $0.section == section }.enumerated().sorted {
                let left = priority.firstIndex(of: $0.element.key) ?? priority.count
                let right = priority.firstIndex(of: $1.element.key) ?? priority.count
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
        }
    }

    /// A download-order receipt or post attribution cannot establish originality.
    private static func sourceSummary(for urls: [URL]) -> String {
        guard !urls.isEmpty else { return "未记录，无法确认" }
        let statuses = urls.map { sourceDescription(MediaSourceProvenance.read(from: $0)) }
        if Set(statuses).count == 1 { return statuses[0] }
        return zip(urls, statuses).map {
            "\(FileSystemUtilities.isImage($0) ? "图片" : "视频")：\($1)"
        }.joined(separator: "\n")
    }

    private static func sourceDescription(_ receipt: MediaSourceProvenance?) -> String {
        guard let receipt else { return "未记录，无法确认" }
        switch receipt.state {
        case .cloudOriginal: return "原始文件（下载时已验证）"
        case .originalWithRecoveredAudio: return "原始画面，已恢复原有音频"
        case .playbackBackup: return "播放源备份（未确认为原始文件）"
        case .unconfirmed: return "待确认（文件已变更或记录失效）"
        }
    }

    private static func attributionRows(evidenceURLs: [URL], displayedURLs: [URL]) -> [Row] {
        var attributions = evidenceURLs.compactMap { MediaPostAttribution.read(from: $0) }
        if attributions.isEmpty {
            attributions = displayedURLs.compactMap { MediaPostAttribution.read(from: $0) }
        }
        // One logical selection may have two files; differing post identities are
        // reported instead of choosing an arbitrary author from either file.
        let identities = Set(attributions.map { $0.platform + ":" + $0.postID })
        if identities.count > 1 {
            return [Row(key: "来源帖子", value: identities.sorted().joined(separator: "\n")),
                    Row(key: "博主", value: "存在多个来源，无法确定单一博主")]
        }
        if let attribution = attributions.first {
            return [Row(key: "来源平台", value: platformName(attribution.platform)),
                    Row(key: "帖子 ID", value: attribution.postID),
                    Row(key: "来源帖子", value: attributions.compactMap(\.postURL).first ?? "未记录"),
                    Row(key: "帖子标题/描述", value: postText(attributions)),
                    Row(key: "博主", value: attributions.compactMap(\.authorName).first ?? "未记录"),
                    Row(key: "博主 ID", value: attributions.compactMap(\.authorID).first ?? "未记录")]
        }
        var postIDs = Set(evidenceURLs.compactMap { MediaDisplayOrder.read(from: $0)?.postID })
        if postIDs.isEmpty {
            postIDs = Set(displayedURLs.compactMap { MediaDisplayOrder.read(from: $0)?.postID })
        }
        let knownPosts = postIDs.compactMap { postID -> (String, String)? in
            guard let separator = postID.firstIndex(of: ":") else { return nil }
            let platform = String(postID[..<separator])
            let identifier = String(postID[postID.index(after: separator)...])
            guard ["xhs", "douyin", "dewu"].contains(platform), !identifier.isEmpty else { return nil }
            return (platform, identifier)
        }
        var rows: [Row] = []
        if knownPosts.count == 1, let post = knownPosts.first {
            rows += [Row(key: "来源平台", value: platformName(post.0)), Row(key: "帖子 ID", value: post.1)]
        } else {
            rows.append(Row(key: "来源平台", value: "未记录"))
            let noteIDs = Set(unique(evidenceURLs + displayedURLs).compactMap { MediaSourceProvenance.read(from: $0)?.noteID })
            if noteIDs.count == 1, let identifier = noteIDs.first {
                rows.append(Row(key: "帖子 ID", value: identifier))
            }
        }
        rows += [Row(key: "来源帖子", value: "未记录"), Row(key: "帖子标题/描述", value: "未记录"),
                 Row(key: "博主", value: "未记录"), Row(key: "博主 ID", value: "未记录")]
        return rows
    }

    private static func postText(_ attributions: [MediaPostAttribution]) -> String {
        let title = attributions.compactMap(\.title).first
        let description = attributions.compactMap(\.postDescription).first
        let values = [title, description].compactMap { $0 }
        var seen = Set<String>()
        let distinct = values.filter { seen.insert($0).inserted }
        return distinct.isEmpty ? "未记录" : distinct.joined(separator: "\n")
    }

    private static func fileRows(_ url: URL, section: Section) async -> (rows: [Row], livePhotoIdentifier: String?) {
        func row(_ key: String, _ value: String) -> Row { Row(key: key, value: value, section: section) }
        var rows: [Row] = []
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey,
                    .contentTypeKey]),
              values.isRegularFile == true else {
            rows.append(row("文件状态", "文件不存在或不可读取"))
            return (rows, nil)
        }
        rows.append(row("大小", values.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "无法读取"))
        rows.append(row("格式", values.contentType?.localizedDescription ?? url.pathExtension.uppercased()))
        let receipt = MediaSourceProvenance.read(from: url)
        if let receipt {
            rows.append(row("来源记录", sourceDescription(receipt)))
            if !receipt.sourceHost.isEmpty { rows.append(row("媒体来源主机", receipt.sourceHost)) }
            if let field = receipt.sourceField, !field.isEmpty { rows.append(row("源字段", field)) }
            if !receipt.imageFileID.isEmpty { rows.append(row("图片资源 ID", receipt.imageFileID)) }
            if !receipt.objectKey.isEmpty { rows.append(row("媒体资源标识", receipt.objectKey)) }
            if let hash = receipt.sha256 { rows.append(row("下载时 SHA-256", hash)) }
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [String: Any] {
            let index = CGImageSourceGetPrimaryImageIndex(source)
            let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
            let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
            let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
            if let width, let height {
                let rotated = [5, 6, 7, 8].contains(orientation)
                rows.append(row("显示尺寸", "\(rotated ? height : width) × \(rotated ? width : height) 像素"))
                rows.append(row("编码尺寸", "\(width) × \(height) 像素"))
            }
            if let type = CGImageSourceGetType(source) {
                rows.append(row("图像编码", UTType(type as String)?.localizedDescription ?? (type as String)))
            }
            if let depth = properties[kCGImagePropertyDepth as String] as? NSNumber {
                rows.append(row("色深", "\(depth.intValue) 位/通道"))
            }
            if let profile = properties[kCGImagePropertyProfileName as String] as? String {
                rows.append(row("颜色配置", profile))
            }
            rows.append(row("方向元数据", String(orientation)))
            rows.append(row("HDR", imageDynamicRange(source, index: index)))
            let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
            let identifier = (maker?["17"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let identifier { rows.append(row("Live Photo 标识", identifier)) }
            return (rows, identifier)
        }

        guard FileSystemUtilities.isVideo(url) else {
            if section == .image { rows.append(row("HDR", "无法确认")) }
            return (rows, nil)
        }
        let asset = AVURLAsset(url: url)
        do {
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                rows.append(row("时长", String(format: "%.3f 秒", duration.seconds)))
            }
            let videos = try await asset.loadTracks(withMediaType: .video)
            rows.append(row("视频轨数", String(videos.count)))
            let hdrTracks = try await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)
            rows.append(row("HDR", videos.isEmpty ? "无法确认" : (hdrTracks.isEmpty ? "否（SDR）" : "是")))
            if let video = videos.first {
                let (size, transform) = try await video.load(.naturalSize, .preferredTransform)
                let display = CGRect(origin: .zero, size: size).applying(transform)
                rows.append(row("显示尺寸", "\(Int(abs(display.width).rounded())) × \(Int(abs(display.height).rounded())) 像素"))
                if let frameRate = try? await video.load(.nominalFrameRate), frameRate > 0 {
                    rows.append(row("帧率", String(format: "%.3f fps", frameRate)))
                }
                if let bitRate = try? await video.load(.estimatedDataRate), bitRate > 0 {
                    rows.append(row("视频码率", String(format: "%.2f Mbps", bitRate / 1_000_000)))
                }
                if let descriptions = try? await video.load(.formatDescriptions) {
                    let codecs = Array(Set(descriptions.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) })).sorted()
                    if !codecs.isEmpty { rows.append(row("视频编码", codecs.joined(separator: ", "))) }
                    if let description = descriptions.first {
                        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
                        if let color = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String {
                            rows.append(row("视频色彩原色", color))
                        }
                        if let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String {
                            rows.append(row("视频传递函数", transfer))
                        }
                    }
                }
            }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            rows.append(row("音轨", audioTracks.isEmpty ? "无音轨" : "\(audioTracks.count) 条"))
            if let audio = audioTracks.first, let descriptions = try? await audio.load(.formatDescriptions) {
                let codecs = Array(Set(descriptions.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) })).sorted()
                if !codecs.isEmpty { rows.append(row("音频编码", codecs.joined(separator: ", "))) }
                if let description = descriptions.first,
                   let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    rows.append(row("声道数", String(basic.mChannelsPerFrame)))
                    rows.append(row("采样率", String(format: "%.0f Hz", basic.mSampleRate)))
                }
            }
            var identifiers = Set<String>()
            for format in try await asset.load(.availableMetadataFormats) {
                for item in try await asset.loadMetadata(for: format)
                where item.identifier == .quickTimeMetadataContentIdentifier {
                    if let value = try await item.load(.stringValue), !value.isEmpty { identifiers.insert(value) }
                }
            }
            if identifiers.count == 1, let identifier = identifiers.first {
                rows.append(row("Live Photo 标识", identifier))
                return (rows, identifier)
            }
        } catch {
            if !Task.isCancelled {
                if !rows.contains(where: { $0.key == "HDR" }) { rows.append(row("HDR", "无法确认")) }
                rows.append(row("媒体信息", "部分信息无法读取"))
            }
        }
        return (rows, nil)
    }

    private static func imageDynamicRange(_ source: CGImageSource, index: Int) -> String {
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            return "是（HDR 增益图）"
        }
        // This creates a lazy image without decoding the full-resolution pixels.
        // P3/wide gamut and 10-bit depth alone do not establish HDR.
        guard let image = CGImageSourceCreateImageAtIndex(source, index, [
            kCGImageSourceShouldCache: false, kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceShouldAllowFloat: true
        ] as CFDictionary) else { return "无法确认" }
        if let space = image.colorSpace, CGColorSpaceIsHLGBased(space) { return "是（HLG）" }
        if let space = image.colorSpace, CGColorSpaceIsPQBased(space) { return "是（PQ）" }
        return image.contentHeadroom > 1 ? "是" : "否（SDR）"
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    }

    private static func platformName(_ platform: String) -> String {
        switch platform {
        case "xhs": return "小红书"
        case "douyin": return "抖音"
        case "dewu": return "得物"
        default: return platform
        }
    }

    private static func formattedDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }
}
