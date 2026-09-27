import AppKit
import QuickLookThumbnailing
import ImageIO

struct MediaThumbnailResult {
    var image: NSImage?
    var unavailableMessage: String?
}

final class SystemThumbnailProvider: @unchecked Sendable {
    static let shared = SystemThumbnailProvider()

    private init() {}

    func thumbnail(for url: URL, pointSize: CGFloat, scale: CGFloat) async -> MediaThumbnailResult {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return MediaThumbnailResult(unavailableMessage: "原文件不可用")
        }
        // Quick Look takes a size in points and applies the display scale itself.
        let requestedSize = CGSize(width: pointSize, height: pointSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: url.standardizedFileURL,
            size: requestedSize,
            scale: scale,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )

        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                if let representation, representation.type != .icon {
                    continuation.resume(returning: representation.nsImage)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
        if let image { return MediaThumbnailResult(image: image) }
        // Quick Look can return no preview while its service is busy. Decode a
        // bounded image thumbnail directly instead of presenting a generic file icon.
        let fallback = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, Int(ceil(pointSize * scale))),
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        }.value
        return MediaThumbnailResult(image: fallback, unavailableMessage: fallback == nil ? "预览暂不可用" : nil)
    }

}
