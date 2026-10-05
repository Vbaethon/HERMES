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
