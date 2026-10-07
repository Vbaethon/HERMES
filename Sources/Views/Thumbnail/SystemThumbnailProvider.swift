import AppKit
import QuickLookThumbnailing
import ImageIO

struct MediaThumbnailResult: @unchecked Sendable {
    var image: NSImage?
    var unavailableMessage: String?
    var smallImage: NSImage? = nil
}

@MainActor
final class SystemThumbnailProvider {
    static let shared = SystemThumbnailProvider()

    typealias Loader = @Sendable (URL, CGFloat, CGFloat) async -> MediaThumbnailResult
    private struct Key: Hashable, Sendable {
        let url: URL
        let version: TimeInterval
        let pointSize: CGFloat
        let scale: CGFloat

        var cacheKey: NSString {
            "\(url.absoluteString)\n\(version.bitPattern):\(Double(pointSize).bitPattern):\(Double(scale).bitPattern)" as NSString
        }
    }

    private final class Load {
        let id = UUID()
        let key: Key
        var waiters: [UUID: CheckedContinuation<MediaThumbnailResult, Never>] = [:]
        var task: Task<Void, Never>?
        init(key: Key) { self.key = key }
    }

    private let cache = NSCache<NSString, NSImage>()
    private let detailCache = NSCache<NSString, NSImage>()
    nonisolated private static let sizes: [CGFloat] = [148, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096]
    private let maxConcurrentRequests: Int
    private let loader: Loader
    private var loads: [Key: Load] = [:]
    private var queued: [Load] = []
    private var running: [UUID: Load] = [:]

