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
}
