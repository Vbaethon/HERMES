import AppKit
import AVFoundation
import ImageIO
import Foundation

enum MediaFileUtilities {
    /// Validate the staged file before publishing it. Never infer validity from its suffix.
    static func validateMedia(_ url: URL, expectedSuffix: String) async throws {
        func invalid() -> NSError {
            NSError(domain: "MediaValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "下载内容不是可读取的媒体文件。"])
        }
        let fileSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize > 0 else { throw invalid() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 512) ?? Data()
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.hasPrefix("<"), !text.hasPrefix("{"), !text.hasPrefix("[") else { throw invalid() }
        let expectsVideo = ["mp4", "mov", "m4v"].contains(expectedSuffix.lowercased())
        if !expectsVideo, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 0,
           CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil { return }
        if ["jpg", "jpeg", "png", "heic", "heif", "webp", "avif"].contains(expectedSuffix.lowercased()) { throw invalid() }
        // Walk ISO container boundaries without reading payloads or restricting brands.
        // A readable moov alone does not prove the mdat payload finished downloading.
        if head.count >= 8, ["ftyp", "moov", "wide", "free", "mdat"].contains(String(decoding: head[4..<8], as: UTF8.self)) {
            var offset: UInt64 = 0
            while offset < fileSize {
                guard fileSize - offset >= 8 else { throw invalid() }
                try handle.seek(toOffset: offset)
                let header = try handle.read(upToCount: 16) ?? Data()
                guard header.count >= 8 else { throw invalid() }
                var size = header.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                let headerSize: UInt64 = size == 1 ? 16 : 8
                if size == 1 {
                    guard header.count >= 16 else { throw invalid() }
                    size = header[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                } else if size == 0 { size = fileSize - offset }
                guard size >= headerSize, size <= fileSize - offset else { throw invalid() }
                offset += size
            }
        }
        // Supply the container hint explicitly: .part is intentionally not a media extension.
        let suffix = sniffSuffix(url, defaultSuffix: expectedSuffix)
        let mime = suffix == "mov" ? "video/quicktime" : "video/mp4"
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mime])
        guard try await asset.load(.isReadable),
              let track = try await asset.loadTracks(withMediaType: .video).first else { throw invalid() }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        guard duration.isFinite, duration > 0, size.width > 0, size.height > 0 else { throw invalid() }
    }

    static func trimURLPunctuation(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "，,。！!）)]】"))
    }

    static func formatURL(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u003D", with: "=")
            .replacingOccurrences(of: "\\u003f", with: "?")
            .replacingOccurrences(of: "\\u003F", with: "?")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard normalized.contains("\\u") || normalized.contains("\\/") else {
            return normalized
        }
        let jsonText = "\"\(normalized)\""
        if let data = jsonText.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return decoded
        }
        return normalized
    }

    static func sniffSuffix(_ url: URL, defaultSuffix: String) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return defaultSuffix
        }
        let data = handle.readData(ofLength: 16)
        try? handle.close()
        let signatures: [(Int, [UInt8], String)] = [
            (0, [0xff, 0xd8, 0xff], "jpg"),
            (0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], "png"),
            (4, Array("ftypavif".utf8), "avif"),
            (4, Array("ftypheic".utf8), "heic"),
            (8, Array("WEBP".utf8), "webp"),
            (4, Array("ftypMSNV".utf8), "mp4"),
            (4, Array("ftypisom".utf8), "mp4"),
            (4, Array("ftypmp42".utf8), "mp4"),
            (4, Array("ftypqt  ".utf8), "mov")
        ]
        for (offset, signature, suffix) in signatures where data.count >= offset + signature.count {
            if Array(data[offset..<(offset + signature.count)]) == signature {
                return suffix
            }
        }
        return defaultSuffix
    }

    static func htmlDecode(_ value: String) -> String {
        guard let data = value.data(using: .utf8),
              let decoded = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ).string else {
            return value
        }
        return decoded
    }
}
