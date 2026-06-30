import AppKit
import QuickLookThumbnailing

final class SystemThumbnailProvider: @unchecked Sendable {
    static let shared = SystemThumbnailProvider()

    private init() {}

    func thumbnail(for url: URL, maxPixelSize: Int) async -> NSImage {
        let requestedSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: url.standardizedFileURL,
            size: requestedSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.thumbnail, .lowQualityThumbnail, .icon]
        )

        let image = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let representation {
                    continuation.resume(returning: representation.nsImage)
                    return
                }
                if error != nil {
                    continuation.resume(returning: self.fallbackIcon(for: url, maxPixelSize: maxPixelSize))
                } else {
                    continuation.resume(returning: self.fallbackIcon(for: url, maxPixelSize: maxPixelSize))
                }
            }
        }

        return image
    }

    private func fallbackIcon(for url: URL, maxPixelSize: Int) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: maxPixelSize, height: maxPixelSize)
        return icon
    }
}
