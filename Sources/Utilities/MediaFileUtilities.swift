import AppKit
import Foundation

enum MediaFileUtilities {
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
