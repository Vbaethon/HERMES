import AppKit
import QuartzCore
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailArrangementTests: XCTestCase {
    private func items(_ ids: [Int], version: TimeInterval = 1) -> [ThumbnailGridItem] {
        ids.map {
            ThumbnailGridItem(id: "arrange-\($0)", url: URL(fileURLWithPath: "/tmp/hermes-arrange-\($0).png"),
                              status: .finished, mediaKind: .photo, contentVersion: version)
        }
    }

    private func fixture(_ ids: [Int], flow: ThumbnailGridArrangementController.Flow = .newestEnd) -> (ThumbnailGridController, NSScrollView, NSWindow) {
        _ = NSApplication.shared
        let grid = ThumbnailGridController(flow: flow)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        grid.updateItems(items(ids), animatingDifferences: false)
        return (grid, scroll, window)
    }

    private func newestFrame(_ grid: ThumbnailGridController, _ scroll: NSScrollView) -> CGRect {
        let layout = grid.zoom.layout
        return layout.spec.frame(index: layout.count - 1, width: layout.viewportSize.width, metrics: layout.metrics)
            .offsetBy(dx: 0, dy: -scroll.contentView.documentVisibleRect.minY)
    }

    private func assertFrame(_ actual: CGRect, _ expected: CGRect, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, message, file: file, line: line)
    }

    func testZoomDeleteRefreshFilterInsertAndRestoreShareTheCurrentNewestColumn() async throws {
        for level in 0..<4 {
            let ids = Array(0..<200)
            let (grid, scroll, window) = fixture(ids)
            defer { window.orderOut(nil) }
            grid.zoom.zoom(to: (level + 1) % 4)
            grid.zoom.displayFrame(at: CACurrentMediaTime() + 10)
            try await Task.sleep(for: .milliseconds(30))
            let focal = grid.zoom.layout.spec.frame(index: 90, width: grid.zoom.layout.viewportSize.width,
                                                  metrics: grid.zoom.layout.metrics)
            let point = CGPoint(x: focal.minX + focal.width * 0.16, y: focal.midY)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: point.y - 220))
            scroll.reflectScrolledClipView(scroll.contentView)
            grid.zoom.beginGesture(at: point)
            grid.zoom.zoom(to: level)
            grid.zoom.displayFrame(at: CACurrentMediaTime() + 10)
            try await Task.sleep(for: .milliseconds(30))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: grid.zoom.maximumOrigin))
            scroll.reflectScrolledClipView(scroll.contentView)
            let tail = newestFrame(grid, scroll)
            let deleted = ids.filter { ![11, 45, 191].contains($0) }
            let filtered = deleted.filter { $0 % 3 != 0 }
            let snapshots = [deleted, deleted, filtered, deleted, deleted + [200, 201],
                             deleted.filter { $0 != 193 } + [200, 201, 202]]
            for (step, snapshot) in snapshots.enumerated() {
                // A refresh reconstructs values; it must never reconstruct the
                // row alignment, even when a scan adds/removes several files.
                grid.updateItems(items(snapshot, version: TimeInterval(step + 2)), animatingDifferences: false)
                try await Task.sleep(for: .milliseconds(30))
                let frame = newestFrame(grid, scroll)
                XCTAssertEqual(frame.minX, tail.minX, accuracy: 0.5, "Preset \(level), update \(step): newest column changed")
                XCTAssertEqual(frame.minY, tail.minY, accuracy: 0.5, "Preset \(level), update \(step): newest viewport anchor changed")
                XCTAssertEqual(grid.nsCollectionView.numberOfItems(inSection: 0), snapshot.count)
                let cell = try XCTUnwrap(grid.nsCollectionView.item(at: IndexPath(item: snapshot.count - 1, section: 0)))
                let native = cell.view.frame.offsetBy(dx: 0, dy: -scroll.contentView.documentVisibleRect.minY)
                XCTAssertEqual(native.minX, tail.minX, accuracy: 0.5)
                XCTAssertEqual(native.minY, tail.minY, accuracy: 0.5)
            }
        }
    }

    func testRefreshWithNewFilesDoesNotSwitchBackToHeadCompaction() async throws {
        let ids = Array(0..<200)
        let (grid, scroll, window) = fixture(ids)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(50))
        let zoom = grid.zoom!
        scroll.contentView.scroll(to: NSPoint(x: 0, y: zoom.maximumOrigin / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        let oldSpec = zoom.layout.spec
        let focal = ZoomGeometry.nearestIndex(to: CGPoint(x: zoom.layout.viewportSize.width / 2,
                                                          y: scroll.contentView.documentVisibleRect.minY + 1),
                                             count: ids.count, width: zoom.layout.viewportSize.width,
                                             spec: oldSpec, metrics: zoom.layout.metrics)!
        let before = oldSpec.frame(index: focal, width: zoom.layout.viewportSize.width, metrics: zoom.layout.metrics)
            .minY - scroll.contentView.documentVisibleRect.minY
        let next = ids.filter { $0 != 175 } + [200, 201]
        grid.updateItems(items(next), animatingDifferences: false)
        try await Task.sleep(for: .milliseconds(30))
        let columns = ZoomGeometry.columns[oldSpec.level]
        let expectedLeading = (oldSpec.leadingSlots + ids.count - next.count + columns) % columns
        XCTAssertEqual(zoom.layout.spec.leadingSlots, expectedLeading)
        let after = zoom.layout.spec.frame(index: next.firstIndex(of: focal)!, width: zoom.layout.viewportSize.width,
                                         metrics: zoom.layout.metrics).minY - scroll.contentView.documentVisibleRect.minY
        XCTAssertEqual(after, before, accuracy: 0.5,
                       "Every mixed scan must retain the same reading anchor while counting from the tail")
    }

    func testMetadataRefreshDoesNotFinishZoomOrMoveCells() async throws {
        let ids = Array(0..<100)
        let (grid, scroll, window) = fixture(ids)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(30))
        let frame = grid.zoom.layout.spec.frame(index: 98, width: grid.zoom.layout.viewportSize.width,
                                              metrics: grid.zoom.layout.metrics)
        grid.zoom.beginGesture(at: CGPoint(x: frame.midX, y: frame.midY))
        grid.zoom.changeGesture(magnification: 0.2)
        grid.zoom.displayFrame(at: CACurrentMediaTime())
        let spec = grid.zoom.layout.spec
        let origin = scroll.contentView.documentVisibleRect.minY
        let cells = Set(grid.nsCollectionView.visibleItems().map(ObjectIdentifier.init))
        grid.updateItems(items(ids, version: 2))
        XCTAssertNotNil(grid.zoom.plan)
        XCTAssertEqual(grid.zoom.layout.spec, spec)
        XCTAssertEqual(scroll.contentView.documentVisibleRect.minY, origin)
        XCTAssertEqual(Set(grid.nsCollectionView.visibleItems().map(ObjectIdentifier.init)), cells)
    }

    func testExpandingSnapshotMovesOlderPhotosBackwardWithoutAWholeRowJump() async throws {
        let ids = Array(0..<70)
        let (grid, scroll, window) = fixture(ids)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(60))
        let latest = try XCTUnwrap(grid.nsCollectionView.item(at: IndexPath(item: 69, section: 0)))
        let before = latest.view.frame.offsetBy(dx: 0, dy: -scroll.contentView.documentVisibleRect.minY)
        grid.updateItems(items(ids + [70]))
        try await Task.sleep(for: .milliseconds(140))
        let moving = try XCTUnwrap(latest.view.layer?.presentation()).frame
            .offsetBy(dx: 0, dy: -scroll.contentView.documentVisibleRect.minY)
        XCTAssertLessThan(moving.minX, before.minX, "Adding at the newest end must shift earlier items backwards")
        XCTAssertEqual(moving.minY, before.minY, accuracy: 0.5,
                       "Allocating a leading row must not move the tail vertically during animation")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(grid.nsCollectionView.item(at: IndexPath(item: 69, section: 0)) === latest)
        let inserted = try XCTUnwrap(grid.nsCollectionView.item(at: IndexPath(item: 70, section: 0)))
        let after = inserted.view.frame.offsetBy(dx: 0, dy: -scroll.contentView.documentVisibleRect.minY)
        assertFrame(after, before)
    }

    func testSparseLibraryAndAlbumAlwaysStartAtTheLeftAcrossEveryPresetAndUpdate() async throws {
        for flow in [ThumbnailGridArrangementController.Flow.newestEnd, .oldestStart] {
            for level in 0..<4 {
                let (grid, _, window) = fixture([0, 1], flow: flow)
                defer { window.orderOut(nil) }
                grid.zoom.zoom(to: level)
                grid.zoom.displayFrame(at: CACurrentMediaTime() + 10)
                try await Task.sleep(for: .milliseconds(30))
                let columns = ZoomGeometry.columns[level]
                for (step, count) in [1, 2, columns - 1, columns, columns + 1, 2, 2, 0, 2].enumerated() {
                    grid.updateItems(items(Array(0..<count), version: TimeInterval(step + 2)), animatingDifferences: false)
                    try await Task.sleep(for: .milliseconds(30))
                    let layout = grid.zoom.layout
                    XCTAssertEqual(layout.spec.leadingSlots, 0, "\(flow), preset \(level), count \(count)")
                    for index in 0..<count {
                        let cell = try XCTUnwrap(grid.nsCollectionView.item(at: IndexPath(item: index, section: 0)))
                        let expected = ZoomGridSpec(level: level).frame(index: index, width: layout.viewportSize.width, metrics: layout.metrics)
                        assertFrame(cell.view.frame, expected, "Each visible row begins on the left")
                    }
                }
            }
        }
    }

    func testLibraryAndAlbumUseOppositeCompactionWhileKeepingTheDeletedPhotoInPlace() async throws {
        for flow in [ThumbnailGridArrangementController.Flow.newestEnd, .oldestStart] {
            let ids = Array(0..<70)
            let (grid, scroll, window) = fixture(ids, flow: flow)
            defer { window.orderOut(nil) }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: grid.zoom.maximumOrigin))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(60))
            let earlier = try XCTUnwrap(grid.nsCollectionView.item(at: IndexPath(item: 66, section: 0)))
            let removed = try XCTUnwrap(grid.nsCollectionView.item(at: IndexPath(item: 67, section: 0)))
            let following = try XCTUnwrap(grid.nsCollectionView.item(at: IndexPath(item: 68, section: 0)))
            let oldEarlier = earlier.view.frame, oldRemoved = removed.view.frame, oldFollowing = following.view.frame
            grid.updateItems(items(ids.filter { $0 != 67 }))
            try await Task.sleep(for: .milliseconds(140))
            let fading = try XCTUnwrap(removed.view.layer?.presentation())
            assertFrame(fading.frame, oldRemoved)
            XCTAssertLessThan(fading.opacity, 0.95)
            let movingEarlier = try XCTUnwrap(earlier.view.layer?.presentation()).frame
            let movingFollowing = try XCTUnwrap(following.view.layer?.presentation()).frame
            if flow == .newestEnd {
                XCTAssertGreaterThan(movingEarlier.minX, oldEarlier.minX)
                assertFrame(movingFollowing, oldFollowing)
            } else {
                assertFrame(movingEarlier, oldEarlier)
                XCTAssertLessThan(movingFollowing.minX, oldFollowing.minX)
            }
            try await Task.sleep(for: .milliseconds(350))
            let settled = flow == .newestEnd ? earlier : following
            let frame = settled.view.frame
            grid.updateItems(items(ids.filter { $0 != 67 }, version: 2), animatingDifferences: false)
            assertFrame(settled.view.frame, frame, "Refresh cannot change the selected flow after deletion")
        }
    }

    func testEmptyFilterAndOrderChangesRetainTheZoomedTail() async throws {
        let ids = Array(0..<71)
        let (grid, scroll, window) = fixture(ids)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(30))
        let focal = grid.zoom.layout.spec.frame(index: 20, width: grid.zoom.layout.viewportSize.width,
                                              metrics: grid.zoom.layout.metrics)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: focal.midY - 220))
        scroll.reflectScrolledClipView(scroll.contentView)
        grid.zoom.beginGesture(at: CGPoint(x: focal.midX, y: focal.midY))
        grid.zoom.zoom(to: 0)
        grid.zoom.displayFrame(at: CACurrentMediaTime() + 10)
        try await Task.sleep(for: .milliseconds(30))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: grid.zoom.maximumOrigin))
        scroll.reflectScrolledClipView(scroll.contentView)
        let before = newestFrame(grid, scroll)
        let snapshots = [[], ids, Array(ids.reversed()), ids]
        for snapshot in snapshots {
            grid.updateItems(items(snapshot), animatingDifferences: false)
            try await Task.sleep(for: .milliseconds(30))
            if !snapshot.isEmpty {
                assertFrame(newestFrame(grid, scroll), before,
                               "Empty filters and refreshed data order must use the existing tail policy")
            }
        }
    }

    func testDeletingAllKeepsTheViewportWhileTheLastCellsFade() async throws {
        let (grid, scroll, window) = fixture(Array(0..<70))
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(60))
        let latest = try XCTUnwrap(grid.nsCollectionView.item(at: IndexPath(item: 69, section: 0)))
        let before = latest.view.frame
        let origin = scroll.contentView.documentVisibleRect.minY
        grid.updateItems([])
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertEqual(scroll.contentView.documentVisibleRect.minY, origin, accuracy: 0.5,
                       "The empty destination must not scroll disappearing photos away mid-fade")
        let fading = try XCTUnwrap(latest.view.layer?.presentation())
        assertFrame(fading.frame, before)
        XCTAssertLessThan(fading.opacity, 0.95)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(scroll.contentView.documentVisibleRect.minY, 0, accuracy: 0.5)
        XCTAssertEqual(grid.nsCollectionView.numberOfItems(inSection: 0), 0)
    }
}