    init(maxConcurrentRequests: Int = 4, loader: Loader? = nil) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.loader = loader ?? Self.generate
        cache.countLimit = 600
        // Detail requested during a zoom must not evict all the small decoded
        // images needed when the same library returns to nine columns.
        cache.totalCostLimit = 32 * 1024 * 1024
        detailCache.countLimit = 120
        detailCache.totalCostLimit = min(256 * 1024 * 1024,
            max(64 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 128)))
    }

    static func requestSize(for pointSize: CGFloat) -> CGFloat {
        let side = max(ThumbnailCollectionStyle.cellSide, pointSize.isFinite ? ceil(pointSize) : 148)
        return sizes.first { $0 >= side } ?? ceil(side / 512) * 512
    }

    private func image(for key: Key) -> NSImage? {
        (key.pointSize == Self.sizes[0] ? cache : detailCache).object(forKey: key.cacheKey)
    }

    private func cachedKeys(url: URL, version: TimeInterval, scale: CGFloat) -> [Key] {
        let canonicalURL = url.standardizedFileURL
        return Self.sizes.map { Key(url: canonicalURL, version: version, pointSize: $0, scale: scale) }
    }

    /// A reused cell can restore decoded artwork immediately, without a task or fade.
    func cachedThumbnail(for url: URL, pointSize: CGFloat, scale: CGFloat,
                         contentVersion: TimeInterval) -> NSImage? {
        let side = Self.requestSize(for: pointSize)
        return cachedKeys(url: url, version: contentVersion, scale: scale)
            .lazy.filter { $0.pointSize >= side }.compactMap { self.image(for: $0) }.first
    }

    /// A new cell can immediately show any decoded size of this exact revision
    /// while a sharper bitmap is prepared. Never substitute another file.
    func bestCachedThumbnail(for url: URL, scale: CGFloat, contentVersion: TimeInterval) -> NSImage? {
        cachedKeys(url: url, version: contentVersion, scale: scale).reversed()
            .lazy.compactMap { self.image(for: $0) }.first
    }

    func thumbnail(for url: URL, pointSize: CGFloat, scale: CGFloat,
                   contentVersion: TimeInterval? = nil, allowsCachedThumbnail: Bool = true) async -> MediaThumbnailResult {
        guard !Task.isCancelled else { return MediaThumbnailResult() }
        let version: TimeInterval
        if let contentVersion {
            version = contentVersion
        } else {
            // Callers without a scanned revision still invalidate replaced files;
            // keep filesystem metadata reads off the main thread.
            version = await Task.detached(priority: .utility) {
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
            }.value
        }
        let requestedKey = Key(url: url.standardizedFileURL, version: version,
                               pointSize: Self.requestSize(for: pointSize), scale: scale)
        // A refreshed missing-resource report must not be hidden by old pixels.
        // Revalidate the file in the worker; an incomplete pair may still have a
        // perfectly readable still image, which should remain previewable.
        if !allowsCachedThumbnail {
            for key in cachedKeys(url: url, version: version, scale: scale) {
                cache.removeObject(forKey: key.cacheKey)
                detailCache.removeObject(forKey: key.cacheKey)
            }
        } else if let image = cachedThumbnail(for: url, pointSize: pointSize, scale: scale, contentVersion: version) {
            return MediaThumbnailResult(image: image)
        }
        // A larger in-flight request already provides the pixels a smaller
        // settled size needs; both subscribers can wait for that same work.
        let key = allowsCachedThumbnail ? (loads.keys.filter {
            $0.url == requestedKey.url && $0.version == version && $0.scale == scale
                && $0.pointSize >= requestedKey.pointSize
        }.min { $0.pointSize < $1.pointSize } ?? requestedKey) : requestedKey
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: MediaThumbnailResult())
                    return
                }
                let load: Load
                if let existing = loads[key] {
                    load = existing
                } else {
                    load = Load(key: key)
                    loads[key] = load
                    queued.append(load)
                }
                load.waiters[waiter] = continuation
                startQueuedLoads()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(waiter: waiter, for: key) }
        }
    }

    private func startQueuedLoads() {
        while running.count < maxConcurrentRequests, !queued.isEmpty {
            let load = queued.removeFirst()
            guard !load.waiters.isEmpty else { continue }
            running[load.id] = load
            let id = load.id
            let key = load.key
            let loader = loader
            load.task = Task.detached(priority: .utility) { [weak self] in
                let result = await loader(key.url, key.pointSize, key.scale)
                await self?.finish(id: id, result: result)
            }
        }
    }

    private func finish(id: UUID, result: MediaThumbnailResult) {
        guard let load = running.removeValue(forKey: id) else { return }
        if loads[load.key]?.id == id { loads.removeValue(forKey: load.key) }
        if let image = result.image, !load.waiters.isEmpty {
            let cost = image.representations.reduce(0) { cost, representation in
                if let bitmap = representation as? NSBitmapImageRep {
                    return cost + max(0, bitmap.bytesPerRow) * max(0, bitmap.pixelsHigh)
                }
                return cost + max(0, representation.pixelsWide) * max(0, representation.pixelsHigh) * 4
            }
            (load.key.pointSize == Self.sizes[0] ? cache : detailCache)
                .setObject(image, forKey: load.key.cacheKey, cost: cost)
            if let small = result.smallImage {
                let key = Key(url: load.key.url, version: load.key.version, pointSize: Self.sizes[0], scale: load.key.scale)
                let smallCost = small.representations.reduce(0) { $0 + max(0, $1.pixelsWide) * max(0, $1.pixelsHigh) * 4 }
                cache.setObject(small, forKey: key.cacheKey, cost: smallCost)
            }
        }
        for waiter in load.waiters.values { waiter.resume(returning: result) }
        load.waiters.removeAll()
        startQueuedLoads()
    }

    private func cancel(waiter: UUID, for key: Key) {
        guard let load = loads[key], let continuation = load.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: MediaThumbnailResult())
        guard load.waiters.isEmpty else { return }
        loads.removeValue(forKey: key)
        queued.removeAll { $0.id == load.id }
        // An active slot is released only after the worker exits. A canceled
        // subscriber cannot cancel artwork still needed by another cell.
        load.task?.cancel()
    }

    nonisolated private static func generate(url: URL, pointSize: CGFloat, scale: CGFloat) async -> MediaThumbnailResult {
        guard !Task.isCancelled else { return MediaThumbnailResult() }
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

        let quickLook = QuickLookThumbnailLoad(request: request)
        let thumbnail = await withTaskCancellationHandler {
            await withCheckedContinuation { quickLook.start($0) }
        } onCancel: {
            quickLook.cancel()
        }
        guard !Task.isCancelled else { return MediaThumbnailResult() }
        if let thumbnail {
            let prepared = displayThumbnail(thumbnail)
            let small = pointSize > Self.sizes[0] ? smallThumbnail(prepared, scale: scale) : nil
            return MediaThumbnailResult(image: NSImage(cgImage: prepared,
                size: NSSize(width: CGFloat(prepared.width) / scale, height: CGFloat(prepared.height) / scale)), smallImage: small)
        }
        // Quick Look can return no preview while its service is busy. Decode a
        // bounded image thumbnail directly instead of presenting a generic file icon.
        let fallback: NSImage? = autoreleasepool {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, Int(ceil(pointSize * scale))),
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        }
        return MediaThumbnailResult(image: fallback, unavailableMessage: fallback == nil ? "预览暂不可用" : nil)
    }

    /// Quick Look HEIC previews can contain 16-bit integer Display P3 pixels.
    /// Prepare their display bitmap once in this worker instead of repeating
    /// Core Animation's image conversion on the main thread during scrolling.
    /// Keep the original color space; floating-point HDR previews stay intact.
    nonisolated static func displayThumbnail(_ image: CGImage) -> CGImage {
        guard image.bitsPerComponent == 16, !image.bitmapInfo.contains(.floatComponents),
              let colorSpace = image.colorSpace, colorSpace.model == .rgb else { return image }
        return autoreleasepool {
            guard !Task.isCancelled,
                  let context = CGContext(data: nil, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context.makeImage() ?? image
        }
    }

    /// Keep a bounded small-grid texture beside zoom detail. Returning to nine
    /// columns must not upload dozens of three-column textures while scrolling.
    nonisolated private static func smallThumbnail(_ image: CGImage, scale: CGFloat) -> NSImage? {
        guard !Task.isCancelled, !image.bitmapInfo.contains(.floatComponents),
              let colorSpace = image.colorSpace, colorSpace.model == .rgb else { return nil }
        let factor = min(1, Self.sizes[0] * scale / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
    }

}

/// Quick Look cancellation need not deliver its completion. Resolve the awaiting
/// task ourselves, once, so abandoned cells cannot occupy all worker slots.
private final class QuickLookThumbnailLoad: @unchecked Sendable {
    private let request: QLThumbnailGenerator.Request
    private let lock = NSRecursiveLock()
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var finished = false

    init(request: QLThumbnailGenerator.Request) { self.request = request }

    func start(_ continuation: CheckedContinuation<CGImage?, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { continuation.resume(returning: nil); return }
        self.continuation = continuation
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [self] representation, _ in
            finish(representation.flatMap { $0.type == .icon ? nil : $0.cgImage })
        }
    }

    private func finish(_ image: CGImage?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: image)
    }

    func cancel() {
        finish(nil)
        QLThumbnailGenerator.shared.cancel(request)
    }
}
