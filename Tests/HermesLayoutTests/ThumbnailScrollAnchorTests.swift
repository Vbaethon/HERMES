import AppKit
import XCTest
@testable import HermesThumbnailUI

private final class ScrollAnchorItem: NSCollectionViewItem {
    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: ThumbnailCollectionStyle.itemSize))
    }
}

@MainActor
private final class ScrollAnchorDataSource: NSObject, NSCollectionViewDataSource {
    let count: Int
    init(count: Int) { self.count = count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("anchor-fixture"), for: indexPath)
    }
}

@MainActor
private final class ScrollAnchorFixture {
    let collection = NSCollectionView()
    let scroll: NSScrollView
    let window: NSWindow
    let dataSource: ScrollAnchorDataSource

    init(width: CGFloat = 1000, height: CGFloat = 480, count: Int = 300,
         layout: NSCollectionViewFlowLayout = ThumbnailCollectionStyle.makeLayout()) {
        _ = NSApplication.shared
        scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        dataSource = ScrollAnchorDataSource(count: count)
        layout.itemSize = ThumbnailCollectionStyle.itemSize
        layout.minimumInteritemSpacing = ThumbnailCollectionStyle.itemSpacing
        layout.minimumLineSpacing = ThumbnailCollectionStyle.itemSpacing
        layout.sectionInset = ThumbnailCollectionStyle.sectionInset
        collection.collectionViewLayout = layout
        collection.register(ScrollAnchorItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("anchor-fixture"))
        collection.dataSource = dataSource
        ThumbnailCollectionStyle.prepare(scroll, documentView: collection)
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        window.contentView = scroll
        collection.reloadData()
        settle()
    }

    func settle() {
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        collection.layoutSubtreeIfNeeded()
    }

    func resize(_ width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: scroll.frame.height))
        settle()
    }

    func scroll(to y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        collection.layoutSubtreeIfNeeded()
    }

    func topAnchor() throws -> (path: IndexPath, offset: CGFloat) {
        let layout = try XCTUnwrap(collection.collectionViewLayout)
        let attributes = collection.indexPathsForVisibleItems().compactMap {
            layout.layoutAttributesForItem(at: $0)
        }.sorted {
            $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }
        let first = try XCTUnwrap(attributes.first)
        return (try XCTUnwrap(first.indexPath), first.frame.minY - scroll.contentView.bounds.minY)
    }

    func offset(of path: IndexPath) throws -> CGFloat {
        let attributes = try XCTUnwrap(collection.collectionViewLayout?.layoutAttributesForItem(at: path))
        return attributes.frame.minY - scroll.contentView.bounds.minY
    }
}

private final class OffsetProbeLayout: NSCollectionViewFlowLayout {
    var adjustment: CGFloat = 0
    var adjustedWidths: [CGFloat] = []
    var previousViewportWidth: CGFloat?

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        return true
    }

    override func invalidationContext(forBoundsChange newBounds: NSRect) -> NSCollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if let previousViewportWidth, previousViewportWidth != newBounds.width, adjustment != 0 {
            context.contentOffsetAdjustment.y = adjustment
            adjustedWidths.append(newBounds.width)
        }
        previousViewportWidth = newBounds.width
        return context
    }

}

private final class CountingAnchorLayout: ThumbnailFlowLayout {
    var prepareCount = 0
    override func prepare() {
        prepareCount += 1
        super.prepare()
    }
}

// The old predicate compared document size with the viewport AppKit provides.
// Keep it here as an independent baseline for a real native scrolling sequence.
private final class LegacyViewportComparisonLayout: NSCollectionViewFlowLayout {
    var prepareCount = 0
    override func prepare() {
        prepareCount += 1
        super.prepare()
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        guard let collectionView else { return true }
        return collectionView.bounds.size != newBounds.size
    }
}

