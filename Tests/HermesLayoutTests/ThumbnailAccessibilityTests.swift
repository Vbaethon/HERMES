import AppKit
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailAccessibilityTests: XCTestCase {
    func testCompositionEffectRestoresArtworkAndDoesNotSurviveReuse() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("artwork.png")
        let image = NSImage(size: NSSize(width: 80, height: 120), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        try image.tiffRepresentation!.write(to: url)
        let item = ThumbnailCollectionItem()
        item.configure(with: url, status: .running, mediaKind: .livePhoto)
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        for _ in 0..<200 where !view.compositionEffect.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        let original = try XCTUnwrap(item.imageView?.image)
        XCTAssertTrue(view.compositionEffect.isRunning)
        XCTAssertEqual(view.compositionEffect.frame, item.imageView?.frame)
        XCTAssertEqual(view.failureLabel?.isHidden, true)
        XCTAssertTrue((view.accessibilityValue() as? String)?.contains("正在合成") == true)
        XCTAssertNil(view.compositionEffect.hitTest(.zero))
        item.configure(with: url, status: .finished, mediaKind: .livePhoto)
        XCTAssertTrue(view.compositionEffect.isRunning, "Fast completion must keep the mesh running for the minimum duration")
        XCTAssertTrue(item.imageView?.image === original)
        for _ in 0..<400 where !view.compositionEffect.isHidden { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(view.compositionEffect.isHidden)
        item.configure(with: url, status: .running, mediaKind: .livePhoto)
        item.prepareForReuse()
        XCTAssertFalse(view.compositionEffect.isRunning)
        XCTAssertTrue(view.compositionEffect.isHidden)
        XCTAssertTrue(view.compositionEffect.subviews.isEmpty)
        XCTAssertNil(item.imageView?.image)
    }

    func testRepeatedCompletionDoesNotRestartTheThreeSecondDeadline() async throws {
        let effect = ThumbnailCompositionEffect(frame: NSRect(x: 0, y: 0, width: 148, height: 148))
        let image = NSImage(size: NSSize(width: 32, height: 32))
        let start = ContinuousClock.now
        var ended: ContinuousClock.Instant?
        effect.onPresentationEnded = { ended = .now }
        effect.update(image: image, running: true)
        effect.update(image: image, running: false)
        try await Task.sleep(for: .milliseconds(1400))
        effect.update(image: image, running: false)
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertTrue(effect.isRunning, "The effect must still be playing before three seconds")
        effect.update(image: image, running: false)
        for _ in 0..<140 where ended == nil { try await Task.sleep(for: .milliseconds(10)) }
        let finish = try XCTUnwrap(ended)
        XCTAssertGreaterThanOrEqual(start.duration(to: finish), .seconds(3))
        XCTAssertLessThan(start.duration(to: finish), .seconds(4.2), "Repeated UI refreshes must not extend the deadline")
        XCTAssertTrue(effect.isHidden)
    }

    func testNewRunCancelsAnOldPendingExitWithoutClearingTheMesh() async throws {
        let effect = ThumbnailCompositionEffect(frame: NSRect(x: 0, y: 0, width: 148, height: 148))
        let image = NSImage(size: NSSize(width: 32, height: 32))
        effect.update(image: image, running: true)
        let host = try XCTUnwrap(effect.subviews.first)
        effect.update(image: image, running: false)
        try await Task.sleep(for: .milliseconds(350))
        effect.update(image: image, running: true)
        XCTAssertTrue(effect.subviews.first === host)
        XCTAssertEqual(effect.alphaValue, 1)
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(effect.isRunning)
        XCTAssertFalse(effect.isHidden)
        effect.reset()
        XCTAssertTrue(effect.subviews.isEmpty)
    }

    func testFailureRemainsVisibleAndReadableWhenSelected() throws {
        let item = ThumbnailCollectionItem()
        item.configure(with: URL(fileURLWithPath: "/tmp/example.heic"), status: .failed, mediaKind: .livePhoto)
        item.isSelected = true
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        XCTAssertEqual(view.accessibilityLabel(), "example.heic，Live Photo")
        XCTAssertEqual(view.accessibilityValue() as? String, "合成失败，已选择")
        XCTAssertEqual(view.failureLabel?.isHidden, false)
        item.isSelected = false
        XCTAssertEqual(view.accessibilityValue() as? String, "合成失败，未选择")
        XCTAssertEqual(view.failureLabel?.isHidden, false)
    }

    func testReuseClearsFailureAndOldIdentity() throws {
        let item = ThumbnailCollectionItem()
        item.configure(with: URL(fileURLWithPath: "/tmp/old.heic"), status: .failed)
        item.prepareForReuse()
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        XCTAssertNil(view.accessibilityLabel())
        XCTAssertEqual(view.failureLabel?.isHidden, true)
        item.configure(with: URL(fileURLWithPath: "/tmp/new.mov"), mediaKind: .video)
        XCTAssertEqual(view.accessibilityLabel(), "new.mov，视频")
        XCTAssertEqual(view.failureLabel?.isHidden, true)
    }

    func testMissingFileHasExplicitPlaceholderAndRecovers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("recovered.png")
        let result = await SystemThumbnailProvider.shared.thumbnail(for:url,pointSize:148,scale:2)
        XCTAssertNil(result.image)
        XCTAssertEqual(result.unavailableMessage,"原文件不可用")
        let item = ThumbnailCollectionItem()
        item.configure(with:url,unavailableMessage:"原文件不可用")
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        for _ in 0..<100 where view.placeholderLabel?.isHidden != false { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(view.placeholderLabel?.isHidden,false)
        XCTAssertEqual(view.failureLabel?.stringValue,"原文件不可用")
        XCTAssertTrue((view.accessibilityValue() as? String)?.contains("原文件不可用") == true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:3,hasAlpha:false,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        try bitmap.representation(using:.png,properties:[:])!.write(to:url)
        item.configure(with:url,contentVersion:1)
        for _ in 0..<200 where item.imageView?.image == nil { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertNotNil(item.imageView?.image)
        XCTAssertEqual(view.placeholderLabel?.isHidden,true)
        XCTAssertEqual(view.failureLabel?.isHidden,true)
    }
}
