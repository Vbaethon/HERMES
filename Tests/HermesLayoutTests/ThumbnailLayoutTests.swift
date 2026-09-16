import AppKit
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailLayoutTests: XCTestCase {
    func testGridWrapsAndTracksViewportAfterDownloadAndResize() async throws {
        _ = NSApplication.shared
        let grid = ThumbnailGridController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        let items = (0..<40).map {
            ThumbnailGridItem(id: "item-\($0)", url: URL(fileURLWithPath: "/tmp/hermes-layout-fixture-\($0).png"), status: .finished, mediaKind: .photo, contentVersion: 1)
        }
        grid.updateItems(items, animatingDifferences: false)
        for width in [800.0, 520.0, 1100.0] {
            scroll.setFrameSize(NSSize(width: width, height: 500))
            scroll.tile()
            scroll.layoutSubtreeIfNeeded()
            grid.nsCollectionView.collectionViewLayout?.invalidateLayout()
            grid.nsCollectionView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(grid.nsCollectionView.frame.width, scroll.contentView.bounds.width, accuracy: 1)
            let layout = try XCTUnwrap(grid.nsCollectionView.collectionViewLayout)
            let frames = (0..<40).compactMap { layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
            XCTAssertEqual(frames.count, 40)
            XCTAssertGreaterThan(Set(frames.map { Int($0.minY) }).count, 1, "Grid must wrap into rows")
            XCTAssertLessThanOrEqual(frames.map(\.maxX).max() ?? .infinity, scroll.contentView.bounds.width + 1)
            XCTAssertEqual(scroll.frame.width, width, accuracy: 1, "Items must not enlarge their viewport")
        }
    }
    func testSamePathWithNewContentVersionClearsOldThumbnail() {
        let item = ThumbnailCollectionItem()
        _ = item.view
        let url = URL(fileURLWithPath: "/tmp/hermes-thumbnail-version-fixture.png")
        item.configure(with: url, contentVersion: 1)
        let oldImage = NSImage(size: NSSize(width: 32, height: 32))
        item.imageView?.image = oldImage
        item.configure(with: url, contentVersion: 1)
        XCTAssertTrue(item.imageView?.image === oldImage)
        item.configure(with: url, contentVersion: 2)
        XCTAssertNil(item.imageView?.image)
    }

}