@MainActor
final class ThumbnailScrollAnchorTests: XCTestCase {
    func testNativeBoundsInvalidationAppliesContentOffsetAdjustment() throws {
        let layout = OffsetProbeLayout()
        let fixture = ScrollAnchorFixture(layout: layout)
        fixture.scroll(to: 1000)
        let initial = fixture.scroll.contentView.bounds.origin.y
        layout.previousViewportWidth = fixture.scroll.contentView.bounds.width
        layout.adjustment = 100
        fixture.resize(850)
        XCTAssertFalse(layout.adjustedWidths.isEmpty, "A real native width resize must call the invalidation hook")
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, initial + 100, accuracy: 0.5,
                       "AppKit must apply the public context adjustment to the enclosing clip view")
        withExtendedLifetime(fixture) {}
    }

    func testActualNativeScrollingDoesNotPrepareTheWholeFixedGrid() {
        let legacy = LegacyViewportComparisonLayout()
        let baseline = ScrollAnchorFixture(layout: legacy)
        let beforeLegacy = legacy.prepareCount
        for step in 1...40 { baseline.scroll(to: CGFloat(step * 25)) }
        let legacyPreparations = legacy.prepareCount - beforeLegacy

        let layout = CountingAnchorLayout()
        let fixture = ScrollAnchorFixture(layout: layout)
        let before = layout.prepareCount
        let initiallyVisible = Set(fixture.collection.indexPathsForVisibleItems())
        for step in 1...40 { fixture.scroll(to: CGFloat(step * 25)) }
        let preparations = layout.prepareCount - before
        print("Native scroll layout preparations: legacy=\(legacyPreparations), fixed=\(preparations), steps=40")
        XCTAssertGreaterThanOrEqual(legacyPreparations, 40, "The baseline must expose the real viewport/document mismatch")
        XCTAssertEqual(preparations, 0, "Scrolling fixed-size rows must recycle cells without a global layout pass")
        XCTAssertTrue(initiallyVisible.isDisjoint(with: Set(fixture.collection.indexPathsForVisibleItems())))
    }

    func testPinnedSupplementaryViewsRetainNativeInvalidation() {
        let fixture = ScrollAnchorFixture()
        let layout = fixture.collection.collectionViewLayout as! NSCollectionViewFlowLayout
        let nativeFixture = ScrollAnchorFixture(layout: NSCollectionViewFlowLayout())
        let nativeLayout = nativeFixture.collection.collectionViewLayout as! NSCollectionViewFlowLayout
        let proposed = fixture.scroll.contentView.bounds.offsetBy(dx: 0, dy: 250)
        XCTAssertFalse(layout.shouldInvalidateLayout(forBoundsChange: proposed))
        layout.sectionHeadersPinToVisibleBounds = true
        nativeLayout.sectionHeadersPinToVisibleBounds = true
        XCTAssertEqual(layout.shouldInvalidateLayout(forBoundsChange: proposed),
                       nativeLayout.shouldInvalidateLayout(forBoundsChange: proposed))
        layout.sectionHeadersPinToVisibleBounds = false
        nativeLayout.sectionHeadersPinToVisibleBounds = false
        layout.sectionFootersPinToVisibleBounds = true
        nativeLayout.sectionFootersPinToVisibleBounds = true
        XCTAssertEqual(layout.shouldInvalidateLayout(forBoundsChange: proposed),
                       nativeLayout.shouldInvalidateLayout(forBoundsChange: proposed))
    }

    func testContinuousWidthChangesPreserveOneVisibleItemAcrossColumnThresholds() throws {
        let fixture = ScrollAnchorFixture()
        fixture.scroll(to: 1000)
        let anchor = try fixture.topAnchor()
        for width in stride(from: 990, through: 690, by: -10) {
            fixture.resize(CGFloat(width))
            XCTAssertEqual(try fixture.offset(of: anchor.path), anchor.offset, accuracy: 0.5, "width=\(width)")
        }
        for width in stride(from: 700, through: 1000, by: 10) {
            fixture.resize(CGFloat(width))
            XCTAssertEqual(try fixture.offset(of: anchor.path), anchor.offset, accuracy: 0.5, "width=\(width)")
        }
    }

    func testPaneWidthRoundTripsDoNotAccumulateScrollDrift() throws {
        let fixture = ScrollAnchorFixture()
        fixture.scroll(to: 1173)
        let anchor = try fixture.topAnchor()
        let initialOrigin = fixture.scroll.contentView.bounds.origin.y
        for _ in 0..<4 {
            for width in [850, 700, 850, 1000] {
                fixture.resize(CGFloat(width))
                XCTAssertEqual(try fixture.offset(of: anchor.path), anchor.offset, accuracy: 0.5)
            }
            XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, initialOrigin, accuracy: 0.5)
        }
    }

    func testFractionalWidthsAtExactColumnThresholdsKeepTheAnchor() throws {
        let fixture = ScrollAnchorFixture()
        fixture.scroll(to: 1000)
        let anchor = try fixture.topAnchor()
        for width in [910.0, 908, 907.5, 907, 910, 742, 740, 739.5, 739, 742, 1000] {
            fixture.resize(CGFloat(width))
            XCTAssertEqual(try fixture.offset(of: anchor.path), anchor.offset, accuracy: 0.5, "width=\(width)")
        }
    }

    func testNativeInspectorAnimationPreservesTheScrollAnchor() async throws {
        let fixture = ScrollAnchorFixture()
        let split = NSSplitViewController()
        let sidebarController = NSViewController()
        sidebarController.view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 480))
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.minimumThickness = 250
        sidebar.maximumThickness = 250
        let contentController = NSViewController()
        contentController.view = fixture.scroll
        let content = NSSplitViewItem(viewController: contentController)
        content.minimumThickness = 520
        let inspectorController = NSViewController()
        inspectorController.view = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 480))
        let inspector = NSSplitViewItem(inspectorWithViewController: inspectorController)
        inspector.minimumThickness = 270
        inspector.maximumThickness = 270
        inspector.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        inspector.isCollapsed = true
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(content)
        split.addSplitViewItem(inspector)
        fixture.window.contentViewController = split
        fixture.window.setContentSize(NSSize(width: 1250, height: 480))
        split.view.layoutSubtreeIfNeeded()
        fixture.settle()
        fixture.scroll(to: 1000)
        let anchor = try fixture.topAnchor()
        let initialOrigin = fixture.scroll.contentView.bounds.origin.y
        let initialWidth = fixture.scroll.frame.width
        for _ in 0..<4 {
            split.toggleInspector(nil)
            try await Task.sleep(for: .milliseconds(350))
            split.view.layoutSubtreeIfNeeded()
            fixture.settle()
            XCTAssertEqual(try fixture.offset(of: anchor.path), anchor.offset, accuracy: 0.5)
            if inspector.isCollapsed {
                XCTAssertEqual(fixture.scroll.frame.width, initialWidth, accuracy: 0.5)
            } else {
                XCTAssertLessThan(fixture.scroll.frame.width, initialWidth - 200,
                                  "The native toggle must actually narrow the content across column thresholds")
            }
        }
        XCTAssertTrue(inspector.isCollapsed)
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, initialOrigin, accuracy: 0.5)
    }

    func testAUserScrollStartsANewResizeAnchor() throws {
        let fixture = ScrollAnchorFixture()
        fixture.scroll(to: 1000)
        fixture.resize(850)
        fixture.scroll(to: fixture.scroll.contentView.bounds.origin.y + 336)
        let anchor = try fixture.topAnchor()
        for width in [700, 850, 1000] {
            fixture.resize(CGFloat(width))
            XCTAssertEqual(try fixture.offset(of: anchor.path), anchor.offset, accuracy: 0.5)
        }
    }

    func testWideningNearBottomClampsAndReturningRestoresTheAnchor() throws {
        let fixture = ScrollAnchorFixture(width: 700, count: 120)
        fixture.scroll(to: fixture.collection.bounds.height - fixture.scroll.contentView.bounds.height)
        let anchor = try fixture.topAnchor()
        let initialOrigin = fixture.scroll.contentView.bounds.origin.y
        fixture.resize(1000)
        let maxY = max(0, fixture.collection.bounds.height - fixture.scroll.contentView.bounds.height)
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, maxY, accuracy: 0.5,
                       "An impossible anchor offset must clamp at the native document boundary")
        XCTAssertGreaterThanOrEqual(try fixture.offset(of: anchor.path), anchor.offset)
        XCTAssertLessThan(try fixture.offset(of: anchor.path), fixture.scroll.contentView.bounds.height)
        fixture.resize(700)
        XCTAssertEqual(try fixture.offset(of: anchor.path), anchor.offset, accuracy: 0.5)
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, initialOrigin, accuracy: 0.5)
    }

    func testAnEntirelyVisibleWideGridRetainsItsPreviousResizeAnchor() throws {
        let fixture = ScrollAnchorFixture(width: 700, count: 12)
        fixture.scroll(to: fixture.collection.bounds.height - fixture.scroll.contentView.bounds.height)
        let anchor = try fixture.topAnchor()
        let initialOrigin = fixture.scroll.contentView.bounds.origin.y
        fixture.resize(1200)
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        fixture.resize(700)
        XCTAssertEqual(try fixture.offset(of: anchor.path), anchor.offset, accuracy: 0.5)
        XCTAssertEqual(fixture.scroll.contentView.bounds.origin.y, initialOrigin, accuracy: 0.5)
    }
}
