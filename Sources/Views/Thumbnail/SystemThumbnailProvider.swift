import AppKit
import QuickLookThumbnailing

final class SystemThumbnailProvider: @unchecked Sendable {
    static let shared = SystemThumbnailProvider()

    private let imageCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 1_200
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    private let failureCache: NSCache<NSURL, NSDate> = {
        let cache = NSCache<NSURL, NSDate>()
        cache.countLimit = 600
        return cache
    }()

    private let failureTTL: TimeInterval = 90

    private init() {}

    func cachedThumbnail(for url: URL) -> NSImage? {
        imageCache.object(forKey: url.standardizedFileURL as NSURL)
    }

    func invalidate(_ url: URL) {
        let key = url.standardizedFileURL as NSURL
        imageCache.removeObject(forKey: key)
        failureCache.removeObject(forKey: key)
    }

    func removeAll() {
        imageCache.removeAllObjects()
        failureCache.removeAllObjects()
    }

    func thumbnail(for url: URL, maxPixelSize: Int) async -> NSImage {
        if let cachedImage = cachedThumbnail(for: url) {
            return cachedImage
        }

        let key = url.standardizedFileURL as NSURL
        if let failureDate = failureCache.object(forKey: key),
           Date().timeIntervalSince(failureDate as Date) < failureTTL {
            return fallbackIcon(for: url, maxPixelSize: maxPixelSize)
        }

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
                self.failureCache.setObject(Date() as NSDate, forKey: key)
                if error != nil {
                    continuation.resume(returning: self.fallbackIcon(for: url, maxPixelSize: maxPixelSize))
                } else {
                    continuation.resume(returning: self.fallbackIcon(for: url, maxPixelSize: maxPixelSize))
                }
            }
        }

        store(image, for: url)
        return image
    }

    private func store(_ image: NSImage, for url: URL) {
        let pixelSize = image.pixelSize
        let cost = max(1, Int(pixelSize.width * pixelSize.height * 4))
        imageCache.setObject(image, forKey: url.standardizedFileURL as NSURL, cost: cost)
    }

    private func fallbackIcon(for url: URL, maxPixelSize: Int) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: maxPixelSize, height: maxPixelSize)
        return icon
    }
}
