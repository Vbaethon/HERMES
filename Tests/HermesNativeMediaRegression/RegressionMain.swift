import AppKit
import Foundation
import AVFoundation
import CoreImage
import ImageIO
import MapKit

private struct NativeMediaFailure: Error, CustomStringConvertible {
    let description: String
}

@main enum NativeMediaRegression {
    @MainActor static func main() {
        precondition(Bundle.main.bundleIdentifier != "com.codex.Hermes")
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--inspector-location-preview") {
            NSApp.setActivationPolicy(.regular)
        }
        Task { @MainActor in
            do {
                try await runChecks()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Native media regression failed: \(error)\n".utf8))
                exit(1)
            }
        }
        NSApp.run()
    }

    @MainActor static func runChecks() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        precondition(domain.hasPrefix("HermesNativeMediaRegression-"))
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(root.appendingPathComponent("output").path, forKey: "OutputFolderPath")
        defaults.set(root.appendingPathComponent("downloads").path, forKey: "DownloadOutputFolderPath.v1")

        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw NativeMediaFailure(description: message) }
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try expect(condition(), description)
        }
        var checks = 0
        func pass(_ description: String) {
            checks += 1
            print("PASS: \(description)")
        }
        func expectCleanInspectorForm(_ inspector: MediaInspectorController, context: String) throws {
            inspector.view.layoutSubtreeIfNeeded()
            var rowRects: [(String, NSRect)] = []
            let document = inspector.scrollView.documentView!
            for kind in MediaInspection.Section.allCases {
                guard let grid = inspector.sectionGrids[kind] else { continue }
                var managedFields = Set<ObjectIdentifier>()
                for row in 0..<grid.numberOfRows {
                    let key = grid.cell(atColumnIndex: 0, rowIndex: row).contentView as! NSTextField
                    let value = grid.cell(atColumnIndex: 1, rowIndex: row).contentView as! NSTextField
                    managedFields.insert(ObjectIdentifier(key))
                    managedFields.insert(ObjectIdentifier(value))
                    let keyRect = grid.convert(key.alignmentRect(forFrame: key.frame), to: document)
                    let valueRect = grid.convert(value.alignmentRect(forFrame: value.frame), to: document)
                    rowRects.append(("\(kind.title) / \(key.stringValue)", keyRect.union(valueRect)))
                }
                let actualFields = descendants(grid).compactMap { $0 as? NSTextField }
                try expect(actualFields.count == grid.numberOfRows * 2
                    && Set(actualFields.map(ObjectIdentifier.init)) == managedFields,
                    "\(context): \(kind.title) must have exactly its current cell views; rows=\(grid.numberOfRows), visible fields=\(actualFields.count)")
            }
            for (index, row) in rowRects.enumerated() {
                for other in rowRects.dropFirst(index + 1) {
                    let overlap = row.1.intersection(other.1)
                    try expect(overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5,
                        "\(context): inspector rows must not overlap: \(row.0) \(row.1), \(other.0) \(other.1)")
                }
            }
        }

        let image = root.appendingPathComponent("source.png")
        let secondImage = root.appendingPathComponent("second.png")
        let movie = root.appendingPathComponent("source.mov")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 19, pixelsHigh: 11,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let fixtureColor = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.8, alpha: 1)
        for y in 0..<11 {
            for x in 0..<19 { bitmap.setColor(fixtureColor, atX: x, y: y) }
        }
        let png = bitmap.representation(using: .png, properties: [:])!
        try png.write(to: image)
        try png.write(to: secondImage)
        var formatImages = [image]
        for (suffix, type) in [("jpg", "public.jpeg"), ("jpeg", "public.jpeg"), ("jfif", "public.jpeg"),
                               ("heic", "public.heic"), ("heif", "public.heic")] {
            let url = root.appendingPathComponent("no-metadata.\(suffix)")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, bitmap.cgImage!, nil)
            try expect(CGImageDestinationFinalize(destination), "\(suffix) fixture must be encoded")
            formatImages.append(url)
        }
        let webp = root.appendingPathComponent("no-metadata.webp")
        try Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")!.write(to: webp)
        formatImages.append(webp)
        for url in formatImages {
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            try expect(source != nil && CGImageSourceCreateImageAtIndex(source!, 0, nil) != nil,
                "\(url.pathExtension) fixture must be a real decodable image")
            let snapshot = await MediaInspection.loadSnapshot(.init(name: url.lastPathComponent, sourceURLs: [url],
                displayedURLs: [url], kind: "照片", compositionState: "不适用"))
            try expect(snapshot.location == nil && !snapshot.inspectorRows.contains {
                [.capture, .location, .post].contains($0.section) || !$0.isDisplayable
            }, "every supported image format must hide missing information using the same evidence rule")
            try expect(snapshot.inspectorRows.contains { $0.key == "显示尺寸" },
                "\(url.pathExtension) must preserve its actual image information")
        }
        pass("JPG, JPEG, JFIF, HEIC, HEIF, PNG and WebP share missing-information visibility while retaining real properties")
        let locatedImage = root.appendingPathComponent("located.jpg")
        let relocatedImage = root.appendingPathComponent("relocated.jpg")
        let cameraProperties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "iPhone 16 Pro back triple camera 6.86mm f/1.78",
                kCGImagePropertyExifFNumber: 1.78, kCGImagePropertyExifExposureTime: 1.0 / 125,
                kCGImagePropertyExifISOSpeedRatings: [80], kCGImagePropertyExifFocalLength: 6.86,
                kCGImagePropertyExifFocalLenIn35mmFilm: 24]
        ]
        func writeJPEGImage(_ url: URL, properties: [CFString: Any]) throws {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, bitmap.cgImage!, properties as CFDictionary)
            try expect(CGImageDestinationFinalize(destination), "EXIF fixture image must be written")
        }
        func writeGPSImage(_ url: URL, latitude: Double, longitude: Double, latitudeRef: String, longitudeRef: String) throws {
            var properties = cameraProperties
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: latitude, kCGImagePropertyGPSLatitudeRef: latitudeRef,
                kCGImagePropertyGPSLongitude: longitude, kCGImagePropertyGPSLongitudeRef: longitudeRef]
            try writeJPEGImage(url, properties: properties)
        }
        try writeGPSImage(locatedImage, latitude: 33.865, longitude: 151.2094, latitudeRef: "S", longitudeRef: "E")
        try writeGPSImage(relocatedImage, latitude: 37.7749, longitude: 122.4194, latitudeRef: "N", longitudeRef: "W")
        let photoLocation = MediaInspection.Location(latitude: -33.865, longitude: 151.2094)!
        let otherPhotoLocation = MediaInspection.Location(latitude: 37.7749, longitude: -122.4194)!
        let videoLocation = MediaInspection.Location(latitude: 28.9534, longitude: 118.8718)!
        let locatedBytes = try Data(contentsOf: locatedImage)
        let locatedSnapshot = await MediaInspection.loadSnapshot(.init(name: "located", sourceURLs: [locatedImage],
            displayedURLs: [locatedImage], kind: "照片", compositionState: "不适用"))
        try expect(locatedSnapshot.location == photoLocation, "ImageIO GPS must preserve southern/eastern hemispheres")
        for (key, value) in [("相机型号", "Apple iPhone 16 Pro"), ("镜头", "iPhone 16 Pro back triple camera 6.86mm f/1.78"),
                             ("光圈", "f/1.78"), ("快门", "1/125 秒"), ("ISO", "80"),
                             ("焦距", "6.86 mm"), ("等效焦距", "24 mm（35 mm）")] {
            try expect(locatedSnapshot.inspectorRows.contains { $0.section == .capture && $0.key == key && $0.value == value },
                "the inspector must read and format actual \(key) from a real EXIF image")
        }
        let invalidCameraRows = MediaInspection.imageCaptureRows([
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Apple"],
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifFNumber as String: -1,
                kCGImagePropertyExifExposureTime as String: Double.nan, kCGImagePropertyExifISOSpeedRatings as String: [0],
                kCGImagePropertyExifFocalLength as String: Double.infinity]])
        try expect(invalidCameraRows.isEmpty, "invalid shooting values and a manufacturer alone must not invent camera settings")
        let longExposureRows = MediaInspection.imageCaptureRows([
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Canon", kCGImagePropertyTIFFModel as String: "Canon EOS R5"],
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifExposureTime as String: 2.5]])
        try expect(longExposureRows.contains { $0.key == "相机型号" && $0.value == "Canon EOS R5" }
            && longExposureRows.contains { $0.key == "快门" && $0.value == "2.5 秒" },
            "camera brands must not repeat and long exposures must remain seconds")
        pass("real EXIF camera, lens, aperture, shutter, ISO and focal lengths with missing/invalid-value handling")
        let otherSnapshot = await MediaInspection.loadSnapshot(.init(name: "relocated", sourceURLs: [relocatedImage],
            displayedURLs: [relocatedImage], kind: "照片", compositionState: "不适用"))
        try expect(otherSnapshot.location == otherPhotoLocation, "ImageIO GPS must preserve northern/western hemispheres")
        try expect(MediaInspection.Location.iso6709("+28.9534+118.8718+072.355/") == videoLocation
            && MediaInspection.Location.iso6709("-33.8650+151.2094-004.250/") == photoLocation
            && MediaInspection.Location.iso6709("+00+000/") == .init(latitude: 0, longitude: 0),
            "QuickTime decimal ISO 6709 must preserve signs and accept valid zero coordinates")
        for invalid in ["", "+91.0000+118.8718/", "+28.9534+181.0000/", "+28.9534+118.8718", "NaN,NaN", "Sydney"] {
            try expect(MediaInspection.Location.iso6709(invalid) == nil, "invalid or inferred locations must be rejected")
        }
        try expect(MediaInspection.Location(latitude: .nan, longitude: 0) == nil
            && MediaInspection.Location(latitude: 0, longitude: .infinity) == nil
            && MediaInspection.Location.imageGPS([kCGImagePropertyGPSDictionary as String:
                [kCGImagePropertyGPSLatitude as String: 33.865, kCGImagePropertyGPSLongitude as String: 151.2094]]) == nil,
            "nonfinite coordinates and GPS with missing hemisphere references must not produce a map")
        let sourceOnlyLocation = await MediaInspection.loadSnapshot(.init(name: "output", sourceURLs: [locatedImage],
            displayedURLs: [image], kind: "照片", compositionState: "不适用", isCompositionOutput: true))
        try expect(sourceOnlyLocation.location == nil, "a source path must never locate an output that has no GPS")
        try expect(!sourceOnlyLocation.rows.contains { $0.section == .capture },
            "a source camera must not be attributed to a displayed output with no shooting metadata")
        try expect(!locatedSnapshot.rows.contains { ["纬度", "经度", "经纬度"].contains($0.key)
            || $0.value.contains("151.2094") || $0.value.contains("33.865") },
            "geographic coordinates must remain map data and never appear in inspector rows")
        pass("real image GPS, hemisphere signs, valid zero coordinates and invalid/missing location handling")
        // Resource transfer depends on real readable files, not successful
        // decoding. The malformed motion fixture also exercises unavailable
        // metadata without pretending the file is a verified Live Photo.
        try Data("not a decoded video".utf8).write(to: movie)

        let unrecorded = MediaInspection.Request(name: "source", sourceURLs: [image, movie],
            displayedURLs: [image, movie], kind: "Live Photo", compositionState: "未合成")
        let originalBytes = try Data(contentsOf: image)
        let originalMovieBytes = try Data(contentsOf: movie)
        let originalRevision = MediaPairRevision(image: image, movie: movie)
        let unknownRows = await MediaInspection.load(unrecorded)
        try expect(unknownRows.contains { $0.key == "原始文件" && $0.value == "未记录，无法确认" },
            "unrecorded local media must remain unknown instead of being labelled original")
        try expect(!unknownRows.contains { $0.value.contains("云端原始文件") && !$0.value.contains("非云端") },
            "an existing readable file cannot itself prove cloud originality")
        try expect(unknownRows.contains { $0.section == .image && $0.key == "显示尺寸" && $0.value == "19 × 11 像素" },
            "the inspector must read real pixel dimensions from the still image")
        try expect(!unknownRows.contains { ["名称", "文件名", "路径", "创建时间", "修改时间", "原照片/视频路径"].contains($0.key) }
            && unknownRows.filter { $0.key == "大小" }.allSatisfy { !$0.value.contains("字节") },
            "the inspector must omit managed filenames, paths, file dates and exact byte counts")
        try expect(unknownRows.contains { $0.section == .image && $0.key == "HDR" && $0.value == "否（SDR）" }
            && unknownRows.contains { $0.section == .video && $0.key == "HDR" && $0.value == "无法确认" },
            "ordinary images must report SDR and malformed videos must not invent an HDR result")
        let unknownSnapshot = await MediaInspection.loadSnapshot(unrecorded)
        try expect(!unknownSnapshot.inspectorRows.contains {
            ["原始文件", "来源平台", "博主", "来源帖子", "帖子标题/描述"].contains($0.key)
                || ($0.section == .video && $0.key == "HDR")
        }, "missing metadata must stay out of the form while its diagnostic state remains available")
        try expect(unknownSnapshot.inspectorRows.contains { $0.section == .image && $0.key == "HDR" && $0.value == "否（SDR）" },
            "a confirmed negative result is real information and must remain visible")
        let presentation = MediaInspection.Snapshot(rows: [
            .init(key: "缺失字段", value: nil), .init(key: "空字段", value: " \n\t"),
            .init(key: "读取中字段", value: "读取中…", availability: .loading),
            .init(key: "帖子标题/描述", value: "未记录"), .init(key: "音轨", value: "无音轨", section: .video)
        ])
        try expect(presentation.inspectorRows.map(\.key) == ["帖子标题/描述", "音轨"],
            "availability must describe the evidence rather than blacklist words in actual metadata")
        if !CommandLine.arguments.contains("--sidebar-performance") {
            let context = CIContext()
            let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
            let sdr = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: rect)
            let hdr = CIImage(color: CIColor(red: 4, green: 2, blue: 1,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!).cropped(to: rect)
            let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
            let gainMap = root.appendingPathComponent("gain-map.jpg")
            let p3SDR = root.appendingPathComponent("wide-gamut-sdr.jpg")
            try context.jpegRepresentation(of: sdr, colorSpace: p3, options: [.hdrImage: hdr])!.write(to: gainMap)
            try context.jpegRepresentation(of: sdr, colorSpace: p3, options: [:])!.write(to: p3SDR)
            for (url, expectedHDR) in [(gainMap, true), (p3SDR, false)] {
                let rows = await MediaInspection.load(.init(name: url.lastPathComponent, sourceURLs: [url],
                    displayedURLs: [url], kind: "照片", compositionState: "不适用"))
                try expect(rows.contains { $0.section == .image && $0.key == "HDR"
                    && $0.value.hasPrefix(expectedHDR ? "是" : "否") },
                    "gain-map HDR must be distinguished from a wide-gamut SDR image")
            }
            for (name, spaceName) in [("hlg", CGColorSpace.itur_2100_HLG), ("pq", CGColorSpace.itur_2100_PQ)] {
                let url = root.appendingPathComponent("\(name).heic")
                let space = CGColorSpace(name: spaceName)!
                try context.heif10Representation(of: hdr, colorSpace: space, options: [:]).write(to: url)
                let rows = await MediaInspection.load(.init(name: name, sourceURLs: [url],
                    displayedURLs: [url], kind: "照片", compositionState: "不适用"))
                try expect(rows.contains { $0.section == .image && $0.key == "HDR" && $0.value.hasPrefix("是") },
                    "\(name.uppercased()) images without a gain map must report HDR")
            }
            let sdr10 = root.appendingPathComponent("10-bit-sdr.heic")
            try context.heif10Representation(of: sdr, colorSpace: p3, options: [:]).write(to: sdr10)
            let sdr10Rows = await MediaInspection.load(.init(name: "10-bit SDR", sourceURLs: [sdr10],
                displayedURLs: [sdr10], kind: "照片", compositionState: "不适用"))
            try expect(sdr10Rows.contains { $0.key == "HDR" && $0.value == "否（SDR）" },
                "10-bit image depth alone must not establish HDR")
            for (transfer, suffix, fileType) in [
                (AVVideoTransferFunction_ITU_R_709_2, "mov", AVFileType.mov),
                (AVVideoTransferFunction_ITU_R_2100_HLG, "mov", .mov),
                (AVVideoTransferFunction_SMPTE_ST_2084_PQ, "mov", .mov),
                (AVVideoTransferFunction_ITU_R_709_2, "mp4", .mp4),
                (AVVideoTransferFunction_ITU_R_709_2, "m4v", .m4v)
            ] {
                let url = root.appendingPathComponent("\(transfer).\(suffix)")
                let isHDR = transfer != AVVideoTransferFunction_ITU_R_709_2
                let hasLocation = !isHDR && suffix == "mov"
                let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
                if hasLocation {
                    let locationTag = AVMutableMetadataItem()
                    locationTag.identifier = .quickTimeMetadataLocationISO6709
                    locationTag.value = "+28.9534+118.8718+072.355/" as NSString
                    locationTag.dataType = kCMMetadataBaseDataType_UTF8 as String
                    let makeTag = AVMutableMetadataItem()
                    makeTag.identifier = .quickTimeMetadataMake
                    makeTag.value = "Apple" as NSString
                    makeTag.dataType = kCMMetadataBaseDataType_UTF8 as String
                    let modelTag = AVMutableMetadataItem()
                    modelTag.identifier = .quickTimeMetadataModel
                    modelTag.value = "Movie Camera" as NSString
                    modelTag.dataType = kCMMetadataBaseDataType_UTF8 as String
                    writer.metadata = [locationTag, makeTag, modelTag]
                }
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
                    AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: isHDR ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: transfer,
                        AVVideoYCbCrMatrixKey: isHDR ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2]
                ])
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                    sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
                writer.add(input)
                try expect(writer.startWriting(), "video HDR fixture writer must start")
                writer.startSession(atSourceTime: .zero)
                var buffer: CVPixelBuffer?
                CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
                CVPixelBufferLockBaseAddress(buffer!, [])
                memset(CVPixelBufferGetBaseAddress(buffer!)!, 100, CVPixelBufferGetBytesPerRow(buffer!) * 64)
                CVPixelBufferUnlockBaseAddress(buffer!, [])
                for frame in 0..<3 {
                    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                    try expect(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)),
                        "video HDR fixture frame must append")
                }
                input.markAsFinished()
                await writer.finishWriting()
                try expect(writer.status == .completed, "video HDR fixture must finish: \(writer.error as Any)")
                let rows = await MediaInspection.load(.init(name: transfer, sourceURLs: [url],
                    displayedURLs: [url], kind: "视频", compositionState: "不适用"))
                try expect(rows.contains { $0.section == .video && $0.key == "HDR"
                    && $0.value == (isHDR ? "是" : "否（SDR）") },
                    "SDR and HLG/PQ videos must be identified from their HDR characteristics")
                if !hasLocation {
                    for (urls, kind, state, output) in [([url], "视频", "不适用", false),
                        ([image, url], "Live Photo", "未合成", false), ([url], "Live Photo", "已合成", true)] {
                        let snapshot = await MediaInspection.loadSnapshot(.init(name: suffix, sourceURLs: urls,
                            displayedURLs: urls, kind: kind, compositionState: state, isCompositionOutput: output))
                        try expect(snapshot.location == nil && !snapshot.inspectorRows.contains {
                            [.capture, .location, .post].contains($0.section) || !$0.isDisplayable
                        }, "\(suffix) \(kind) must use the same visibility rule for missing information")
                        try expect(snapshot.inspectorRows.contains { $0.key == "音轨" && $0.value == "无音轨" },
                            "confirmed absence of an audio track must remain visible")
                    }
                }
                if hasLocation {
                    let videoBytes = try Data(contentsOf: url)
                    for (photos, expected) in [([url], videoLocation), ([image, url], videoLocation),
                                               ([url, locatedImage], photoLocation)] {
                        let snapshot = await MediaInspection.loadSnapshot(.init(name: "video GPS", sourceURLs: photos,
                            displayedURLs: photos, kind: "Live Photo", compositionState: "未合成"))
                        try expect(snapshot.location == expected,
                            "real QuickTime GPS must locate videos and Live Photos, preferring still GPS regardless of file order")
                        let expectedCamera = photos.contains(locatedImage) ? "Apple iPhone 16 Pro" : "Apple Movie Camera"
                        try expect(snapshot.rows.filter { $0.key == "相机型号" }.map(\.value) == [expectedCamera],
                            "QuickTime camera metadata must provide a fallback without overriding the Live Photo still")
                    }
                    try expect(try Data(contentsOf: url) == videoBytes && Data(contentsOf: locatedImage) == locatedBytes,
                        "reading GPS must preserve the exact image and movie bytes")
                    pass("real QuickTime location metadata, Live Photo movie fallback and still-location priority without media changes")
                }
            }
            pass("HDR gain maps, HLG/PQ stills and videos, wide-gamut SDR and 10-bit SDR stills are distinguished")
            pass("MOV, MP4, M4V, uncomposed Live Photos and composition outputs share missing-information visibility")
        }
        pass("unrecorded sources remain unknown and malformed media is inspected without inventing provenance")

        let attribution = MediaPostAttribution(platform: "小红书", postID: "note-fixture",
            postURL: URL(string: "https://www.xiaohongshu.com/explore/note-fixture?xsec_token=private-fixture-token"),
            title: "来源标题", authorName: "来源博主", authorID: "author-fixture", postDescription: "来源帖子描述")
        attribution.write(to: image)
        let receipt = MediaSourceProvenance(state: .cloudOriginal, noteID: "note-fixture",
            imageFileID: "image-fixture", objectKey: "livephoto/fixture", sourceHost: "cdn.example.test",
            sourceField: "images_list.fileid", sha256: MediaSourceProvenance.hash(of: image))
        receipt.write(to: image)
        receipt.write(to: movie)
        let savedReceipt = MediaSourceProvenance.read(from: image)
        let recordedSnapshot = await MediaInspection.loadSnapshot(unrecorded)
        let recordedRows = recordedSnapshot.rows
        try expect(["帖子 ID", "博主 ID", "图片资源 ID", "媒体资源标识", "下载时 SHA-256"].allSatisfy { key in
            recordedRows.contains { $0.key == key } && !recordedSnapshot.inspectorRows.contains { $0.key == key }
        } && MediaSourceProvenance.read(from: image) == savedReceipt,
            "technical IDs and hashes must stay in the read-only snapshot and file receipt while hidden from the inspector")
        let coreEnd = recordedRows.lastIndex { [.common, .image, .video].contains($0.section) }!
        let technicalStart = recordedRows.firstIndex { [.sourceDetails, .imageDetails, .videoDetails].contains($0.section) }!
        try expect(coreEnd < technicalStart,
            "post identifiers, source hosts and hashes must follow all useful image/video information")
        try expect(recordedRows.firstIndex { $0.key == "HDR" }! < recordedRows.firstIndex { $0.key == "下载时 SHA-256" }!,
            "HDR and dimensions must appear before low-priority technical receipts")
        try expect(recordedRows.contains { $0.key == "博主" && $0.value == "来源博主" },
            "the inspector must display the recorded author")
        try expect(recordedRows.contains { $0.key == "帖子标题/描述" && $0.value == "来源标题\n来源帖子描述" },
            "the recorded source post title and description must both be retained")
        try expect(recordedRows.contains { $0.key == "原始文件" && $0.value.contains("原始") && !$0.value.contains("无法确认") },
            "a current original-source receipt must be distinguishable from missing provenance")
        try expect(!recordedRows.contains { $0.value.contains("private-fixture-token") || $0.value.contains("xsec_token") },
            "post attribution must not expose authenticated share-page tokens")
        let composedRows = await MediaInspection.load(.init(name: "composed", sourceURLs: [image, movie],
            displayedURLs: [image, movie], kind: "Live Photo", compositionState: "已合成", isCompositionOutput: true))
        try expect(composedRows.contains { $0.key == "原始文件" && $0.value == "合成产物（非云端原始文件）" },
            "a composition output must remain distinct from its original source receipt")
        try expect(try Data(contentsOf: image) == originalBytes, "inspection must preserve the still's data fork")
        try expect(try Data(contentsOf: movie) == originalMovieBytes, "inspection must preserve the motion's data fork")
        try expect(MediaPairRevision(image: image, movie: movie) == originalRevision,
            "inspection must preserve source filesystem revisions")
        pass("source post and author are retained, authentication is omitted and composition outputs are labelled separately")
        pass("technical receipt identifiers and hashes remain intact without frontend rows")

        let staleImage = root.appendingPathComponent("changed-source.png")
        try png.write(to: staleImage)
        receipt.write(to: staleImage)
        try (png + Data([0])).write(to: staleImage)
        let staleRows = await MediaInspection.load(.init(name: "changed", sourceURLs: [staleImage],
            displayedURLs: [staleImage], kind: "照片", compositionState: "不适用"))
        try expect(staleRows.contains { $0.key == "原始文件" && $0.value == "待确认（文件已变更或记录失效）" },
            "a receipt for changed bytes must lose its original-source confirmation")
        pass("changing a source invalidates the original-file confirmation")

        let model = ImporterModel(refreshOnInit: false)
        let pair = PairItem(imageURL: image, videoURL: movie)
        model.downloadPairs = [pair]
        model.downloadPhotos = [secondImage]
        model.downloadFilter = .all
        model.selection = .downloads
        let pairID = "pair:\(pair.id)"
        let photoID = "photo:\(secondImage.standardizedFileURL.path)"
        let completedSentinel = try JSONEncoder().encode([CompletedItem(imagePath: image.path, moviePath: movie.path)])
        defaults.set(completedSentinel, forKey: "CompletedRecords.v1")
        defaults.set(completedSentinel, forKey: "DownloadCompletedRecords.v1")
        let first = MainWindowController(model: model)
        defer { first.window?.orderOut(nil) }
        try expect(!first.inspectorVisible, "the inspector must start closed when there is no preference")
        first.showWindow(nil)
        let split = first.window!.contentViewController as! NSSplitViewController
        try expect(split.splitViewItems.count == 3 && split.splitViewItems.last!.isCollapsed,
            "the native inspector split item must start collapsed")
        try await Task.sleep(for: .milliseconds(50))
        first.window!.setContentSize(NSSize(width: 1360, height: 800))
        split.splitView.setPosition(280, ofDividerAt: 0)
        first.window!.contentView!.layoutSubtreeIfNeeded()
        let sidebarBeforeInspector = split.splitViewItems[0].viewController.view.frame.width
        let windowBeforeInspector = first.window!.frame
        first.window!.makeKeyAndOrderFront(nil)
        let nativeToggle = first.window!.toolbar!.items.first { $0.itemIdentifier == .toggleInspector }!
        try expect(nativeToggle.action != nil, "the system inspector toolbar item must expose its native action")
        try expect(NSApp.sendAction(nativeToggle.action!, to: nativeToggle.target, from: nativeToggle),
            "the actual native toolbar inspector action must reach the split-view responder")
        try await waitUntil("the actual toolbar action must open the inspector") { first.inspectorVisible }
        try await waitUntil("the native inspector animation must finish") { !first.inspectorController.isPaneTransitioning }
        first.window!.contentView!.layoutSubtreeIfNeeded()
        print("Inspector toggle geometry: sidebar \(sidebarBeforeInspector) → \(split.splitViewItems[0].viewController.view.frame.width), window \(windowBeforeInspector) → \(first.window!.frame), panes=\(split.splitViewItems.map { $0.viewController.view.frame.width })")
        try expect(abs(split.splitViewItems[0].viewController.view.frame.width - sidebarBeforeInspector) < 0.5,
            "opening the inspector must preserve the user's sidebar width when the content has room")
        try expect(first.inspectorVisible && !split.splitViewItems.last!.isCollapsed,
            "opening the inspector must expand its native split item")
        try expect(defaults.bool(forKey: "HERMESInspectorVisible.v1"), "opening the inspector must persist immediately")
        let restored = MainWindowController(model: model)
        defer { restored.window?.orderOut(nil) }
        try expect(restored.inspectorVisible, "recreating the window must restore an open inspector")
        restored.setInspectorVisible(false)
        let closed = MainWindowController(model: model)
        defer { closed.window?.orderOut(nil) }
        try expect(!closed.inspectorVisible && defaults.object(forKey: "HERMESInspectorVisible.v1") as? Bool == false,
            "an explicitly closed inspector must remain closed after recreation")
        pass("native inspector defaults closed and persists both open and closed states across window recreation")

        let inspector = first.inspectorController
        try expect(descendants(inspector.view).compactMap { $0 as? NSScrollView }.count == 1
            && inspector.scrollView.borderType == .noBorder && !inspector.scrollView.drawsBackground,
            "the native form must use exactly one continuous borderless transparent scroll view")
        try expect(!descendants(inspector.view).contains { $0 is NSTableView }
            && !(inspector.view is NSVisualEffectView) && !inspector.view.isOpaque,
            "the transparent form must let the split item's system glass show through")
        model.selectedDownloadItemIDs = [pairID]
        try await waitUntil("single selection must populate native common, image and video form sections") {
            !inspector.isLoading && inspector.sectionGrids[.common] != nil
                && inspector.sectionGrids[.image] != nil && inspector.sectionGrids[.video] != nil
        }
        if CommandLine.arguments.contains("--sidebar-performance") {
            // Measure main-run-loop stalls during real native pane actions. This
            // is responsiveness telemetry, not a claim about display/GPU FPS.
            for index in 0..<100 {
                let photo = root.appendingPathComponent("grid-\(index).png")
                try png.write(to: photo)
                model.downloadPhotos.append(photo)
            }
            first.window!.setContentSize(NSSize(width: 1440, height: 900))
            try await Task.sleep(for: .milliseconds(600))
            var gaps: [Double] = []
            let monitor = Task { @MainActor in
                var last = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(1))
                    let now = ProcessInfo.processInfo.systemUptime
                    gaps.append((now - last) * 1000)
                    last = now
                }
            }
            for action in [NSToolbarItem.Identifier.toggleInspector, .toggleSidebar] {
                let item = first.window!.toolbar!.items.first { $0.itemIdentifier == action }!
                var retained = 0
                for _ in 0..<6 {
                    let grid = inspector.sectionGrids[.common]
                    NSApp.sendAction(item.action!, to: item.target, from: item)
                    try await Task.sleep(for: .milliseconds(350))
                    if grid === inspector.sectionGrids[.common] { retained += 1 }
                }
                print("Pane \(action.rawValue): retained form on \(retained)/6 toggles")
            }
            monitor.cancel()
            await monitor.value
            let sorted = gaps.sorted()
            print(String(format: "Main-loop gaps: p95=%.2fms p99=%.2fms max=%.2fms over16.7ms=%d samples=%d",
                sorted[Int(Double(sorted.count - 1) * 0.95)], sorted[Int(Double(sorted.count - 1) * 0.99)],
                sorted.last ?? 0, gaps.filter { $0 > 16.7 }.count, gaps.count))
            return
        }
        // The production inspector keeps its native material under a full-size
        // toolbar, while its single form scroll view must respect the safe area.
        try await Task.sleep(for: .milliseconds(350))
        first.window!.contentView!.layoutSubtreeIfNeeded()
        let fullSizeWindow = first.window!
        let safeArea = inspector.view.safeAreaLayoutGuide.frame
        let safeAreaWindowRect = inspector.view.convert(safeArea, to: nil)
        let scrollWindowRect = inspector.scrollView.convert(inspector.scrollView.bounds, to: nil)
        let informationTitle = descendants(inspector.view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "信息" }!
        let informationWindowRect = informationTitle.convert(informationTitle.bounds, to: nil)
        let titleClipRect = informationTitle.convert(informationTitle.bounds, to: inspector.scrollView.contentView)
        print("Full-size inspector geometry: safeInsets=\(inspector.view.safeAreaInsets), safeArea=\(safeAreaWindowRect), contentLayout=\(fullSizeWindow.contentLayoutRect), scroll=\(scrollWindowRect), contentInsets=\(inspector.scrollView.contentInsets), clip=\(inspector.scrollView.contentView.bounds), informationTitle=\(informationWindowRect)")
        try expect(fullSizeWindow.styleMask.contains(.fullSizeContentView) && fullSizeWindow.toolbar != nil,
            "the header regression must exercise the real production full-size toolbar window")
        try expect(inspector.view.safeAreaInsets.top > 0
            && abs(scrollWindowRect.maxY - safeAreaWindowRect.maxY) < 0.5
            && scrollWindowRect.maxY <= fullSizeWindow.contentLayoutRect.maxY + 0.5,
            "the form scroll view must begin below the native full-size toolbar safe area")
        try expect(informationWindowRect.maxY <= fullSizeWindow.contentLayoutRect.maxY - 15
            && titleClipRect.maxY <= inspector.scrollView.contentView.bounds.maxY + 0.5
            && inspector.scrollView.contentView.bounds.maxY - titleClipRect.maxY < 18,
            "the 信息 heading must remain visible at the form top below the native toolbar")
        try expect(inspector.view.bounds.height > inspector.scrollView.bounds.height,
            "the native sidebar material must retain its full-height background behind the toolbar")
        pass("the real full-size window places the form heading below its native toolbar safe area")
        let retainedFormGrid = inspector.sectionGrids[.common]!
        let retainedRows = inspector.rows
        for identifier in [NSToolbarItem.Identifier.toggleInspector, .toggleSidebar] {
            let item = first.window!.toolbar!.items.first { $0.itemIdentifier == identifier }!
            for _ in 0..<2 {
                NSApp.sendAction(item.action!, to: item.target, from: item)
                try await waitUntil("the native pane transition must complete") { !inspector.isPaneTransitioning }
                try expect(inspector.sectionGrids[.common] === retainedFormGrid && inspector.rows == retainedRows,
                    "toggling \(identifier.rawValue) must retain the form: grid=\(inspector.sectionGrids[.common] === retainedFormGrid), rows=\(inspector.rows == retainedRows), status=\(inspector.statusText), selection=\(model.selectedDownloadItemIDs), transitioning=\(inspector.isPaneTransitioning)")
                try expect(!inspector.isPaneTransitioning, "pane completion must resume inspection and layout")
            }
        }
        // Selection changes made while hidden still need fresh information.
        first.setInspectorVisible(false)
        model.selectedDownloadItemIDs = [photoID]
        first.setInspectorVisible(true)
        try await waitUntil("reopening must inspect the current selection rather than reuse stale rows") {
            inspector.sectionGrids[.image] != nil && inspector.sectionGrids[.video] == nil
        }
        model.selectedDownloadItemIDs = [pairID]
        try await waitUntil("restoring pair selection must restore both media sections") {
            !inspector.isLoading && inspector.sectionGrids[.image] != nil && inspector.sectionGrids[.video] != nil
        }
        pass("pane animations reuse the loaded form and reopening refreshes changed selections")

        let sidebarItem = split.splitViewItems[0]
        func sidebarWidth() -> CGFloat { sidebarItem.viewController.view.frame.width }
        func layoutWindow() { first.window!.contentView!.layoutSubtreeIfNeeded() }
        func togglePane(_ identifier: NSToolbarItem.Identifier) async throws {
            first.window!.makeKeyAndOrderFront(nil)
            let item = first.window!.toolbar!.items.first { $0.itemIdentifier == identifier }!
            try expect(NSApp.sendAction(item.action!, to: item.target, from: item),
                "pane regression must use the real system toolbar action")
            try await waitUntil("native pane animation must finish") { !inspector.isPaneTransitioning }
            try await Task.sleep(for: .milliseconds(50))
            layoutWindow()
        }
        for windowWidth: CGFloat in [1200, 1360] {
            first.setInspectorVisible(false)
            first.window!.setContentSize(NSSize(width: windowWidth, height: 800))
            try await Task.sleep(for: .milliseconds(50))
            layoutWindow()
            for width: CGFloat in [180, 240, 320] {
                split.splitView.setPosition(width, ofDividerAt: 0)
                try await Task.sleep(for: .milliseconds(50))
                layoutWindow()
                let chosenWidth = sidebarWidth()
                let frame = first.window!.frame
                for _ in 0..<2 {
                    try await togglePane(.toggleInspector)
                    try expect(abs(sidebarWidth() - chosenWidth) < 0.5 && !sidebarItem.isCollapsed,
                        "inspector toggles must preserve independently chosen sidebar widths: window=\(windowWidth), chosen=\(chosenWidth), actual=\(sidebarWidth()), collapsed=\(sidebarItem.isCollapsed), frame=\(first.window!.frame), panes=\(split.splitViewItems.map { $0.viewController.view.frame.width })")
                    try expect(first.window!.frame.height == frame.height,
                        "native horizontal pane actions must preserve window height")
                }
            }
        }
        first.setInspectorVisible(true)
        try await Task.sleep(for: .milliseconds(50))
        split.splitView.setPosition(240, ofDividerAt: 0)
        try await Task.sleep(for: .milliseconds(50))
        layoutWindow()
        let chosenSidebarWidth = sidebarWidth()
        for width: CGFloat in [1480, 1400, 1360] {
            first.window!.setContentSize(NSSize(width: width, height: 800))
            try await Task.sleep(for: .milliseconds(50))
            layoutWindow()
            try expect(abs(sidebarWidth() - chosenSidebarWidth) < 0.5,
                "ordinary window resizing must be absorbed by the content pane before the sidebar")
        }
        first.window!.setContentSize(NSSize(width: 900, height: 800))
        try await Task.sleep(for: .milliseconds(100))
        layoutWindow()
        try expect(first.inspectorVisible && split.splitViewItems[1].viewController.view.frame.width >= 520,
            "a narrow window must preserve native inspector and content constraints")
        try expect(sidebarItem.isCollapsed || sidebarWidth() >= sidebarItem.minimumThickness,
            "AppKit must respect its sidebar minimum when it constrains a programmatic resize")
        first.window!.setContentSize(NSSize(width: 1360, height: 800))
        try await Task.sleep(for: .milliseconds(100))
        layoutWindow()
        if sidebarItem.isCollapsed { try await togglePane(.toggleSidebar) }
        split.splitView.setPosition(chosenSidebarWidth, ofDividerAt: 0)
        try await Task.sleep(for: .milliseconds(50))
        layoutWindow()
        try await togglePane(.toggleSidebar)
        try expect(sidebarItem.isCollapsed, "native sidebar action must collapse the navigation pane")
        for _ in 0..<2 {
            try await togglePane(.toggleInspector)
            try expect(sidebarItem.isCollapsed,
                "inspector toggles must not reopen a sidebar the user explicitly closed")
        }
        try await togglePane(.toggleSidebar)
        try expect(abs(sidebarWidth() - chosenSidebarWidth) < 0.5,
            "native sidebar action must restore the user's previous width")
        pass("native pane actions preserve sidebar widths, ordinary resizes use the content pane and narrow windows respect native constraints")

        let stableFrame = first.window!.frame
        let savedImport = model.importToPhotos
        let savedAlbum = model.addToAlbum
        let savedCompletedAlbum = model.completedAddToAlbum
        for page in [SidebarSection.queue, .completed, .downloads] {
            model.selection = page
            try await Task.sleep(for: .milliseconds(100))
            model.importToPhotos.toggle()
            model.completedAddToAlbum.toggle()
            try await Task.sleep(for: .milliseconds(100))
            layoutWindow()
            try expect(first.window!.frame == stableFrame && abs(sidebarWidth() - chosenSidebarWidth) < 0.5,
                "page toolbars and import preference switches must not rewrite window or sidebar sizes")
        }
        model.importToPhotos = savedImport
        model.addToAlbum = savedAlbum
        model.completedAddToAlbum = savedCompletedAlbum
        model.selectedDownloadItemIDs = [pairID]
        try await waitUntil("layout regressions must restore the selected media form") {
            !inspector.isLoading && inspector.sectionGrids[.image] != nil && inspector.sectionGrids[.video] != nil
        }
        pass("page and preference changes retain the native window frame and sidebar width")
        try expectCleanInspectorForm(inspector, context: "initial pair after pane/selection changes")
        for kind in MediaInspection.Section.allCases where inspector.sectionGrids[kind] != nil {
            let grid = inspector.sectionGrids[kind]!
            try expect(grid.numberOfColumns == 2 && grid.numberOfRows == inspector.rows.filter { $0.section == kind }.count,
                "each native grid must contain only its own section's key/value fields")
            for row in 0..<grid.numberOfRows {
                let key = grid.cell(atColumnIndex: 0, rowIndex: row).contentView as! NSTextField
                let value = grid.cell(atColumnIndex: 1, rowIndex: row).contentView as! NSTextField
                try expect(key.font?.pointSize == 13 && value.font?.pointSize == 13
                    && key.textColor == .secondaryLabelColor && value.isSelectable,
                    "the native form must use uniform 13pt labels, secondary keys and selectable values")
            }
        }
        try expect(inspector.rows.filter { $0.section != .common }.allSatisfy {
            !$0.key.contains("照片 ·") && !$0.key.contains("视频 ·") && !$0.key.contains("文件 ·")
        }, "file sections must not repeat redundant image/video prefixes in each key")
        try expect(descendants(inspector.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "图片" }
            && descendants(inspector.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "视频" },
            "native form sections must use the requested 图片 and 视频 labels")

        let coldImage = root.appendingPathComponent("uncached-selection.png")
        try png.write(to: coldImage)
        MediaPostAttribution(platform: "xhs", postID: "new-selection", authorName: "新选中的作者").write(to: coldImage)
        model.downloadPhotos.append(coldImage)
        model.downloadFilter = .notComposed
        model.downloadFilter = .all
        let coldID = "photo:\(coldImage.standardizedFileURL.path)"
        let existingImageGrid = inspector.sectionGrids[.image]
        model.selectedDownloadItemIDs = [coldID]
        inspector.reload()
        try expect(inspector.isLoading && inspector.rows.contains { $0.key == "博主" && $0.value == "新选中的作者" },
            "an uncached selection must immediately show its own basic attribution without a blank loading screen")
        try expect(inspector.sectionGrids[.image] === existingImageGrid
            && !inspector.rows.contains { $0.key == "下载时 SHA-256" },
            "uncached selections must reuse the image form without showing the previous resource's technical data")
        try expectCleanInspectorForm(inspector, context: "uncached photo preview")
        try await waitUntil("the cold selection must finish loading") { !inspector.isLoading }
        try expectCleanInspectorForm(inspector, context: "completed photo metadata")
        let cacheStarted = ProcessInfo.processInfo.systemUptime
        model.selectedDownloadItemIDs = [pairID]
        inspector.reload()
        let cachedSelectionMilliseconds = (ProcessInfo.processInfo.systemUptime - cacheStarted) * 1000
        try expect(!inspector.isLoading && inspector.statusText.isEmpty
            && inspector.rows.contains { $0.key == "博主" && $0.value == "来源博主" }
            && inspector.sectionGrids[.image] === existingImageGrid,
            "returning to a read selection must synchronously restore verified metadata and reuse existing fields")
        print(String(format: "Cached selection display: %.2fms, no asynchronous read", cachedSelectionMilliseconds))
        try expectCleanInspectorForm(inspector, context: "cached pair metadata")
        let coldRevision = MediaFileRevision(coldImage)
        MediaPostAttribution(platform: "xhs", postID: "new-selection", authorName: "更新后的作者").write(to: coldImage)
        try expect(MediaFileRevision(coldImage) == coldRevision,
            "the metadata invalidation fixture must leave the media-byte revision unchanged")
        model.selectedDownloadItemIDs = [coldID]
        inspector.reload()
        try expect(inspector.isLoading && inspector.rows.contains { $0.key == "博主" && $0.value == "更新后的作者" },
            "extended-attribute changes must invalidate cached attribution even if media bytes and mtime are unchanged")
        try await waitUntil("updated attribution must finish loading") { !inspector.isLoading }
        let tiny = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        tiny.setColor(fixtureColor, atX: 0, y: 0)
        try tiny.representation(using: .png, properties: [:])!.write(to: coldImage)
        inspector.reload()
        try expect(inspector.isLoading, "replacement bytes at an unchanged path must invalidate cached media properties")
        try await waitUntil("replacement media properties must load") { !inspector.isLoading }
        try expect(inspector.rows.contains { $0.key == "显示尺寸" && $0.value == "1 × 1 像素" },
            "cache invalidation must display the replacement image dimensions")
        try png.write(to: coldImage)
        inspector.reload()
        model.selectedDownloadItemIDs = [pairID]
        inspector.reload()
        try await Task.sleep(for: .milliseconds(80))
        try expect(!inspector.isLoading && inspector.rows.contains { $0.key == "博主" && $0.value == "来源博主" },
            "a cancelled slow selection must never replace a newer cached selection")
        for iteration in 0..<12 {
            model.selectedDownloadItemIDs = [coldID]
            inspector.reload()
            try await waitUntil("the repeated photo selection must finish loading") { !inspector.isLoading }
            try expectCleanInspectorForm(inspector, context: "repeated photo selection \(iteration)")
            model.selectedDownloadItemIDs = [pairID]
            inspector.reload()
            try expect(!inspector.isLoading && inspector.sectionGrids[.image] === existingImageGrid,
                "repeated selections must preserve the cached form and immediate display")
            try expectCleanInspectorForm(inspector, context: "repeated cached pair selection \(iteration)")
        }
        pass("repeated photo/Live Photo selections remove obsolete views and keep every information row separate")
        pass("selection previews do not blank the form, cached selections display immediately and file/receipt changes invalidate them")
        model.selectedDownloadItemIDs = [pairID, photoID]
        try await waitUntil("multiple selections must clear per-file fields and show a native prompt") {
            inspector.rows.isEmpty && inspector.sectionGrids.isEmpty
                && descendants(inspector.view).compactMap { $0 as? NSTextField }
                    .contains { !$0.isHidden && $0.stringValue.contains("多个") }
        }
        try expect(!inspector.scrollView.isHidden && inspector.scrollView.borderType == .noBorder
            && !(inspector.view is NSVisualEffectView),
            "multiple selection must retain the same borderless native sidebar treatment")
        model.selectedDownloadItemIDs = []
        try await waitUntil("empty selection must clear per-file fields") { inspector.rows.isEmpty }
        try expect(defaults.data(forKey: "CompletedRecords.v1") == completedSentinel
            && defaults.data(forKey: "DownloadCompletedRecords.v1") == completedSentinel,
            "changing inspector selection must not rewrite completion records")
        pass("one native scroll groups image/video forms, preserves sidebar material and leaves records intact")

        MediaPostAttribution(platform: "xhs", postID: "located-fixture",
            postURL: URL(string: "https://www.xiaohongshu.com/explore/located-fixture"),
            title: "带位置的照片").write(to: locatedImage)
        let mapModel = ImporterModel(refreshOnInit: false)
        mapModel.downloadPhotos = [locatedImage, relocatedImage, secondImage]
        mapModel.downloadFilter = .notComposed
        mapModel.downloadFilter = .all
        mapModel.selection = .downloads
        let locatedID = "photo:\(locatedImage.standardizedFileURL.path)"
        let relocatedID = "photo:\(relocatedImage.standardizedFileURL.path)"
        mapModel.selectedDownloadItemIDs = [locatedID]
        let mapInspector = MediaInspectorController(model: mapModel)
        let mapWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 880),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        mapWindow.title = "HERMES · 位置检查器验证"
        mapWindow.contentViewController = mapInspector
        defer { mapWindow.orderOut(nil) }
        mapWindow.makeKeyAndOrderFront(nil)
        mapInspector.isInspectionEnabled = true
        try await waitUntil("the native map must load for a located photo; selection=\(mapModel.selectedDownloadItemIDs), items=\(mapModel.visibleDownloadItems.map(\.id)), status=\(mapInspector.statusText)") {
            !mapInspector.isLoading && mapInspector.location == photoLocation
        }
        func currentMap() -> MKMapView? { descendants(mapInspector.view).compactMap { $0 as? MKMapView }.first }
        try expect(mapInspector.rows.contains { $0.key == "光圈" && $0.value == "f/1.78" }
            && mapInspector.sectionGrids[.capture] != nil,
            "the native inspector must show actual shooting metadata above the location map")
        for width: CGFloat in [270, 560, 340] {
            mapWindow.setContentSize(NSSize(width: width, height: 880))
            mapInspector.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            mapInspector.view.layoutSubtreeIfNeeded()
            let map = currentMap()!
            try expect(map.annotations.count == 1 && map.annotations[0].coordinate.latitude == photoLocation.latitude
                && map.annotations[0].coordinate.longitude == photoLocation.longitude
                && !map.showsUserLocation && map.layer?.cornerRadius == 10 && map.layer?.masksToBounds == true,
                "the native rounded map must mark only the selected file's location without current-location tracking")
            try expect(abs(map.frame.width - (mapInspector.scrollView.contentSize.width - 32)) < 0.5
                && abs(map.frame.height - 180) < 0.5,
                "the location map must fit the inspector at narrow and wide pane sizes")
            let document = mapInspector.scrollView.documentView!
            let headings = descendants(mapInspector.view).compactMap { $0 as? NSTextField }
            let imageHeading = headings.first { $0.stringValue == "图片" }!
            let captureHeading = headings.first { $0.stringValue == "拍摄信息" }!
            let locationHeading = headings.first { $0.stringValue == "位置" }!
            let postHeading = headings.first { $0.stringValue == "帖子信息" }!
            let mapRect = map.convert(map.bounds, to: document)
            try expect(imageHeading.convert(imageHeading.bounds, to: document).minY > mapRect.maxY
                && captureHeading.convert(captureHeading.bounds, to: document).minY > mapRect.maxY
                && locationHeading.convert(locationHeading.bounds, to: document).minY > mapRect.maxY
                && postHeading.convert(postHeading.bounds, to: document).maxY < mapRect.minY,
                "the map must follow useful media properties and precede post and technical details")
            let marker = mapInspector.mapView(map, viewFor: map.annotations[0]) as? MKMarkerAnnotationView
            try expect(marker?.displayPriority == .required && marker?.canShowCallout == false,
                "the file location must use the system marker with no raw-coordinate callout")
            try expectCleanInspectorForm(mapInspector, context: "located photo at width \(width)")
        }
        let retainedMap = currentMap()!
        mapInspector.isInspectionEnabled = false
        mapInspector.isInspectionEnabled = true
        try expect(currentMap() === retainedMap, "reopening an unchanged inspector must retain its native map")
        mapModel.selectedDownloadItemIDs = [photoID]
        mapInspector.reload()
        try expect(currentMap() == nil && mapInspector.location == nil,
            "an uncached selection must immediately discard the previous file's pin")
        try expect(!descendants(mapInspector.view).compactMap { $0 as? NSTextField }
            .contains { ["位置", "拍摄信息", "帖子信息"].contains($0.stringValue) },
            "uncached metadata must not leave empty headings or the preceding file's details")
        try await waitUntil("a photo without GPS must finish inspecting") { !mapInspector.isLoading }
        try expect(currentMap() == nil && !descendants(mapInspector.view).compactMap { $0 as? NSTextField }
            .contains { ["位置", "未记录位置信息", "正在读取位置信息…"].contains($0.stringValue) },
            "a no-GPS photo must omit the entire location section")
        try expect(mapInspector.sectionGrids[.capture] == nil && !mapInspector.rows.contains { $0.section == .capture }
            && !descendants(mapInspector.view).compactMap { $0 as? NSTextField }
                .contains { ["拍摄信息", "未记录拍摄信息", "正在读取拍摄信息…", "帖子信息"].contains($0.stringValue) },
            "missing capture and post sections must use the same rule as missing location")
        mapModel.selectedDownloadItemIDs = [locatedID]
        mapInspector.reload()
        mapModel.selectedDownloadItemIDs = [photoID]
        mapInspector.reload()
        try expect(!mapInspector.isLoading && currentMap() == nil
            && !descendants(mapInspector.view).compactMap { $0 as? NSTextField }
                .contains { ["位置", "拍摄信息", "帖子信息"].contains($0.stringValue) },
            "cached no-metadata selections must apply the same section visibility rules")
        mapModel.selectedDownloadItemIDs = [locatedID]
        mapInspector.reload()
        try expect(!mapInspector.isLoading && mapInspector.location == photoLocation && currentMap() != nil,
            "the cached selection must restore its map immediately")
        // Replace only this regression fixture; unchanged paths must invalidate GPS too.
        try writeGPSImage(locatedImage, latitude: 37.7749, longitude: 122.4194, latitudeRef: "N", longitudeRef: "W")
        mapInspector.reload()
        try await waitUntil("changed GPS at the same path must invalidate its cached location") {
            !mapInspector.isLoading && mapInspector.location == otherPhotoLocation
        }
        mapModel.selectedDownloadItemIDs = [relocatedID]
        mapInspector.reload()
        mapModel.selectedDownloadItemIDs = [locatedID, relocatedID]
        mapInspector.reload()
        try await Task.sleep(for: .milliseconds(50))
        try expect(mapInspector.rows.isEmpty && mapInspector.location == nil && currentMap() == nil,
            "multi-selection and cancelled loads must clear the previous file's location")
        try writeGPSImage(locatedImage, latitude: 33.865, longitude: 151.2094, latitudeRef: "S", longitudeRef: "E")
        pass("native MapKit pin, rounded responsive layout, section order, cache invalidation and selection clearing")
        if CommandLine.arguments.contains("--inspector-location-preview") {
            mapModel.selectedDownloadItemIDs = [locatedID]
            mapInspector.reload()
            try await waitUntil("the location preview must show its actual GPS") {
                !mapInspector.isLoading && mapInspector.location == photoLocation
            }
            mapWindow.center()
            mapWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            print("Native location preview ready")
            fflush(stdout)
            try await Task.sleep(for: .seconds(50))
            return
        }

        let longFilename = String(repeating: "unbroken-long-filename-", count: 8) + ".jpg"
        let longImage = root.appendingPathComponent(longFilename)
        let longCamera = String(repeating: "Very Long Camera Model ", count: 12)
        let longLens = String(repeating: "Very Long Lens Model 24-70mm f/2.8 ", count: 12)
        try writeJPEGImage(longImage, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: longCamera],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: longLens]])
        MediaPostAttribution(platform: "xhs", postID: String(repeating: "unbroken-post-identifier-", count: 8),
            title: String(repeating: "很长的来源帖子标题与说明", count: 50)).write(to: longImage)
        let longReceipt = MediaSourceProvenance(state: .cloudOriginal, noteID: "long-layout-fixture",
            imageFileID: String(repeating: "note_pre_post_uhdr/1040g3r0325qf5d1ol6105qisb0dk040124l1avo", count: 3),
            objectKey: String(repeating: "note_pre_post_uhdr/1040g3r0325qf5d1ol6105qisb0dk040124l1avo", count: 3),
            sourceHost: "sns-img-bd.xhscdn.com", sourceField: "images_list.fileid",
            sha256: MediaSourceProvenance.hash(of: longImage))
        longReceipt.write(to: longImage)
        let wrapModel = ImporterModel(refreshOnInit: false)
        wrapModel.downloadPhotos = [longImage]
        wrapModel.downloadFilter = .notComposed
        wrapModel.selection = .downloads
        wrapModel.selectedDownloadItemIDs = ["photo:\(longImage.standardizedFileURL.path)"]
        let wrapInspector = MediaInspectorController(model: wrapModel)
        let wrapWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        wrapWindow.contentViewController = wrapInspector
        defer { wrapWindow.orderOut(nil) }
        wrapWindow.makeKeyAndOrderFront(nil)
        wrapInspector.isInspectionEnabled = true
        try await waitUntil("long post metadata must load into the native form") {
            !wrapInspector.isLoading && wrapInspector.sectionGrids[.image] != nil
        }
        try expect([MediaInspection.Section.sourceDetails, .imageDetails, .videoDetails].allSatisfy { section in
            wrapInspector.sectionGrids[section] == nil && !wrapInspector.rows.contains { $0.section == section }
        },
            "the native form must not expose technical receipt sections")
        let formText = descendants(wrapInspector.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        try expect(!formText.contains { $0.contains("unbroken-post-identifier-")
            || $0.contains("note_pre_post_uhdr/") || $0 == longReceipt.sha256 },
            "hidden technical values must not survive in native field views")
        func wrappedFieldHeights(at width: CGFloat) async throws -> [CGFloat] {
            wrapWindow.setContentSize(NSSize(width: width, height: 700))
            wrapInspector.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            wrapInspector.view.layoutSubtreeIfNeeded()
            let firstSectionLabel = descendants(wrapInspector.view).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == "信息" }!
            let titleRect = firstSectionLabel.convert(firstSectionLabel.bounds, to: wrapInspector.scrollView.contentView)
            try expect(titleRect.maxY <= wrapInspector.scrollView.contentView.bounds.maxY + 0.5
                && wrapInspector.scrollView.contentView.bounds.maxY - titleRect.maxY < 18,
                "the first form section must stay at the top after resize: width=\(width), title=\(titleRect), clip=\(wrapInspector.scrollView.contentView.bounds), document=\(wrapInspector.scrollView.documentView!.frame)")
            var heights: [CGFloat] = []
            try expectCleanInspectorForm(wrapInspector, context: "long shooting and post metadata at width \(width)")
            for key in ["帖子标题/描述", "相机型号", "镜头"] {
                let section = wrapInspector.rows.first { $0.key == key }!.section
                let fileRows = wrapInspector.rows.filter { $0.section == section }
                let grid = wrapInspector.sectionGrids[section]!
                let row = fileRows.firstIndex { $0.key == key }!
                let field = grid.cell(atColumnIndex: 1, rowIndex: row).contentView as! NSTextField
                let requiredHeight = field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0,
                    width: field.bounds.width, height: 100_000)).height
                try expect(field.isSelectable && field.maximumNumberOfLines == 0 && field.font?.pointSize == 13,
                    "wrapped form values must remain native selectable unlimited-line 13pt fields")
                try expect(abs(field.preferredMaxLayoutWidth - (wrapInspector.scrollView.contentSize.width - 144)) < 0.5,
                    "wrapping must track the current clip width after native scrollers appear or disappear")
                try expect(field.bounds.height + 0.5 >= requiredHeight && requiredHeight > 16,
                    "native \(key) value must fit every line at width \(width): actual \(field.bounds.height), required \(requiredHeight)")
                let alignedRect = field.alignmentRect(forFrame: field.frame)
                try expect(alignedRect.minX >= 0 && alignedRect.maxX <= grid.bounds.width + 0.5
                    && alignedRect.minY >= 0 && alignedRect.maxY <= grid.bounds.height + 0.5,
                    "every wrapped value's native alignment rectangle must remain inside the grid bounds")
                heights.append(field.bounds.height)
            }
            try expect(descendants(wrapInspector.view).compactMap { $0 as? NSScrollView }.count == 1,
                "long content must scroll as one continuous form rather than nested sections")
            return heights
        }
        for style in [NSScroller.Style.overlay, .legacy] {
            wrapInspector.scrollView.scrollerStyle = style
            let narrowHeights = try await wrappedFieldHeights(at: 270)
            let wideHeights = try await wrappedFieldHeights(at: 560)
            let restoredNarrowHeights = try await wrappedFieldHeights(at: 270)
            try expect(zip(narrowHeights, wideHeights).allSatisfy { $0 > $1 }
                && zip(narrowHeights, restoredNarrowHeights).allSatisfy { abs($0 - $1) < 0.5 },
                "native grid row sizing must shrink and grow automatically with either scroller style")
        }
        try expect(wrapInspector.sectionGrids[.video] == nil,
            "a single photograph must not invent a video form section")
        let topOrigin = wrapInspector.scrollView.contentView.bounds.origin.y
        try expect(topOrigin > 0, "the stress fixture must extend beyond one visible inspector page")
        wrapInspector.scrollView.contentView.scroll(to: .zero)
        wrapInspector.scrollView.reflectScrolledClipView(wrapInspector.scrollView.contentView)
        try expect(wrapInspector.scrollView.contentView.bounds.origin.y < topOrigin,
            "one native scroll view must move through the entire continuous form")
        pass("native 13pt form values wrap without clipping and resize at the minimum and maximum inspector widths")

        if CommandLine.arguments.contains("--inspector-layout") {
            print("Focused native inspector layout checks passed")
            return
        }

        for page in SidebarSection.allCases {
            model.selection = page
            try await waitUntil("the inspector toggle must remain the rightmost toolbar item on \(page.title)") {
                first.window?.toolbar?.items.last?.itemIdentifier == .toggleInspector
                    && first.window?.toolbar?.identifier.hasSuffix(page == .queue ? "Queue" : page == .downloads ? "Downloads" : "Completed") == true
            }
        }
        pass("the system inspector toggle stays at the far right of every page toolbar")

        let gridPair = ThumbnailGridItem(id: pairID, url: image, status: .waiting,
            mediaKind: .livePhoto, contentVersion: 0, resourceURLs: [image, movie])
        let gridPhoto = ThumbnailGridItem(id: photoID, url: secondImage, status: .waiting,
            mediaKind: .photo, contentVersion: 0, resourceURLs: [secondImage])
        try expect(NativeMediaResources.readableURLs(for: gridPair) == [image, movie],
            "Live Photo transfer must include its still and motion resources")
        try expect(NativeMediaResources.readableURLs(for: [gridPair, gridPhoto, gridPair]) == [image, movie, secondImage],
            "multi-item transfer must deduplicate exact URLs while preserving resource order")
        var unavailablePair = gridPair
        unavailablePair.unavailableMessage = "暂时不可用"
        try expect(NativeMediaResources.readableURLs(for: unavailablePair).isEmpty,
            "an explicitly unavailable pair must not be exported")
        let missingPair = ThumbnailGridItem(id: "missing-pair", url: image, status: .waiting,
            mediaKind: .livePhoto, contentVersion: 0, resourceURLs: [image, root.appendingPathComponent("missing.mov")])
        try expect(NativeMediaResources.readableURLs(for: missingPair).isEmpty,
            "a missing motion component must never silently flatten a Live Photo to a still")
        try expect(NativeMediaResources.readableURLs(for: [gridPhoto, missingPair]).isEmpty,
            "a partially unavailable selection must not silently share or drag only its readable subset")
        let grid = ThumbnailGridController()
        grid.updateItems([gridPair, gridPhoto], animatingDifferences: false)
        try expect(grid.resourceURLs(forIDs: [pairID, photoID]) == [image, movie, secondImage],
            "the actual grid must use complete resources for multi-selection")
        let pairDrag = NSDraggingItem(pasteboardWriter: image as NSURL)
        pairDrag.setDraggingFrame(NSRect(x: 0, y: 0, width: 20, height: 20), contents: nil)
        let photoDrag = NSDraggingItem(pasteboardWriter: secondImage as NSURL)
        photoDrag.setDraggingFrame(NSRect(x: 30, y: 0, width: 20, height: 20), contents: nil)
        let dragURLs = grid.expandedDraggingItems([pairDrag, photoDrag]).compactMap { ($0.item as? NSURL).map { $0 as URL } }
        try expect(dragURLs == [image, movie, secondImage],
            "native dragging must expand a logical pair into two actual file-URL pasteboard items")
        grid.updateItems([gridPhoto, missingPair], animatingDifferences: false)
        try expect(grid.expandedDraggingItems([photoDrag, pairDrag]).isEmpty,
            "native drag expansion must refuse the whole session when one selected component is missing")
        pass("drag/share resources preserve both Live Photo components and refuse incomplete payloads")

        let replacementMotion = root.appendingPathComponent("replacement-motion.mov")
        try (originalMovieBytes + Data(" replacement".utf8)).write(to: replacementMotion)
        let retainedGrid = ThumbnailGridController()
        let retainedScroll = NSScrollView()
        ThumbnailCollectionStyle.prepare(retainedScroll, documentView: retainedGrid.nsCollectionView)
        let retainedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer { retainedWindow.orderOut(nil) }
        retainedWindow.contentView = retainedScroll
        retainedWindow.makeKeyAndOrderFront(nil)
        let oldAnimatedPair = ThumbnailGridItem(id: "retained-animation-old", url: image, status: .running,
            mediaKind: .livePhoto, contentVersion: 0, resourceURLs: [image, movie])
        let currentAnimatedPair = ThumbnailGridItem(id: "retained-animation-current", url: image, status: .waiting,
            mediaKind: .livePhoto, contentVersion: 0, resourceURLs: [image, replacementMotion])
        retainedGrid.updateItems([oldAnimatedPair], animatingDifferences: false)
        retainedScroll.layoutSubtreeIfNeeded()
        retainedGrid.nsCollectionView.layoutSubtreeIfNeeded()
        try await waitUntil("the old visible pair must actually be presenting its composition animation") {
            (retainedGrid.nsCollectionView.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailCollectionItem)?
                .isPresentingComposition == true
        }
        retainedGrid.updateItems([currentAnimatedPair], animatingDifferences: false)
        try await waitUntil("the old animation must remain presented beside the current requested pair") {
            retainedGrid.nsCollectionView.numberOfItems(inSection: 0) == 2
        }
        let currentDrag = NSDraggingItem(pasteboardWriter: image as NSURL)
        currentDrag.setDraggingFrame(NSRect(x: 0, y: 0, width: 20, height: 20), contents: nil)
        let currentDragURLs = retainedGrid.expandedDraggingItems([currentDrag])
            .compactMap { ($0.item as? NSURL).map { $0 as URL } }
        try expect(currentDragURLs == [image, replacementMotion],
            "a retained old animation sharing the still path must not hide or replace the current pair's drag resources")
        pass("dragging a current pair ignores a retained composition animation with the same still path")

        let scannedPair = CompletedItem(imagePath: image.path, moviePath: movie.path,
            revision: MediaPairRevision(image: image, movie: movie))
        model.completed = [scannedPair]
        model.selection = .completed
        model.selectedCompletedIDs = [scannedPair.id]
        try await waitUntil("a scanned native pair must omit an unrecorded composition state and retain its original-source receipt") {
            !inspector.isLoading && !inspector.rows.contains { $0.key == "合成状态" }
                && inspector.rows.contains { $0.key == "原始文件" && $0.value == "原始文件（下载时已验证）" }
        }
        try expect(!inspector.rows.contains { $0.key == "原始文件" && $0.value.contains("合成产物") },
            "being found on the completed page must not itself establish that HERMES composed the pair")
        pass("a scanned native pair retains its original receipt and is not mislabelled as a HERMES composition")

        let replacedOutputImage = root.appendingPathComponent("replaced-output.png")
        let replacedOutputMovie = root.appendingPathComponent("replaced-output.mov")
        try png.write(to: replacedOutputImage)
        try originalMovieBytes.write(to: replacedOutputMovie)
        let outputRecord = CompletedItem(imagePath: replacedOutputImage.path, moviePath: replacedOutputMovie.path,
            revision: MediaPairRevision(image: replacedOutputImage, movie: replacedOutputMovie),
            sourceImagePath: image.path, sourceVideoPath: movie.path,
            sourceRevision: MediaPairRevision(image: image, movie: movie))
        model.completed = [outputRecord]
        model.selectedCompletedIDs = [outputRecord.id]
        inspector.reload(force: true)
        try await waitUntil("a current recorded composition must initially display its verified record") {
            inspector.rows.contains { $0.key == "合成状态" && $0.value == "已合成" }
        }
        try FileManager.default.removeItem(at: replacedOutputImage)
        try (png + Data([0])).write(to: replacedOutputImage)
        inspector.reload(force: true)
        try await waitUntil("replacement at the same output path must invalidate recorded composition and original-source claims") {
            inspector.rows.contains { $0.key == "合成状态" && $0.value == "文件已变化，合成状态待确认" }
                && !inspector.isLoading && !inspector.rows.contains { $0.key == "原始文件" }
        }
        try expect(!inspector.rows.contains { $0.key == "原始文件" && $0.value.contains("合成产物") },
            "a stale completed record cannot establish that replacement output bytes are a composition")
        pass("replacement output bytes at an unchanged path lose the stale composition and original-source labels")

        let sourceWithReusedPath = root.appendingPathComponent("reused-source.png")
        let sourceMovieWithReusedPath = root.appendingPathComponent("reused-source.mov")
        let retainedOutputImage = root.appendingPathComponent("retained-output.png")
        let retainedOutputMovie = root.appendingPathComponent("retained-output.mov")
        for url in [sourceWithReusedPath, retainedOutputImage] { try png.write(to: url) }
        for url in [sourceMovieWithReusedPath, retainedOutputMovie] { try originalMovieBytes.write(to: url) }
        let originalPost = MediaPostAttribution(platform: "小红书", postID: "original-post",
            title: "原始帖子", authorName: "原帖博主", authorID: "original-author")
        for url in [sourceWithReusedPath, sourceMovieWithReusedPath, retainedOutputImage, retainedOutputMovie] {
            originalPost.write(to: url)
        }
        for url in [sourceWithReusedPath, sourceMovieWithReusedPath] { receipt.write(to: url) }
        let retainedRecord = CompletedItem(imagePath: retainedOutputImage.path, moviePath: retainedOutputMovie.path,
            revision: MediaPairRevision(image: retainedOutputImage, movie: retainedOutputMovie),
            sourceImagePath: sourceWithReusedPath.path, sourceVideoPath: sourceMovieWithReusedPath.path,
            sourceRevision: MediaPairRevision(image: sourceWithReusedPath, movie: sourceMovieWithReusedPath))
        model.completed = [retainedRecord]
        model.selectedCompletedIDs = [retainedRecord.id]
        inspector.reload(force: true)
        try await waitUntil("the current output must initially retain its original author's captured attribution") {
            inspector.rows.contains { $0.key == "博主" && $0.value == "原帖博主" }
        }
        try FileManager.default.removeItem(at: sourceWithReusedPath)
        try (png + Data([1])).write(to: sourceWithReusedPath)
        let replacementPost = MediaPostAttribution(platform: "小红书", postID: "replacement-post",
            title: "替换后的帖子", authorName: "新帖博主", authorID: "replacement-author")
        for url in [sourceWithReusedPath, sourceMovieWithReusedPath] { replacementPost.write(to: url) }
        inspector.reload(force: true)
        try await waitUntil("changed source paths must not overwrite the unchanged output's captured author") {
            inspector.rows.contains { $0.key == "合成状态" && $0.value == "已合成" }
                && inspector.rows.contains { $0.key == "博主" && $0.value == "原帖博主" }
                && !inspector.isLoading && !inspector.rows.contains { $0.key == "源文件原始状态" }
        }
        try expect(!inspector.rows.contains { $0.value.contains("新帖博主") || $0.value.contains("replacement-post") },
            "reused source paths from another post must not become evidence for an unchanged output")
        pass("source path reuse keeps captured output attribution and discards foreign source evidence")

        try expect(defaults.data(forKey: "CompletedRecords.v1") == completedSentinel
            && defaults.data(forKey: "DownloadCompletedRecords.v1") == completedSentinel,
            "native inspection and transfer must not alter completion records")
        print("\(checks) native media regression checks passed")
    }
}
