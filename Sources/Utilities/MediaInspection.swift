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
        case common, image, video, capture, location, post, sourceDetails, imageDetails, videoDetails

        var title: String {
            switch self {
            case .common: "信息"
            case .image: "图片"
            case .video: "视频"
            case .capture: "拍摄信息"
            case .location: "位置"
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
        enum Availability: Equatable, Sendable {
            case available, missing, loading
        }

        let key: String
        let value: String
        let section: Section
        let availability: Availability

        var isDisplayable: Bool {
            availability == .available && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        init(key: String, value: String?, section: Section = .common, availability: Availability? = nil) {
            self.key = key
            self.value = value ?? "未记录"
            self.availability = availability ?? (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? .available : .missing)
            // Keep useful media properties ahead of identifiers and codec data.
            if ["帖子标题/描述", "来源帖子"].contains(key) {
                self.section = .post
            } else if ["帖子 ID", "博主 ID", "Live Photo 配对标识"].contains(key) {
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

    /// Coordinates remain data for MapKit, never inspector text rows.
    struct Location: Equatable, Sendable {
        let latitude: Double
        let longitude: Double

        init?(latitude: Double, longitude: Double) {
            guard latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            self.latitude = latitude
            self.longitude = longitude
        }

        static func imageGPS(_ properties: [String: Any]) -> Location? {
            guard let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
                  let latitude = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
                  let longitude = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue,
                  let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
                  let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String,
                  ["N", "S"].contains(latitudeRef), ["E", "W"].contains(longitudeRef),
                  latitude >= 0, longitude >= 0 else { return nil }
            return Location(latitude: latitudeRef == "S" ? -latitude : latitude,
                longitude: longitudeRef == "W" ? -longitude : longitude)
        }

        static func iso6709(_ value: String) -> Location? {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.utf8.count <= 128,
                  let regex = try? NSRegularExpression(pattern:
                    #"^([+-][0-9]{2}(?:\.[0-9]+)?)([+-][0-9]{3}(?:\.[0-9]+)?)(?:[+-][0-9]+(?:\.[0-9]+)?)?/$"#),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let latitudeRange = Range(match.range(at: 1), in: value),
                  let longitudeRange = Range(match.range(at: 2), in: value),
                  let latitude = Double(value[latitudeRange]),
                  let longitude = Double(value[longitudeRange]) else { return nil }
            return Location(latitude: latitude, longitude: longitude)
        }
    }

    struct Snapshot: Sendable {
        /// Complete read-only information retains the technical receipt. Only
        /// the presentation filters it; no file attributes or records change.
        let rows: [Row]
        var location: Location? = nil

        var inspectorRows: [Row] {
            rows.filter { $0.isDisplayable && ![.sourceDetails, .imageDetails, .videoDetails].contains($0.section) }
        }
    }

    private struct FileDetails: Sendable {
        var rows: [Row]
        var livePhotoIdentifier: String? = nil
        var location: Location? = nil
        var captureRows: [Row] = []
    }

    static func load(_ request: Request) async -> [Row] {
        await loadSnapshot(request).rows
    }

    static func loadSnapshot(_ request: Request) async -> Snapshot {
        let reader = Task.detached(priority: .userInitiated) { await snapshot(for: request) }
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
                result.append(Row(key: key, value: "读取中…", section: section, availability: .loading))
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
            result.append(Row(key: "合成状态", value: request.compositionState,
                availability: request.compositionState == "未记录合成状态" ? .missing : .available))
        }
        if let imported = request.importedToPhotos {
            result.append(Row(key: "照片图库", value: imported ? "已导入" : "未导入"))
        }
        result.append(Row(key: "原始文件", value: request.isCompositionOutput
            ? "合成产物（非云端原始文件）" : sourceSummary(for: evidenceURLs),
            availability: request.isCompositionOutput || evidenceURLs.contains { MediaSourceProvenance.read(from: $0) != nil }
                ? .available : .missing))
        if request.isCompositionOutput {
            result.append(Row(key: "源文件原始状态", value: sourceURLs.isEmpty
                ? "未记录，无法确认" : sourceSummary(for: sourceURLs),
                availability: sourceURLs.contains { MediaSourceProvenance.read(from: $0) != nil } ? .available : .missing))
        }
        result += attributionRows(evidenceURLs: evidenceURLs, displayedURLs: displayedURLs)
        if let order = unique(evidenceURLs + displayedURLs).compactMap({ MediaDisplayOrder.read(from: $0) }).first {
            result.append(Row(key: "帖子内序号", value: String(order.index)))
            result.append(Row(key: "下载时间", value: formattedDate(Date(timeIntervalSince1970: order.downloadedAt))))
        }
        return result
    }

    private static func snapshot(for request: Request) async -> Snapshot {
        let displayedURLs = unique(request.displayedURLs)
        var result = commonRows(for: request)

        var identifiers: [(image: Bool, value: String?)] = []
        let files = await withTaskGroup(of: (Int, FileDetails).self) { group in
            for (index, url) in displayedURLs.enumerated() {
                group.addTask {
                    let section: Section = FileSystemUtilities.isImage(url) ? .image
                        : FileSystemUtilities.isVideo(url) ? .video : .common
                    let details = await fileRows(url, section: section)
                    return (index, details)
                }
            }
            var results: [(Int, FileDetails)] = []
            for await file in group { results.append(file) }
            return results.sorted { $0.0 < $1.0 }
        }
        guard !Task.isCancelled else { return Snapshot(rows: []) }
        for (index, details) in files {
            result += details.rows
            identifiers.append((FileSystemUtilities.isImage(displayedURLs[index]), details.livePhotoIdentifier))
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
        // The still is the primary location of a Live Photo. Its movie supplies
        // a fallback only when the still has no valid GPS. Inspect displayed
        // files only; an old source path cannot locate the current output.
        let imageLocation = files.first {
            FileSystemUtilities.isImage(displayedURLs[$0.0]) && $0.1.location != nil
        }?.1.location
        // One shooting form describes one displayed resource. Prefer the
        // still of a Live Photo; never combine conflicting camera settings or
        // borrow them from an old source file of a composition output.
        let imageCapture = files.first {
            FileSystemUtilities.isImage(displayedURLs[$0.0]) && !$0.1.captureRows.isEmpty
        }?.1.captureRows
        result += imageCapture ?? files.first { !$0.1.captureRows.isEmpty }?.1.captureRows ?? []
        return Snapshot(rows: ordered(result), location: imageLocation ?? files.compactMap { $0.1.location }.first)
    }

    private static func ordered(_ rows: [Row]) -> [Row] {
        let common = ["素材类型", "合成状态", "照片图库", "来源平台", "博主",
                      "帖子内序号", "原始文件", "源文件原始状态", "下载时间"]
        let media = ["显示尺寸", "时长", "HDR", "帧率", "音轨", "大小", "格式", "文件状态", "媒体信息"]
        let capture = ["相机型号", "镜头", "光圈", "快门", "ISO", "焦距", "等效焦距"]
        return Section.allCases.flatMap { section in
            let priority = section == .common ? common : section == .capture ? capture
                : section == .post ? ["帖子标题/描述", "来源帖子"] : media
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
            return [Row(key: "帖子 ID", value: identities.sorted().joined(separator: "\n")),
                    Row(key: "来源帖子", value: "存在多个来源，无法确定单一帖子"),
                    Row(key: "博主", value: "存在多个来源，无法确定单一博主")]
        }
        if let attribution = attributions.first {
            return [Row(key: "来源平台", value: platformName(attribution.platform)),
                    Row(key: "帖子 ID", value: attribution.postID),
                    Row(key: "来源帖子", value: attributions.compactMap(\.postURL).first),
                    Row(key: "帖子标题/描述", value: postText(attributions)),
                    Row(key: "博主", value: attributions.compactMap(\.authorName).first),
                    Row(key: "博主 ID", value: attributions.compactMap(\.authorID).first)]
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
            rows.append(Row(key: "来源平台", value: nil))
            let noteIDs = Set(unique(evidenceURLs + displayedURLs).compactMap { MediaSourceProvenance.read(from: $0)?.noteID })
            if noteIDs.count == 1, let identifier = noteIDs.first {
                rows.append(Row(key: "帖子 ID", value: identifier))
            }
        }
        rows += [Row(key: "来源帖子", value: nil), Row(key: "帖子标题/描述", value: nil),
                 Row(key: "博主", value: nil), Row(key: "博主 ID", value: nil)]
        return rows
    }

    private static func postText(_ attributions: [MediaPostAttribution]) -> String? {
        let title = attributions.compactMap(\.title).first
        let description = attributions.compactMap(\.postDescription).first
        let values = [title, description].compactMap { $0 }
        var seen = Set<String>()
        let distinct = values.filter { seen.insert($0).inserted }
        return distinct.isEmpty ? nil : distinct.joined(separator: "\n")
    }

    private static func fileRows(_ url: URL, section: Section) async -> FileDetails {
        func row(_ key: String, _ value: String, availability: Row.Availability = .available) -> Row {
            Row(key: key, value: value, section: section, availability: availability)
        }
        var rows: [Row] = []
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey,
                    .contentTypeKey]),
              values.isRegularFile == true else {
            rows.append(row("文件状态", "文件不存在或不可读取"))
            return FileDetails(rows: rows)
        }
        rows.append(row("大小", values.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "无法读取",
            availability: values.fileSize == nil ? .missing : .available))
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
            let dynamicRange = imageDynamicRange(source, index: index)
            rows.append(row("HDR", dynamicRange, availability: dynamicRange == "无法确认" ? .missing : .available))
            let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
            let identifier = (maker?["17"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let identifier { rows.append(row("Live Photo 标识", identifier)) }
            return FileDetails(rows: rows, livePhotoIdentifier: identifier, location: Location.imageGPS(properties),
                captureRows: imageCaptureRows(properties))
        }

        guard FileSystemUtilities.isVideo(url) else {
            if section == .image { rows.append(row("HDR", "无法确认", availability: .missing)) }
            return FileDetails(rows: rows)
        }
        let asset = AVURLAsset(url: url)
        var identifiers = Set<String>()
        var location: Location?
        var cameraMake: String?
        var cameraModel: String?
        // Read metadata independently of track decoding: a partial video may
        // still have a valid geographic tag. Only known location identifiers
        // are accepted, never a title or an inferred place name.
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            guard !Task.isCancelled else { return FileDetails(rows: rows) }
            for item in (try? await asset.loadMetadata(for: format)) ?? [] {
                if item.identifier == .quickTimeMetadataContentIdentifier,
                   let value = try? await item.load(.stringValue), !value.isEmpty {
                    identifiers.insert(value)
                } else if location == nil,
                          item.identifier == .quickTimeMetadataLocationISO6709
                            || item.identifier == .quickTimeUserDataLocationISO6709,
                          let value = try? await item.load(.stringValue) {
                    location = Location.iso6709(value)
                } else if item.identifier == .quickTimeMetadataMake, cameraMake == nil {
                    cameraMake = recordedText(try? await item.load(.stringValue))
                } else if item.identifier == .quickTimeMetadataModel, cameraModel == nil {
                    cameraModel = recordedText(try? await item.load(.stringValue))
                }
            }
        }
        do {
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                rows.append(row("时长", String(format: "%.3f 秒", duration.seconds)))
            }
            let videos = try await asset.loadTracks(withMediaType: .video)
            rows.append(row("视频轨数", String(videos.count)))
            let hdrTracks = try await asset.loadTracks(withMediaCharacteristic: .containsHDRVideo)
            rows.append(row("HDR", videos.isEmpty ? "无法确认" : (hdrTracks.isEmpty ? "否（SDR）" : "是"),
                availability: videos.isEmpty ? .missing : .available))
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
        } catch {
            if !Task.isCancelled {
                if !rows.contains(where: { $0.key == "HDR" }) { rows.append(row("HDR", "无法确认", availability: .missing)) }
                rows.append(row("媒体信息", "部分信息无法读取"))
            }
        }
        let identifier = identifiers.count == 1 ? identifiers.first : nil
        if let identifier { rows.append(row("Live Photo 标识", identifier)) }
        let capture = cameraDescription(make: cameraMake, model: cameraModel)
            .map { [Row(key: "相机型号", value: $0, section: .capture)] } ?? []
        return FileDetails(rows: rows, livePhotoIdentifier: identifier, location: location, captureRows: capture)
    }

    /// ImageIO supplies the actual EXIF exposure values (seconds and F-number),
    /// rather than inferring them from filenames, resolution or device names.
    static func imageCaptureRows(_ properties: [String: Any]) -> [Row] {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let auxiliary = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        var rows: [Row] = []
        func add(_ key: String, _ value: String) { rows.append(Row(key: key, value: value, section: .capture)) }
        func positive(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
            return number.doubleValue
        }
        if let camera = cameraDescription(make: recordedText(tiff[kCGImagePropertyTIFFMake as String]),
                                          model: recordedText(tiff[kCGImagePropertyTIFFModel as String])) {
            add("相机型号", camera)
        }
        if let lens = recordedText(exif[kCGImagePropertyExifLensModel as String])
            ?? recordedText(auxiliary[kCGImagePropertyExifAuxLensModel as String]) { add("镜头", lens) }
        if let aperture = positive(exif[kCGImagePropertyExifFNumber as String]) { add("光圈", "f/\(decimal(aperture))") }
        if let seconds = positive(exif[kCGImagePropertyExifExposureTime as String]) {
            let denominator = (1 / seconds).rounded()
            if seconds < 1, denominator.isFinite, abs(seconds * denominator - 1) < 0.0025 {
                add("快门", "1/\(decimal(denominator, precision: 0)) 秒")
            } else { add("快门", "\(decimal(seconds, precision: 6)) 秒") }
        }
        let ratings = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]
        if let iso = ratings?.compactMap({ positive($0) }).first
            ?? positive(exif[kCGImagePropertyExifISOSpeedRatings as String])
            ?? positive(exif[kCGImagePropertyExifISOSpeed as String]) { add("ISO", decimal(iso, precision: 0)) }
        if let focal = positive(exif[kCGImagePropertyExifFocalLength as String]) { add("焦距", "\(decimal(focal)) mm") }
        if let focal = positive(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String]) {
            add("等效焦距", "\(decimal(focal)) mm（35 mm）")
        }
        return rows
    }

    private static func recordedText(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text.utf8.count > 4096 ? nil : text
    }

    private static func cameraDescription(make: String?, model: String?) -> String? {
        guard let model else { return nil }
        guard let make, model.range(of: make, options: [.anchored, .caseInsensitive]) == nil else { return model }
        return "\(make) \(model)"
    }

    private static func decimal(_ value: Double, precision: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = precision
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
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
