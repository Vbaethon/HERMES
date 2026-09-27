import AppKit
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailAccessibilityTests: XCTestCase {
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
