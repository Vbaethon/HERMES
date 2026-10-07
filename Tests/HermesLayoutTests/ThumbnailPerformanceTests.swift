import AppKit
import XCTest
@testable import HermesThumbnailUI

private actor ThumbnailLoadMetrics {
    private var active = 0
    private var peak = 0
    private var requests: [URL] = []

    func begin(_ url: URL) { active += 1; peak = max(peak, active); requests.append(url) }
    func end() { active -= 1 }
    func snapshot() -> (peak: Int, requests: [URL]) { (peak, requests) }
}

@MainActor
final class ThumbnailPerformanceTests: XCTestCase {
    func testHEICDisplayPreparationKeepsP3ColorsAndLeavesFloatingHDRIntact() throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let values: [UInt16] = [12000, 36000, 58000, 65535]
        let bytes = values.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let source = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: 8, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let prepared = SystemThumbnailProvider.displayThumbnail(source)
        XCTAssertEqual(prepared.bitsPerComponent, 8)
        XCTAssertEqual(prepared.colorSpace?.name, source.colorSpace?.name)
        func displayedPixels(_ image: CGImage) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Data(bytes: try XCTUnwrap(context.data), count: 4)
        }
        XCTAssertEqual(try displayedPixels(prepared), try displayedPixels(source),
                       "Preparing in the worker must match native rendering of the original P3 preview")
        let hdrValues: [Float16] = [0.2, 0.5, 1.3, 1]
        let hdrBytes = hdrValues.withUnsafeBytes { Data($0) }
        let hdrProvider = try XCTUnwrap(CGDataProvider(data: hdrBytes as CFData))
        let floating = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: 8, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: hdrProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        XCTAssertTrue(SystemThumbnailProvider.displayThumbnail(floating) === floating,
                      "Floating-point HDR pixels must not be clipped to an integer preview")
    }

    func testScrollingKeepsAppKitTextRasterWhileTextChangesInvalidateIt() async throws {
        _ = NSApplication.shared
        let label = ThumbnailBadgeLabel(labelWithString: "HEIC")
        label.frame = NSRect(origin: CGPoint(x: 20, y: 20),
                             size: ThumbnailBadgeStyle.size(for: label.stringValue))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        root.addSubview(label)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        window.displayIfNeeded()

        func textRaster(_ layer: CALayer?) -> AnyObject? {
            guard let layer, !layer.bounds.isEmpty else { return nil }
            if let children = layer.sublayers, !children.isEmpty {
                return children.compactMap { textRaster($0) }.last
            }
            return layer.contents as AnyObject?
        }
        let initial = try XCTUnwrap(textRaster(label.layer))
        for offset in 0..<100 {
            label.frame.origin.y = CGFloat(20 + offset % 40)
            label.needsDisplay = true
            window.displayIfNeeded()
            XCTAssertTrue(textRaster(label.layer) === initial,
                          "Panning must reuse AppKit's existing text raster instead of drawing the glyphs again")
        }
        label.stringValue = "0:42"
        label.frame.size = ThumbnailBadgeStyle.size(for: label.stringValue)
        label.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        window.displayIfNeeded()
        XCTAssertFalse(textRaster(label.layer) === initial)
        label.stringValue = ""
        label.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        window.displayIfNeeded()
        let empty = NSBitmapImageRep(cgImage: try XCTUnwrap(label.bitmap(scale: window.backingScaleFactor)))
        let textPixels = (0..<empty.pixelsHigh).reduce(0) { count, y in
            count + (0..<empty.pixelsWide).filter { x in
                (empty.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.01
            }.count
        }
        XCTAssertEqual(textPixels, 0, "Empty native text must not retain visible old duration pixels")
        XCTAssertTrue(label.wantsUpdateLayer, "Keep AppKit's efficient layer-backed text path")
        XCTAssertEqual(label.accessibilityValue() as? String, "")
    }

    func testNativePrefetchLoadsAnOffscreenPhotoBeforeItsCellExists() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("ahead.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let grid = ThumbnailGridController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 220))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        grid.updateItems((0..<70).map { ThumbnailGridItem(id: "prefetch-\($0)",
            url: $0 == 15 ? url : folder.appendingPathComponent("missing-\($0).png"),
            status: .finished, mediaKind: .photo, contentVersion: 7) }, animatingDifferences: false)
        try await Task.sleep(for: .milliseconds(30))
        let path = IndexPath(item: 15, section: 0)
        XCTAssertNil(grid.nsCollectionView.item(at: path))
        XCTAssertTrue(grid.nsCollectionView.prefetchDataSource === grid)
        grid.collectionView(grid.nsCollectionView, prefetchItemsAt: [path])
        let side = ZoomGeometry.side(width: grid.zoom.layout.viewportSize.width,
                                     columns: 5, metrics: grid.zoom.layout.metrics)
        let scale = window.backingScaleFactor
        for _ in 0..<100 {
            if SystemThumbnailProvider.shared.cachedThumbnail(for: url, pointSize: side,
                scale: scale, contentVersion: 7) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(SystemThumbnailProvider.shared.cachedThumbnail(for: url, pointSize: side,
            scale: scale, contentVersion: 7), "The future cell's exact image is ready before it enters the viewport")
        XCTAssertNil(grid.nsCollectionView.item(at: path), "Prefetching must not instantiate offscreen native cells")
        XCTAssertNil(SystemThumbnailProvider.shared.cachedThumbnail(for: url, pointSize: side,
            scale: scale, contentVersion: 8), "Prefetching never pairs an image with a different file revision")
    }

    private func provider(limit: Int = 4, delay: Duration = .milliseconds(80),
                          metrics: ThumbnailLoadMetrics) -> SystemThumbnailProvider {
        SystemThumbnailProvider(maxConcurrentRequests: limit) { url, _, _ in
            await metrics.begin(url)
            do { try await Task.sleep(for: delay) }
            catch { await metrics.end(); return MediaThumbnailResult() }
            await metrics.end()
            return MediaThumbnailResult(image: NSImage(size: NSSize(width: 32, height: 32)))
        }
    }

    private func waitForRequests(_ count: Int, metrics: ThumbnailLoadMetrics) async throws {
        for _ in 0..<200 {
            if await metrics.snapshot().requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Thumbnail backend did not start")
    }

    func testConcurrentCellsShareOneRequestAndReuseItsBitmap() async throws {
        let metrics = ThumbnailLoadMetrics()
        let provider = provider(metrics: metrics)
        let url = URL(fileURLWithPath: "/tmp/shared-thumbnail.png")
        async let first = provider.thumbnail(for: url, pointSize: 148, scale: 2, contentVersion: 1)
        async let second = provider.thumbnail(for: url, pointSize: 148, scale: 2, contentVersion: 1)
        let (a, b) = await (first, second)
        let bitmap = try XCTUnwrap(a.image)
        XCTAssertTrue(b.image === bitmap)
        let revisited = await provider.thumbnail(for: url, pointSize: 148, scale: 2, contentVersion: 1)
        XCTAssertTrue(revisited.image === bitmap)
        let stats = await metrics.snapshot()
        XCTAssertEqual(stats.requests.count, 1)
    }

    func testWindowAndSidebarSizingReuseDecodedDetailAcrossNearbyAndSmallerSizes() async throws {
        let metrics = ThumbnailLoadMetrics()
        let provider = provider(metrics: metrics)
        let url = URL(fileURLWithPath: "/tmp/resize-detail.png")
        let large = await provider.thumbnail(for: url, pointSize: 360, scale: 2, contentVersion: 1)
        let bitmap = try XCTUnwrap(large.image)
        for side in [355.0, 370, 300, 200, 148] {
            let smaller = await provider.thumbnail(for: url, pointSize: side, scale: 2, contentVersion: 1)
            XCTAssertTrue(smaller.image === bitmap)
            XCTAssertTrue(provider.cachedThumbnail(for: url, pointSize: side, scale: 2, contentVersion: 1) === bitmap)
        }
        let requests = await metrics.snapshot().requests
        XCTAssertEqual(requests.count, 1, "Geometry changes alone must not regenerate an already sufficient image")
        XCTAssertTrue(provider.bestCachedThumbnail(for: url, scale: 2, contentVersion: 1) === bitmap)
        XCTAssertNil(provider.bestCachedThumbnail(for: url, scale: 2, contentVersion: 2))
    }

    func testSmallerSizingSharesAnAlreadyRunningDetailRequest() async throws {
        let metrics = ThumbnailLoadMetrics()
        let provider = provider(delay: .milliseconds(150), metrics: metrics)
        let url = URL(fileURLWithPath: "/tmp/resize-in-flight.png")
        let large = Task { await provider.thumbnail(for: url, pointSize: 360, scale: 2, contentVersion: 1) }
        try await waitForRequests(1, metrics: metrics)
        let smaller = await provider.thumbnail(for: url, pointSize: 170, scale: 2, contentVersion: 1)
        let result = await large.value
        XCTAssertTrue(smaller.image === result.image)
        let requests = await metrics.snapshot().requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRevisionAndDisplayScaleCannotReuseStalePixels() async throws {
        let metrics = ThumbnailLoadMetrics()
        let provider = provider(metrics: metrics)
        let url = URL(fileURLWithPath: "/tmp/replaced-thumbnail.png")
        let old = await provider.thumbnail(for: url, pointSize: 148, scale: 1, contentVersion: 1)
        let replacement = await provider.thumbnail(for: url, pointSize: 148, scale: 1, contentVersion: 2)
        let retina = await provider.thumbnail(for: url, pointSize: 148, scale: 2, contentVersion: 2)
        XCTAssertNotNil(old.image)
        XCTAssertFalse(old.image === replacement.image)
        XCTAssertFalse(replacement.image === retina.image)
        let stats = await metrics.snapshot()
        XCTAssertEqual(stats.requests.count, 3)
    }

    func testFastScrollingBoundsNativeGenerationConcurrency() async throws {
        let metrics = ThumbnailLoadMetrics()
        let provider = provider(metrics: metrics)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = await provider.thumbnail(for: URL(fileURLWithPath: "/tmp/scroll-\(index).png"),
                        pointSize: 148, scale: 2, contentVersion: 1)
                }
            }
        }
        let stats = await metrics.snapshot()
        XCTAssertEqual(stats.requests.count, 20)
        XCTAssertEqual(stats.peak, 4)
    }

    func testCancelingOneSubscriberDoesNotCancelAnotherVisibleCell() async throws {
        let metrics = ThumbnailLoadMetrics()
        let provider = provider(delay: .milliseconds(150), metrics: metrics)
        let url = URL(fileURLWithPath: "/tmp/shared-cancellation.png")
        let first = Task { await provider.thumbnail(for: url, pointSize: 148, scale: 2, contentVersion: 1) }
        try await waitForRequests(1, metrics: metrics)
        let second = Task { await provider.thumbnail(for: url, pointSize: 148, scale: 2, contentVersion: 1) }
        await Task.yield()
        first.cancel()
        let canceled = await first.value
        let visible = await second.value
        XCTAssertNil(canceled.image)
        XCTAssertNotNil(visible.image)
        let stats = await metrics.snapshot()
        XCTAssertEqual(stats.requests.count, 1)
    }

    func testCanceledQueuedCellNeverStartsAndActiveCancellationFreesSlot() async throws {
        let metrics = ThumbnailLoadMetrics()
        let provider = provider(limit: 1, delay: .milliseconds(150), metrics: metrics)
        let first = Task { await provider.thumbnail(for: URL(fileURLWithPath: "/tmp/active.png"),
            pointSize: 148, scale: 2, contentVersion: 1) }
        try await waitForRequests(1, metrics: metrics)
        let queued = Task { await provider.thumbnail(for: URL(fileURLWithPath: "/tmp/abandoned.png"),
            pointSize: 148, scale: 2, contentVersion: 1) }
        await Task.yield()
        queued.cancel()
        let abandoned = await queued.value
        XCTAssertNil(abandoned.image)
        first.cancel()
        _ = await first.value
        let next = await provider.thumbnail(for: URL(fileURLWithPath: "/tmp/visible.png"),
            pointSize: 148, scale: 2, contentVersion: 1)
        XCTAssertNotNil(next.image)
        let stats = await metrics.snapshot()
        XCTAssertEqual(stats.requests.map(\.lastPathComponent), ["active.png", "visible.png"])
        XCTAssertEqual(stats.peak, 1)
    }

    func testReusedCellRestoresNativeThumbnailImmediatelyWithoutFade() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("portrait.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let result = await SystemThumbnailProvider.shared.thumbnail(for: url, pointSize: 148,
            scale: scale, contentVersion: 7)
        let cached = try XCTUnwrap(result.image)
        XCTAssertLessThanOrEqual(max(cached.pixelSize.width, cached.pixelSize.height), 148 * scale + 1)
        let item = ThumbnailCollectionItem()
        item.configure(with: url, contentVersion: 7)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = item.view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let imageView = try XCTUnwrap(item.imageView)
        imageView.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            imageView.animator().alphaValue = 1
        }, completionHandler: nil)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(imageView.layer?.animation(forKey: "opacity"), "The fixture must still be fading when it is recycled")
        item.prepareForReuse()
        item.configure(with: url, contentVersion: 7)
        XCTAssertTrue(item.imageView?.image === cached, "A revisit must paint synchronously from the cache")
        XCTAssertEqual(item.imageView?.alphaValue, 1)
        XCTAssertNil(imageView.layer?.animation(forKey: "opacity"), "A cached revisit must not inherit a previous image's unfinished fade")
        item.configure(with: url, contentVersion: 8)
        XCTAssertNil(item.imageView?.image, "File replacement must still invalidate the cached bitmap")
        item.prepareForReuse()
        try FileManager.default.removeItem(at: url)
        let missing = await SystemThumbnailProvider.shared.thumbnail(for: url, pointSize: 148,
            scale: scale, contentVersion: 7, allowsCachedThumbnail: false)
        XCTAssertNil(missing.image, "A missing-source refresh must not reuse stale cached pixels")
        XCTAssertEqual(missing.unavailableMessage, "原文件不可用")
    }

    func testVideoBadgeSurvivesReuseAndInvalidatesOnReplacement() throws {
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mov")
        let key = thumbnailDurationCache.key(for: url, contentVersion: 7)
        thumbnailDurationCache.cache.setObject("0:42", forKey: key)
        defer { thumbnailDurationCache.cache.removeObject(forKey: key) }
        let item = ThumbnailCollectionItem()
        item.configure(with: url, mediaKind: .video, contentVersion: 7)
        item.prepareForReuse()
        item.configure(with: url, mediaKind: .video, contentVersion: 7)
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        XCTAssertEqual(view.badgeLabel?.stringValue, "0:42")
        item.configure(with: url, mediaKind: .video, contentVersion: 8)
        XCTAssertEqual(view.badgeLabel?.isHidden, true)
    }
}
