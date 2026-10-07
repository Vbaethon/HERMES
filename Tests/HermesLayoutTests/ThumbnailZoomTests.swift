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

    private func pinch(_ zoom: ThumbnailGridZoomController, to position: CGFloat) {
        let width = zoom.layout.viewportSize.width, metrics = zoom.layout.metrics
        let before = ZoomGeometry.side(width: width, position: zoom.position, metrics: metrics)
        let after = ZoomGeometry.side(width: width, position: position, metrics: metrics)
        zoom.changeGesture(magnification: 2 * (after - before) / zoom.gesture!.startSide)
        zoom.displayFrame(at: CACurrentMediaTime())
    }

    func testAllAdjacentDirectionsBlendDepartingNeighboursAndKeepAlignedPhotosContinuous() async throws {
        let (grid, scroll, window) = fixture()
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        for (from, to) in [(0, 1), (1, 0), (1, 2), (2, 1), (2, 3), (3, 2)] {
            zoom.zoom(to: from)
            zoom.displayFrame(at: CACurrentMediaTime() + 10)
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
                pinch(zoom, to: target)
                XCTAssertEqual(zoom.position, target, accuracy: 0.0001)
                XCTAssertTrue(zoom.overlay.superview === scroll.contentView,
                              "Reusable collection cells must not own the presentation's stacking order")
                XCTAssertTrue(scroll.documentView === grid.nsCollectionView)
                XCTAssertEqual(grid.nsCollectionView.alphaValue, 1,
                               "Never remove the document from the native background effect during zoom")
                XCTAssertEqual(zoom.overlay.frame, scroll.contentView.bounds)
                XCTAssertTrue(grid.nsCollectionView.visibleItems().allSatisfy { $0.view.alphaValue == 0 },
                              "The old native grid must never draw underneath the prepared zoom grids")
                for index in start..<(start + columns) {
                    let source = zoom.overlay.states[from].cellFrame(index: index, width: width, metrics: metrics)
                    let destination = zoom.overlay.states[to].cellFrame(index: index, width: width, metrics: metrics)
                    let aligned = abs(source.midX - destination.midX) + abs(source.midY - destination.midY) < 0.01
                    if aligned {
                        XCTAssertEqual(zoom.overlay.focalOpacity(at: index), 1,
                                       "Only photos with matching frames in both grids remain continuous")
                    } else {
                        XCTAssertNil(zoom.overlay.focalOpacity(at: index),
                                     "Departing neighbours must blend with their grid, including the pointer row")
                    }
                }
                XCTAssertEqual(zoom.overlay.layer?.sublayers?.count, 4,
                               "No additional opaque focal row may override the common blend")
                XCTAssertLessThan(zoom.overlay.retainedTileCount, 300, "Presentation work must depend on the viewport, not library size")
            }
            pinch(zoom, to: CGFloat(to))
            zoom.endGesture()
            zoom.displayFrame(at: CACurrentMediaTime() + 10)
            let expected = layout.spec.frame(index: focal, width: width, metrics: metrics)
                .offsetBy(dx: 0, dy: -scroll.contentView.bounds.minY)
            let displayed = try XCTUnwrap(zoom.overlay.focalFrames[focal])
            XCTAssertEqual(displayed.midX, expected.midX, accuracy: 0.01)
            XCTAssertEqual(displayed.midY, expected.midY, accuracy: 0.01)
            XCTAssertEqual(displayed.size.width, expected.size.width, accuracy: 0.01)
            XCTAssertEqual(zoom.overlay.frame, scroll.contentView.bounds,
                           "The held presentation must stay in the viewport after native scrolling")
            await Task.yield()
        }
    }

    func testRealNativeFramesPreserveFocalRegionThroughHandoffWithToolbarInsets() async throws {
        let (grid, scroll, window) = fixture(count: 70)
        defer { window.orderOut(nil) }
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = NSToolbar(identifier: "ZoomFocusRegressionToolbar")
        let zoom = grid.zoom!
        for width in [720.0, 1000.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            scroll.layoutSubtreeIfNeeded()
            zoom.viewportChanged()
            for (from, to) in [(0, 1), (1, 2), (2, 3), (3, 2), (2, 1), (1, 0)] {
                zoom.zoom(to: from)
                zoom.displayFrame(at: CACurrentMediaTime() + 10)
                try await Task.sleep(for: .milliseconds(15))
                let index = 42
                let source = zoom.layout.spec.frame(index: index, width: zoom.layout.viewportSize.width,
                                                    metrics: zoom.layout.metrics)
                let point = CGPoint(x: source.minX + source.width * 0.32, y: source.minY + source.height * 0.61)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: point.y - 240))
                scroll.reflectScrolledClipView(scroll.contentView)
                zoom.beginGesture(at: point)
                let plan = try XCTUnwrap(zoom.plan)
                XCTAssertEqual(plan.anchor.index, index)
                pinch(zoom, to: CGFloat(to))
                let displayed = try XCTUnwrap(zoom.overlay.focalFrames[index])
                let content = try XCTUnwrap(window.contentView)
                let before = content.convert(displayed, from: zoom.overlay)
                zoom.endGesture()
                zoom.displayFrame(at: CACurrentMediaTime() + 10)
                try await Task.sleep(for: .milliseconds(30))
                let cell = try XCTUnwrap(grid.nsCollectionView.item(at: IndexPath(item: index, section: 0)))
                let actual = content.convert(cell.view.bounds, from: cell.view)
                XCTAssertEqual(actual.minY, before.minY, accuracy: 0.6)
                XCTAssertEqual(actual.midX, before.midX, accuracy: 0.6)
                XCTAssertTrue(zoom.overlay.isHidden)
                XCTAssertFalse(zoom.cellsSuppressed)
                XCTAssertTrue(grid.nsCollectionView.visibleItems().allSatisfy { $0.view.alphaValue == 1 })
            }
        }
    }

    func testWindowResizeAndBottomScrollingPreserveTheFocusedRowStart() async {
        let (grid, scroll, window) = fixture()
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        for level in 0..<4 {
            zoom.zoom(to: level)
            zoom.displayFrame(at: CACurrentMediaTime() + 10)
            await Task.yield()
            let prepared = zoom.layout.spec
            scroll.contentView.scroll(to: CGPoint(x: 0, y: zoom.maximumOrigin))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertEqual(zoom.layout.spec, prepared, "Scrolling to the tail must not reorder the focused grid")
            for width in [700.0, 1100.0, 850.0] {
                window.setContentSize(NSSize(width: width, height: 600))
                scroll.layoutSubtreeIfNeeded()
                zoom.viewportChanged()
                XCTAssertEqual(zoom.layout.spec, prepared, "Native window and sidebar sizing must preserve the row start")
                XCTAssertEqual(scroll.contentView.bounds.minY, zoom.maximumOrigin, accuracy: 0.5)
            }
        }
    }

    func testReleasedStableZoomBeginsBadgeRevealWithoutAnExtraSettlementWait() {
        let (grid, _, window) = fixture(count: 70)
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        let frame = zoom.layout.spec.frame(index: 68, width: zoom.layout.viewportSize.width,
                                          metrics: zoom.layout.metrics)
        zoom.beginGesture(at: CGPoint(x: frame.midX, y: frame.midY))
        zoom.endGesture()
        XCTAssertFalse(zoom.badgesSuppressed,
                       "A released, already stable layout must start revealing metadata while the existing handoff completes")
        XCTAssertNotNil(zoom.plan, "The accepted image handoff remains independent of metadata visibility")
    }

    func testRequestingTheCurrentPresetDoesNotBlinkBadges() {
        let (grid, _, window) = fixture(count: 70)
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        zoom.zoom(to: zoom.layout.spec.level)
        XCTAssertFalse(zoom.badgesSuppressed, "An unchanged keyboard preset does not hide decorations")
        for case let cell as ThumbnailCollectionItem in grid.nsCollectionView.visibleItems() {
            XCTAssertGreaterThan((cell.view as? ThumbnailItemView)?.badgeLabel?.alphaValue ?? 0, 0.99)
        }
    }

    func testBadgesUseOneFadeThroughSettlementHandoffAndReentry() async throws {
        let (grid, _, window) = fixture(count: 70)
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        let index = 68
        let frame = zoom.layout.spec.frame(index: index, width: zoom.layout.viewportSize.width,
                                          metrics: zoom.layout.metrics)
        zoom.beginGesture(at: CGPoint(x: frame.midX, y: frame.midY))
        XCTAssertTrue(zoom.badgesSuppressed)
        zoom.displayFrame(at: CACurrentMediaTime() + 1)
        for case let cell as ThumbnailCollectionItem in grid.nsCollectionView.visibleItems() {
            XCTAssertEqual((cell.view as? ThumbnailItemView)?.badgeLabel?.alphaValue, 0)
        }
        zoom.changeGesture(magnification: 0.2)
        zoom.endGesture()
        XCTAssertTrue(zoom.badgesSuppressed, "A released finger does not reveal badges while layout is still settling")
        zoom.displayFrame(at: CACurrentMediaTime() + 10)
        XCTAssertFalse(zoom.badgesSuppressed, "A stable layout starts its common reveal before native handoff")
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(zoom.overlay.isHidden)
        XCTAssertFalse(zoom.badgesSuppressed)
        for case let cell as ThumbnailCollectionItem in grid.nsCollectionView.visibleItems() {
            XCTAssertEqual((cell.view as? ThumbnailItemView)?.badgeLabel?.alphaValue, 1)
        }

        let currentFrame = zoom.layout.spec.frame(index: index, width: zoom.layout.viewportSize.width,
                                                 metrics: zoom.layout.metrics)
        zoom.beginGesture(at: CGPoint(x: currentFrame.midX, y: currentFrame.midY))
        XCTAssertTrue(zoom.badgesSuppressed, "A new gesture cancels the previous native reveal")
        let reused = ThumbnailCollectionItem()
        zoom.prepareBadgeAppearance(for: reused)
        (reused.view as? ThumbnailItemView)?.setBadge("JPG")
        XCTAssertEqual((reused.view as? ThumbnailItemView)?.badgeLabel?.alphaValue, zoom.badgeOpacity,
                       "A new cell inherits the current fade phase, rather than jumping directly to its target")
        zoom.finishForInteraction()
    }

    func testBadgeClockContinuesAfterImageHandoffAndNewCellsInheritTheRevealPhase() async throws {
        let (grid, _, window) = fixture(count: 70)
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        let frame = zoom.layout.spec.frame(index: 68, width: zoom.layout.viewportSize.width,
                                          metrics: zoom.layout.metrics)
        zoom.beginGesture(at: CGPoint(x: frame.midX, y: frame.midY))
        zoom.displayFrame(at: CACurrentMediaTime() + 1)
        XCTAssertEqual(zoom.badgeOpacity, 0)
        zoom.finishForInteraction()
        XCTAssertNil(zoom.plan)
        XCTAssertFalse(zoom.badgesSuppressed)
        await Task.yield()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(zoom.overlay.isHidden)
        XCTAssertGreaterThan(zoom.badgeOpacity, 0)
        XCTAssertLessThan(zoom.badgeOpacity, 1)
        let reused = ThumbnailCollectionItem()
        zoom.prepareBadgeAppearance(for: reused)
        (reused.view as? ThumbnailItemView)?.setBadge("JPG")
        XCTAssertEqual((reused.view as? ThumbnailItemView)?.badgeLabel?.alphaValue, zoom.badgeOpacity)
        for case let cell as ThumbnailCollectionItem in grid.nsCollectionView.visibleItems() {
            let badge = try XCTUnwrap((cell.view as? ThumbnailItemView)?.badgeLabel)
            XCTAssertEqual(badge.alphaValue, zoom.badgeOpacity, accuracy: 0.0001)
            XCTAssertTrue(badge.layer?.animationKeys()?.isEmpty ?? true)
        }
        for viewport in try XCTUnwrap(zoom.overlay.layer?.sublayers) {
            let decorations = try XCTUnwrap(viewport.sublayers?.first?.sublayers?.last)
            XCTAssertEqual(CGFloat(decorations.opacity), zoom.badgeOpacity, accuracy: 0.0001)
        }
        let frames = zoom.overlay.focalFrames
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(zoom.badgeOpacity, 1)
        XCTAssertEqual(zoom.overlay.focalFrames, frames, "Badge-only frames must not rerender image geometry")
        XCTAssertNil(zoom.plan)
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
        pinch(zoom, to: 0)
        zoom.endGesture()
        zoom.displayFrame(at: CACurrentMediaTime() + 10)
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
        if layout.count < columns {
            XCTAssertEqual(first.minX, metrics.left, accuracy: 0.001, file: file, line: line)
            XCTAssertTrue(row.allSatisfy { abs($0.minY - last.minY) < 0.001 }, file: file, line: line)
            return
        }
        XCTAssertEqual(last.maxX, width - metrics.right, accuracy: 0.001, file: file, line: line)
        if layout.count >= columns { XCTAssertEqual(first.minX, metrics.left, accuracy: 0.001, file: file, line: line) }
        XCTAssertTrue(row.allSatisfy { abs($0.minY - last.minY) < 0.001 }, file: file, line: line)
        XCTAssertEqual(row.count, min(layout.count, columns), file: file, line: line)
    }

    func testStartupOpensAtNewestButAllSixZoomDirectionsPreserveTheFocusedPlan() async throws {
        for count in [2, 68, 70, 71] {
            let (grid, scroll, window) = fixture(count: count, animatingDifferences: true)
            let zoom = grid.zoom!
            await Task.yield()
            XCTAssertEqual(scroll.contentView.bounds.minY, zoom.maximumOrigin, accuracy: 0.5)
            assertNewestRowIsFull(zoom)
            for (from, to) in [(0, 1), (1, 0), (1, 2), (2, 1), (2, 3), (3, 2)] {
                zoom.zoom(to: from)
                zoom.displayFrame(at: CACurrentMediaTime() + 10)
                await Task.yield()
                // Each direction starts at the native bottom. A previous zoom
                // may legitimately keep an older cursor focus above the tail.
                scroll.contentView.scroll(to: CGPoint(x: 0, y: zoom.maximumOrigin))
                scroll.reflectScrolledClipView(scroll.contentView)
                zoom.viewportChanged()
                XCTAssertEqual(scroll.contentView.bounds.minY, zoom.maximumOrigin, accuracy: 0.5)
                let layout = zoom.layout, metrics = layout.metrics, width = layout.viewportSize.width
                let focal = count - 1
                let frame = layout.spec.frame(index: focal, width: width, metrics: metrics)
                zoom.beginGesture(at: CGPoint(x: frame.midX, y: frame.midY))
                let plan = try XCTUnwrap(zoom.plan)
                pinch(zoom, to: CGFloat(to))
                XCTAssertEqual(zoom.overlay.focalOpacity(at: focal), 1)
                zoom.endGesture()
                zoom.displayFrame(at: CACurrentMediaTime() + 10)
                XCTAssertEqual(layout.spec, plan.specs[to], "The nearest focal slot survives native handoff at the tail")
                let nativeFrame = layout.spec.frame(index: focal, width: width, metrics: metrics)
                let desiredOrigin = nativeFrame.minY + nativeFrame.height * plan.anchor.unitPoint.y - plan.anchor.viewportPoint.y
                XCTAssertEqual(scroll.contentView.bounds.minY, min(zoom.maximumOrigin, max(0, desiredOrigin)), accuracy: 0.5,
                               "Zoom preserves the cursor point whenever native scroll boundaries permit it")
                let expected = nativeFrame.offsetBy(dx: 0, dy: -scroll.contentView.bounds.minY)
                let displayed = try XCTUnwrap(zoom.overlay.focalFrames[focal])
                XCTAssertEqual(displayed.midX, expected.midX, accuracy: 0.01)
                XCTAssertEqual(displayed.midY, expected.midY, accuracy: 0.01)
                await Task.yield()
                zoom.viewportChanged()
                XCTAssertEqual(layout.spec, plan.specs[to], "A later bounds notification must not force a full final row")
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
        XCTAssertGreaterThan(small.elasticScale, ZoomGesture.minimumElasticScale)
        XCTAssertLessThan(small.elasticScale, 0.95)
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

    func testNativeMagnificationDeltasProduceLinearSizeAndIgnoreEventPartitioning() {
        let width: CGFloat = 1000
        var single = ZoomGesture(position: 0, width: width)
        var split = ZoomGesture(position: 0, width: width)
        single.update(magnification: 1, width: width)
        for _ in 0..<20 { split.update(magnification: 0.05, width: width) }
        let expected = single.startSide * 1.5
        XCTAssertEqual(ZoomGeometry.side(width: width, position: single.position), expected, accuracy: 0.0001)
        XCTAssertEqual(ZoomGeometry.side(width: width, position: split.position), expected, accuracy: 0.0001)
        split.update(magnification: -0.4, width: width)
        XCTAssertEqual(ZoomGeometry.side(width: width, position: split.position), split.startSide * 1.3, accuracy: 0.0001)
        split.update(magnification: -0.6, width: width)
        XCTAssertEqual(split.position, 0, accuracy: 0.0001)
        XCTAssertEqual(split.elasticScale, 1, accuracy: 0.0001)
    }

    func testNativeDisplayLinkCoalescesBurstInputAndCompletesTheHandoff() async throws {
        let (grid, _, window) = fixture(count: 71)
        defer { window.orderOut(nil) }
        let zoom = grid.zoom!
        let focal = 63
        let initial = zoom.layout.spec.frame(index: focal, width: zoom.layout.viewportSize.width,
                                             metrics: zoom.layout.metrics)
        zoom.beginGesture(at: CGPoint(x: initial.midX, y: initial.midY))
        let first = try XCTUnwrap(zoom.overlay.focalFrames[focal])
        for _ in 0..<10 { zoom.changeGesture(magnification: 0.04) }
        XCTAssertEqual(zoom.overlay.focalFrames[focal], first,
                       "A burst of input must update state without rebuilding ten layer trees in one frame")
        try await Task.sleep(for: .milliseconds(80))
        let shown = try XCTUnwrap(zoom.overlay.focalFrames[focal])
        XCTAssertEqual(shown.width, initial.width * 1.2, accuracy: 0.001,
                       "The native refresh clock must present the most recent input without a synthetic tick")
        zoom.endGesture()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(zoom.plan)
        XCTAssertTrue(zoom.overlay.isHidden)
        XCTAssertFalse(zoom.cellsSuppressed)
        XCTAssertFalse(zoom.badgesSuppressed)
    }
}
