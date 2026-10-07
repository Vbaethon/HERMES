import AppKit
import QuartzCore
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailDeletionTests: XCTestCase {
    private func items(_ count: Int) -> [ThumbnailGridItem] {
        (0..<count).map {
            ThumbnailGridItem(id: "delete-\($0)", url: URL(fileURLWithPath: "/tmp/hermes-delete-\($0).png"),
                              status: .finished, mediaKind: .photo, contentVersion: 1)
        }
    }

    private func fixture(count: Int = 70) -> (ThumbnailGridController, NSScrollView, NSWindow) {
        _ = NSApplication.shared
        let grid = ThumbnailGridController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        grid.updateItems(items(count), animatingDifferences: false)
        scroll.layoutSubtreeIfNeeded()
        grid.nsCollectionView.layoutSubtreeIfNeeded()
        return (grid, scroll, window)
    }

    func testDeletingPreservesRowStartAndFramesBeforeTheFirstRemovedItem() async throws {
        for level in 0..<4 {
            let (grid, scroll, window) = fixture()
            defer { window.orderOut(nil) }
            let zoom = grid.zoom!
            zoom.zoom(to: level)
            zoom.displayFrame(at: CACurrentMediaTime() + 10)
            try await Task.sleep(for: .milliseconds(30))
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            let before = zoom.layout.spec
            let frame = zoom.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame
            grid.updateItems(items(70).filter { ![40, 42, 69].contains(Int($0.id.dropFirst(7))!) }, animatingDifferences: false)
            XCTAssertEqual(zoom.layout.spec, before, "Deleting must not repad the entire grid to fill its last row")
            XCTAssertEqual(zoom.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.frame, frame)
            XCTAssertEqual(grid.nsCollectionView.numberOfItems(inSection: 0), 67)
        }
    }

    func testCellHonorsNativeLayoutOpacityAndZoomRestoresThatOpacity() {
        let cell = ThumbnailCollectionItem()
        cell.loadView()
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: 0, section: 0))
        attributes.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        attributes.alpha = 0.25
        cell.apply(attributes)
        XCTAssertEqual(cell.view.alphaValue, 0.25, accuracy: 0.001)
        cell.setZoomPresentationSuppressed(true)
        XCTAssertEqual(cell.view.alphaValue, 0)
        cell.setZoomPresentationSuppressed(false)
        XCTAssertEqual(cell.view.alphaValue, 0.25, accuracy: 0.001,
                       "Finishing zoom must not resurrect an item that is disappearing")
    }

    func testDeletingDuringZoomReleasesTheOldPresentationBeforeTheSnapshot() async throws {
        let (grid, _, window) = fixture()
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        let frame = zoom.layout.spec.frame(index: 68, width: zoom.layout.viewportSize.width, metrics: zoom.layout.metrics)
        zoom.beginGesture(at: CGPoint(x: frame.midX, y: frame.midY))
        zoom.changeGesture(magnification: 0.2)
        zoom.displayFrame(at: CACurrentMediaTime())
        XCTAssertFalse(zoom.overlay.isHidden)
        grid.updateItems(items(69))
        XCTAssertNil(zoom.plan)
        XCTAssertTrue(zoom.overlay.isHidden, "A held zoom image must not retain the deleted thumbnail during reflow")
        XCTAssertFalse(zoom.cellsSuppressed)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(grid.nsCollectionView.numberOfItems(inSection: 0), 69)
    }

    func testNativeDeletionFadesInPlaceWhileSurvivorsMove() async throws {
        let (grid, _, window) = fixture()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(80))
        let collection = grid.nsCollectionView
        let deleted = try XCTUnwrap(collection.item(at: IndexPath(item: 67, section: 0)))
        let survivor = try XCTUnwrap(collection.item(at: IndexPath(item: 68, section: 0)))
        let originalFrame = deleted.view.frame
        let survivorStart = survivor.view.frame
        grid.updateItems(items(70).filter { $0.id != "delete-67" })
        try await Task.sleep(for: .milliseconds(140))
        let opacity = try XCTUnwrap(deleted.view.layer?.presentation()).opacity
        XCTAssertGreaterThan(opacity, 0, "Deletion should fade through AppKit's animation transaction")
        XCTAssertLessThan(opacity, 0.95, "The removed thumbnail must start disappearing before reflow finishes")
        let fadingFrame = try XCTUnwrap(deleted.view.layer?.presentation()).frame
        XCTAssertEqual(fadingFrame.minX, originalFrame.minX, accuracy: 0.5)
        XCTAssertEqual(fadingFrame.minY, originalFrame.minY, accuracy: 0.5)
        let movingFrame = try XCTUnwrap(survivor.view.layer?.presentation()).frame
        XCTAssertNotEqual(movingFrame.origin, survivorStart.origin)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 69)
        XCTAssertTrue(collection.visibleItems().allSatisfy { $0.view.alphaValue == 1 })
        XCTAssertTrue(deleted.view.superview == nil || deleted.view.alphaValue == 0,
                      "No removed item may stay visible after the transaction")
    }

    func testConsecutiveAndDeleteAllKeepSurvivingSelectionAndClearPresentation() async throws {
        let (grid, _, window) = fixture()
        defer { window.orderOut(nil) }
        grid.applySelection(["delete-65", "delete-69"])
        grid.updateItems(items(70).filter { $0.id != "delete-68" })
        try await Task.sleep(for: .milliseconds(35))
        grid.updateItems(items(70).filter { ![67, 68, 69].contains(Int($0.id.dropFirst(7))!) })
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(grid.nsCollectionView.numberOfItems(inSection: 0), 67)
        XCTAssertEqual(grid.nsCollectionView.selectionIndexPaths, [IndexPath(item: 65, section: 0)])
        grid.updateItems([])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(grid.nsCollectionView.numberOfItems(inSection: 0), 0)
        XCTAssertTrue(grid.nsCollectionView.selectionIndexPaths.isEmpty)
        XCTAssertTrue(grid.zoom.overlay.isHidden)
        XCTAssertFalse(grid.zoom.cellsSuppressed)
    }
}
