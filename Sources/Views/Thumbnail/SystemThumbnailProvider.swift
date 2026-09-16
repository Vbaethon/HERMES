import AppKit
import QuickLookThumbnailing

final class SystemThumbnailProvider: @unchecked Sendable {
    static let shared = SystemThumbnailProvider()

    private init() {}

    func thumbnail(for url: URL, pointSize: CGFloat, scale: CGFloat) async -> NSImage {
        // Quick Look takes a size in points and applies the display scale itself.
        let requestedSize = CGSize(width: pointSize, height: pointSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: url.standardizedFileURL,
            size: requestedSize,
            scale: scale,
            representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]
        )

        let image = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                if let representation {
                    continuation.resume(returning: representation.nsImage)
                    return
                }
                continuation.resume(returning: self.fallbackIcon(for: url, pointSize: pointSize))
            }
        }
        return image
    }

    private func fallbackIcon(for url: URL, pointSize: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: pointSize, height: pointSize)
        return icon
    }
}
