import AppKit
import QuartzCore
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailZoomTests: XCTestCase {
    private func fixture(count: Int = 500, animatingDifferences: Bool = false) -> (ThumbnailGridController, NSScrollView, NSWindow) {
        _ = NSApplication.shared
        let grid = ThumbnailGridController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        grid.updateItems((0..<count).map {
            ThumbnailGridItem(id: "zoom-\($0)", url: URL(fileURLWithPath: "/tmp/hermes-zoom-\($0).png"),
                              status: .finished, mediaKind: .photo, contentVersion: 1)
        }, animatingDifferences: animatingDifferences)
        scroll.layoutSubtreeIfNeeded()
        grid.nsCollectionView.layoutSubtreeIfNeeded()
        return (grid, scroll, window)
    }

    func testAllAdjacentDirectionsKeepSourceFocalRowOpaqueAndHandoffAligned() async throws {
        let (grid, scroll, window) = fixture()
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        for (from, to) in [(0, 1), (1, 0), (1, 2), (2, 1), (2, 3), (3, 2)] {
            zoom.zoom(to: from)
            zoom.advanceAnimation(at: CACurrentMediaTime() + 10)
            await Task.yield()
            let layout = zoom.layout, width = layout.viewportSize.width, metrics = layout.metrics
            let focal = 203
            let frame = layout.spec.frame(index: focal, width: width, metrics: metrics)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: frame.midY - 270))
            scroll.reflectScrolledClipView(scroll.contentView)
            zoom.beginGesture(at: CGPoint(x: frame.midX, y: frame.midY))
            let plan = try XCTUnwrap(zoom.plan)
            XCTAssertEqual(plan.anchor.index, focal)
            let columns = ZoomGeometry.columns[from]
            let start = ((focal + plan.sourceSpec.leadingSlots) / columns) * columns - plan.sourceSpec.leadingSlots
            for fraction in [0.01, 0.2, 0.5, 0.8, 0.99] {
                let target = CGFloat(from) + CGFloat(to - from) * fraction
                let ratio = ZoomGeometry.side(width: width, position: target, metrics: metrics) /
                    ZoomGeometry.side(width: width, position: zoom.position, metrics: metrics)
                zoom.changeGesture(magnification: ratio * ratio - 1)
                XCTAssertEqual(zoom.position, target, accuracy: 0.0001)
                XCTAssertTrue(zoom.overlay.superview === grid.nsCollectionView,
                              "Zoom content must stay inside the native scroll document for toolbar blending")
                XCTAssertTrue(scroll.documentView === grid.nsCollectionView)
                XCTAssertEqual(grid.nsCollectionView.alphaValue, 1,
                               "Never remove the document from the native background effect during zoom")
                XCTAssertEqual(zoom.overlay.frame, scroll.contentView.documentVisibleRect)
                for index in start..<(start + columns) {
                    XCTAssertEqual(zoom.overlay.focalOpacity(at: index), 1,
                                   "All six directions retain the same source row, including 9/7 and 7/5")
                }
                XCTAssertLessThan(zoom.overlay.retainedTileCount, 300, "Presentation work must depend on the viewport, not library size")
            }
            let ratio = ZoomGeometry.side(width: width, columns: ZoomGeometry.columns[to], metrics: metrics) /
                ZoomGeometry.side(width: width, position: zoom.position, metrics: metrics)
            zoom.changeGesture(magnification: ratio * ratio - 1)
            zoom.endGesture()
            zoom.advanceAnimation(at: CACurrentMediaTime() + 10)
            let expected = layout.spec.frame(index: focal, width: width, metrics: metrics)
                .offsetBy(dx: 0, dy: -scroll.contentView.bounds.minY)
            let displayed = try XCTUnwrap(zoom.overlay.focalFrames[focal])
            XCTAssertEqual(displayed.midX, expected.midX, accuracy: 0.01)
            XCTAssertEqual(displayed.midY, expected.midY, accuracy: 0.01)
            XCTAssertEqual(displayed.size.width, expected.size.width, accuracy: 0.01)
            XCTAssertEqual(zoom.overlay.frame, scroll.contentView.documentVisibleRect,
                           "The held presentation must stay in the viewport after native scrolling")
            await Task.yield()
        }
    }

    func testColumnPresetSurvivesWindowResizeAndNewestRowRemainsFull() async {
        let (grid, scroll, window) = fixture()
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        for level in 0..<4 {
            zoom.zoom(to: level)
            zoom.advanceAnimation(at: CACurrentMediaTime() + 10)
            await Task.yield()
            scroll.contentView.scroll(to: CGPoint(x: 0, y: zoom.maximumOrigin))
            scroll.reflectScrolledClipView(scroll.contentView)
            for width in [700.0, 1100.0, 850.0] {
                window.setContentSize(NSSize(width: width, height: 600))
                scroll.layoutSubtreeIfNeeded()
                zoom.viewportChanged()
                XCTAssertEqual(zoom.layout.spec.level, level)
                assertNewestRowIsFull(zoom)
                XCTAssertEqual(scroll.contentView.bounds.minY, zoom.maximumOrigin, accuracy: 0.5)
            }
        }
    }

    func testHandoffRetainsTheDisplayedFocalBitmapBeforeAsyncCellLoading() async throws {
        let (grid, scroll, window) = fixture()
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        try await Task.sleep(for: .milliseconds(150))
        for case let cell as ThumbnailCollectionItem in grid.nsCollectionView.visibleItems() {
            let image = NSImage(size: NSSize(width: 32, height: 64), flipped: false) { rect in
                NSColor.systemOrange.setFill(); rect.fill(); return true
            }
            cell.imageView?.image = image
            cell.imageView?.alphaValue = 1
            (cell.view as? ThumbnailItemView)?.updateImageFrame(for: image)
        }
        let focal = zoom.layout.count - 3
        let path = IndexPath(item: focal, section: 0)
        let frame = zoom.layout.layoutAttributesForItem(at: path)!.frame
        zoom.beginGesture(at: CGPoint(x: frame.midX, y: frame.midY))
        let retained = try XCTUnwrap(zoom.overlay.image(at: focal))
        let ratio = ZoomGeometry.side(width: scroll.contentSize.width, columns: 9, metrics: zoom.layout.metrics) /
            ZoomGeometry.side(width: scroll.contentSize.width, columns: 5, metrics: zoom.layout.metrics)
        zoom.changeGesture(magnification: ratio * ratio - 1)
        zoom.endGesture()
        zoom.advanceAnimation(at: CACurrentMediaTime() + 10)
        let cell = try XCTUnwrap(grid.nsCollectionView.item(at: path) as? ThumbnailCollectionItem)
        let native = try XCTUnwrap(cell.imageView?.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertTrue(native === retained, "The native cell must receive the same bitmap before the overlay disappears")
        XCTAssertEqual(cell.imageView?.alphaValue, 1)
        await Task.yield()
        XCTAssertTrue(zoom.overlay.isHidden)
        XCTAssertEqual(grid.nsCollectionView.alphaValue, 1)
    }

    private func assertNewestRowIsFull(_ zoom: ThumbnailGridZoomController, file: StaticString = #filePath, line: UInt = #line) {
        let layout = zoom.layout, columns = ZoomGeometry.columns[layout.spec.level]
        let width = layout.viewportSize.width, metrics = layout.metrics
        let row = (max(0, layout.count - columns)..<layout.count).map {
            layout.spec.frame(index: $0, width: width, metrics: metrics)
        }
        guard let first = row.first, let last = row.last else { return }
        XCTAssertEqual(last.maxX, width - metrics.right, accuracy: 0.001, file: file, line: line)
        if layout.count >= columns { XCTAssertEqual(first.minX, metrics.left, accuracy: 0.001, file: file, line: line) }
        XCTAssertTrue(row.allSatisfy { abs($0.minY - last.minY) < 0.001 }, file: file, line: line)
        XCTAssertEqual(row.count, min(layout.count, columns), file: file, line: line)
    }

    func testStartupAndEveryAdjacentZoomKeepNewestAtBottomAcrossRemainders() async throws {
        for count in [2, 68, 70, 71] {
            let (grid, scroll, window) = fixture(count: count, animatingDifferences: true)
            let zoom = grid.zoom!
            await Task.yield()
            XCTAssertEqual(scroll.contentView.bounds.minY, zoom.maximumOrigin, accuracy: 0.5)
            assertNewestRowIsFull(zoom)
            for (from, to) in [(0, 1), (1, 0), (1, 2), (2, 1), (2, 3), (3, 2)] {
                zoom.zoom(to: from)
                zoom.advanceAnimation(at: CACurrentMediaTime() + 10)
                await Task.yield()
                assertNewestRowIsFull(zoom)
                XCTAssertEqual(scroll.contentView.bounds.minY, zoom.maximumOrigin, accuracy: 0.5)
                let layout = zoom.layout, metrics = layout.metrics, width = layout.viewportSize.width
                let focal = count - 1
                let frame = layout.spec.frame(index: focal, width: width, metrics: metrics)
                zoom.beginGesture(at: CGPoint(x: frame.midX, y: frame.midY))
                XCTAssertTrue(try XCTUnwrap(zoom.plan).pinsToNewest)
                let ratio = ZoomGeometry.side(width: width, columns: ZoomGeometry.columns[to], metrics: metrics) / frame.width
                zoom.changeGesture(magnification: ratio * ratio - 1)
                XCTAssertEqual(zoom.overlay.focalOpacity(at: focal), 1)
                zoom.endGesture()
                zoom.advanceAnimation(at: CACurrentMediaTime() + 10)
                assertNewestRowIsFull(zoom)
                XCTAssertEqual(scroll.contentView.bounds.minY, zoom.maximumOrigin, accuracy: 0.5)
                let expected = layout.spec.frame(index: focal, width: width, metrics: metrics)
                    .offsetBy(dx: 0, dy: -scroll.contentView.bounds.minY)
                let displayed = try XCTUnwrap(zoom.overlay.focalFrames[focal])
                XCTAssertEqual(displayed.midX, expected.midX, accuracy: 0.01)
                XCTAssertEqual(displayed.midY, expected.midY, accuracy: 0.01)
                await Task.yield()
            }
            window.orderOut(nil)
        }
    }

    func testAddingNewMediaFollowsNewestOnlyWhenAlreadyAtBottom() async {
        let (grid, scroll, window) = fixture(count: 71)
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        func entries(_ count: Int) -> [ThumbnailGridItem] {
            (0..<count).map {
                ThumbnailGridItem(id: "zoom-\($0)", url: URL(fileURLWithPath: "/tmp/hermes-zoom-\($0).png"),
                                  status: .finished, mediaKind: .photo, contentVersion: 1)
            }
        }
        grid.updateItems(entries(72), animatingDifferences: false)
        await Task.yield()
        assertNewestRowIsFull(zoom)
        XCTAssertEqual(scroll.contentView.bounds.minY, zoom.maximumOrigin, accuracy: 0.5)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        let focal = 12
        let before = zoom.layout.spec.frame(index: focal, width: zoom.layout.viewportSize.width, metrics: zoom.layout.metrics)
            .minY - scroll.contentView.bounds.minY
        grid.updateItems(entries(76), animatingDifferences: false)
        await Task.yield()
        let after = zoom.layout.spec.frame(index: focal, width: zoom.layout.viewportSize.width, metrics: zoom.layout.metrics)
            .minY - scroll.contentView.bounds.minY
        XCTAssertEqual(after, before, accuracy: 0.5, "Reading older media must not jump to the newest additions")
        XCTAssertLessThan(scroll.contentView.bounds.minY, zoom.maximumOrigin - 1)
        assertNewestRowIsFull(zoom)
    }

    func testDataLoadedBeforeThePageJoinsAWindowOpensAtNewestAfterAutoLayout() async {
        _ = NSApplication.shared
        let grid = ThumbnailGridController(sectionInset: ThumbnailCollectionStyle.sectionInset(additionalBottomInset: 164))
        let scroll = NSScrollView()
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        grid.updateItems((0..<71).map {
            ThumbnailGridItem(id: "deferred-\($0)", url: URL(fileURLWithPath: "/tmp/hermes-deferred-\($0).png"),
                              status: .finished, mediaKind: .photo, contentVersion: 1)
        })
        grid.updateSectionInset(ThumbnailCollectionStyle.sectionInset(additionalBottomInset: 164))
        await Task.yield()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 660),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        scroll.layoutSubtreeIfNeeded()
        grid.nsCollectionView.layoutSubtreeIfNeeded()
        await Task.yield()
        XCTAssertEqual(scroll.contentView.documentVisibleRect.minY, grid.zoom.maximumOrigin, accuracy: 0.5)
        assertNewestRowIsFull(grid.zoom)
    }

    func testInputReservationFollowsBottomButPreservesOtherScrollPositions() {
        let (grid, scroll, window) = fixture()
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        grid.updateSectionInset(ThumbnailCollectionStyle.sectionInset(additionalBottomInset: 164))
        scroll.contentView.scroll(to: CGPoint(x: 0, y: zoom.maximumOrigin))
        scroll.reflectScrolledClipView(scroll.contentView)
        let previousOrigin = scroll.contentView.bounds.minY
        grid.updateSectionInset(ThumbnailCollectionStyle.sectionInset(additionalBottomInset: 249))
        XCTAssertEqual(scroll.contentView.bounds.minY, previousOrigin + 85, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, zoom.maximumOrigin, accuracy: 0.5)
        grid.updateSectionInset(ThumbnailCollectionStyle.sectionInset(additionalBottomInset: 164))
        XCTAssertEqual(scroll.contentView.bounds.minY, previousOrigin, accuracy: 0.5)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 400))
        scroll.reflectScrolledClipView(scroll.contentView)
        grid.updateSectionInset(ThumbnailCollectionStyle.sectionInset(additionalBottomInset: 249))
        XCTAssertEqual(scroll.contentView.bounds.minY, 400, accuracy: 0.5)
    }

    func testEndpointResistanceAndImmediateReversalRemainInteractive() {
        var small = ZoomGesture(position: 0, width: 1000)
        for _ in 0..<1000 { small.update(magnification: -0.2, width: 1000) }
        XCTAssertGreaterThan(small.elasticScale, 0.8)
        XCTAssertLessThan(small.elasticScale, 0.81)
        let compressed = small.elasticScale
        small.update(magnification: 0.2, width: 1000)
        XCTAssertGreaterThan(small.elasticScale, compressed)
        var large = ZoomGesture(position: 3, width: 1000)
        for _ in 0..<1000 { large.update(magnification: 0.2, width: 1000) }
        let extended = large.elasticScale
        large.update(magnification: 0.2, width: 1000)
        XCTAssertGreaterThan(large.elasticScale, extended)
        large.update(magnification: -0.3, width: 1000)
        XCTAssertLessThan(large.elasticScale, extended)
    }
}
