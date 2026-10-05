import AppKit
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailLayoutTests: XCTestCase {
    func testScrollingKeepsFixedLayoutAndUpdatesVisibleRowsOnRetainedLayers() async throws {
        _ = NSApplication.shared
        let grid = ThumbnailGridController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 350))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        grid.updateItems((0..<200).map {
            ThumbnailGridItem(id: "scroll-\($0)", url: URL(fileURLWithPath: "/tmp/scroll-row-\($0).png"),
                status: .finished, mediaKind: .photo, contentVersion: 1)
        }, animatingDifferences: false)
        scroll.layoutSubtreeIfNeeded()
        grid.nsCollectionView.layoutSubtreeIfNeeded()
        let layout = try XCTUnwrap(grid.nsCollectionView.collectionViewLayout)
        let before = Set(grid.nsCollectionView.visibleItems().compactMap { grid.nsCollectionView.indexPath(for: $0) })
        XCTAssertNotNil(grid.nsCollectionView.layer)
        XCTAssertNotNil(scroll.contentView.layer)
        let bounds = grid.nsCollectionView.bounds
        XCTAssertFalse(layout.shouldInvalidateLayout(forBoundsChange: bounds.offsetBy(dx: 0, dy: 250)))
        XCTAssertTrue(layout.shouldInvalidateLayout(forBoundsChange:
            NSRect(origin: bounds.origin, size: NSSize(width: bounds.width + 150, height: bounds.height))))
        let distant = try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: 150, section: 0)))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: distant.frame.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        grid.nsCollectionView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(75))
        let after = Set(grid.nsCollectionView.visibleItems().compactMap { grid.nsCollectionView.indexPath(for: $0) })
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(before.isDisjoint(with: after), "Panning without layout invalidation must still recycle visible rows")
        XCTAssertTrue(after.contains(IndexPath(item: 150, section: 0)))
        grid.updateSectionInset(ThumbnailCollectionStyle.sectionInset(additionalBottomInset: 90))
        grid.nsCollectionView.layoutSubtreeIfNeeded()
        XCTAssertEqual((layout as? NSCollectionViewFlowLayout)?.sectionInset.bottom, 90)
        grid.updateItems([], animatingDifferences: false)
        XCTAssertFalse(grid.hasPresentedItems)
    }

    func testStatusUpdatesKeepTheVisibleCellAndLoadedImage() async throws {
        _ = NSApplication.shared
        let grid = ThumbnailGridController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let url = URL(fileURLWithPath: "/tmp/hermes-status-fixture.png")
        func entry(_ status: PairItem.Status) -> ThumbnailGridItem {
            ThumbnailGridItem(id: "same", url: url, status: status, mediaKind: .livePhoto, contentVersion: 1)
        }
        grid.updateItems([entry(.waiting)], animatingDifferences: false)
        scroll.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let cell = try XCTUnwrap(grid.nsCollectionView.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailCollectionItem)
        let image = try XCTUnwrap(cell.imageView?.image)
        grid.updateItems([entry(.running)])
        try await Task.sleep(for: .milliseconds(150))
        let runningCell = grid.nsCollectionView.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailCollectionItem
        XCTAssertTrue(runningCell === cell, "Changing status must not recreate the collection cell")
        XCTAssertTrue(runningCell?.imageView?.image === image, "Changing status must not clear/reload the thumbnail")
        grid.updateItems([entry(.finished)])
        try await Task.sleep(for: .milliseconds(150))
        let finishedCell = grid.nsCollectionView.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailCollectionItem
        XCTAssertTrue(finishedCell === cell, "Completion must update the existing cell in place")
        XCTAssertTrue(finishedCell?.imageView?.image === image, "Completion must preserve the original bitmap")
        let completedView = try XCTUnwrap(finishedCell?.view as? ThumbnailItemView)
        XCTAssertTrue(completedView.compositionEffect.isRunning)
        // Queue/filter removal must not bypass the minimum playback period.
        grid.updateItems([])
        XCTAssertTrue(grid.hasPresentedItems)
        XCTAssertTrue(grid.nsCollectionView.item(at: IndexPath(item: 0, section: 0)) === cell)
        for _ in 0..<400 where grid.hasPresentedItems { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(grid.hasPresentedItems)

        grid.updateItems([entry(.running)], animatingDifferences: false)
        try await Task.sleep(for: .milliseconds(200))
        // A user-requested filter switch is immediate, not a delayed completion.
        grid.updateItems([], animatingDifferences: false, defersCompletionRemoval: false)
        XCTAssertFalse(grid.hasPresentedItems)
    }

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

    func testGridStatusChangesPreserveLoadedImage() async throws {
        _ = NSApplication.shared
        let grid = ThumbnailGridController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        let url = URL(fileURLWithPath: "/tmp/hermes-status-preservation.png")
        func update(_ status: PairItem.Status, version: TimeInterval = 1) {
            grid.updateItems([ThumbnailGridItem(id: "stable", url: url, status: status,
                mediaKind: .livePhoto, contentVersion: version)], animatingDifferences: false)
            scroll.layoutSubtreeIfNeeded()
            grid.nsCollectionView.layoutSubtreeIfNeeded()
        }
        update(.running)
        try await Task.sleep(for: .milliseconds(100))
        let indexPath = IndexPath(item: 0, section: 0)
        let original = try XCTUnwrap(grid.nsCollectionView.item(at: indexPath) as? ThumbnailCollectionItem)
        let image = NSImage(size: NSSize(width: 32, height: 32))
        original.imageView?.image = image
        original.imageView?.alphaValue = 1
        for status in [PairItem.Status.finished, .failed, .running] {
            update(status)
            let current = try XCTUnwrap(grid.nsCollectionView.item(at: indexPath) as? ThumbnailCollectionItem)
            XCTAssertTrue(current === original, "State changes must preserve the visible collection item")
            XCTAssertTrue(current.imageView?.image === image, "State changes must not clear a loaded thumbnail")
            XCTAssertEqual(current.imageView?.alphaValue, 1, "State changes must not restart the image fade")
        }
        XCTAssertTrue((original.view.accessibilityValue() as? String)?.contains("正在合成") == true)
        update(.finished, version: 2)
        let replacement = try XCTUnwrap(grid.nsCollectionView.item(at: indexPath) as? ThumbnailCollectionItem)
        XCTAssertNil(replacement.imageView?.image, "A changed file revision must still invalidate stale pixels")
        withExtendedLifetime(window) {}
    }

}
