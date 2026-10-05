import AppKit
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailSelectionTests: XCTestCase {
    func testHitTestingUsesTheVisibleImageForPortraitLandscapeAndSquareThumbnails() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.orderOut(nil) }

        for (index, size) in [NSSize(width: 80, height: 160),
                              NSSize(width: 160, height: 80),
                              NSSize(width: 160, height: 160)].enumerated() {
            let path = IndexPath(item: index, section: 0)
            let view = try setImage(size: size, at: path, in: fixture.grid.nsCollectionView)
            let imageFrame = try XCTUnwrap(view.imageView?.frame)
            let center = view.convert(NSPoint(x: imageFrame.midX, y: imageFrame.midY),
                                      to: fixture.grid.nsCollectionView)
            XCTAssertEqual(fixture.grid.nsCollectionView.indexPathForItem(at: center), path)

            if size.width < size.height {
                let blank = view.convert(NSPoint(x: imageFrame.minX / 2, y: imageFrame.midY),
                                         to: fixture.grid.nsCollectionView)
                XCTAssertNil(fixture.grid.nsCollectionView.indexPathForItem(at: blank),
                             "Portrait thumbnail side padding must not count as the image")
            } else if size.width > size.height {
                let blank = view.convert(NSPoint(x: imageFrame.midX, y: imageFrame.minY / 2),
                                         to: fixture.grid.nsCollectionView)
                XCTAssertNil(fixture.grid.nsCollectionView.indexPathForItem(at: blank),
                             "Landscape thumbnail vertical padding must not count as the image")
            }
        }

        let betweenItems = NSPoint(x: 0, y: 0)
        XCTAssertNil(fixture.grid.nsCollectionView.indexPathForItem(at: betweenItems))
    }

    func testContextMenuOnPaddingDoesNotSelectAndArtworkKeepsMultipleSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.orderOut(nil) }
        let collection = fixture.grid.nsCollectionView
        let path = IndexPath(item: 0, section: 0)
        let view = try setImage(size: NSSize(width: 80, height: 160), at: path, in: collection)
        let frame = try XCTUnwrap(view.imageView?.frame)
        let menu = NSMenu(title: "Thumbnail actions")
        menu.addItem(withTitle: "Inspect", action: nil, keyEquivalent: "")
        fixture.grid.setContextMenuProvider { menu }

        let blank = view.convert(NSPoint(x: frame.minX / 2, y: frame.midY), to: collection)
        let artwork = view.convert(NSPoint(x: frame.midX, y: frame.midY), to: collection)
        XCTAssertNil(collection.menu(for: try mouseEvent(.rightMouseDown, at: blank, in: collection)))
        XCTAssertTrue(collection.selectionIndexPaths.isEmpty,
                      "Opening a menu in image padding must not select a thumbnail")

        XCTAssertTrue(collection.menu(for: try mouseEvent(.rightMouseDown, at: artwork, in: collection)) === menu)
        XCTAssertEqual(collection.selectionIndexPaths, [path])

        fixture.grid.applySelection(["item-0", "item-1"])
        XCTAssertTrue(collection.menu(for: try mouseEvent(.rightMouseDown, at: artwork, in: collection)) === menu)
        XCTAssertEqual(collection.selectionIndexPaths,
                       [path, IndexPath(item: 1, section: 0)],
                       "Right-clicking selected artwork must preserve multiple selection")
        XCTAssertNil(collection.menu(for: try mouseEvent(.rightMouseDown, at: blank, in: collection)))
        XCTAssertEqual(collection.selectionIndexPaths, [path, IndexPath(item: 1, section: 0)])
    }

    func testMouseDownInImagePaddingClearsSelectionWithoutSelectingTheCell() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.orderOut(nil) }
        let collection = fixture.grid.nsCollectionView
        let view = try setImage(size: NSSize(width: 80, height: 160),
                                at: IndexPath(item: 0, section: 0), in: collection)
        let frame = try XCTUnwrap(view.imageView?.frame)
        let blank = view.convert(NSPoint(x: frame.minX / 2, y: frame.midY), to: collection)
        fixture.grid.applySelection(["item-1"])
        var reportedSelection: Set<String>?
        fixture.grid.setSelectionHandler { reportedSelection = $0 }

        try click(at: blank, in: collection)

        XCTAssertTrue(collection.selectionIndexPaths.isEmpty,
                      "AppKit mouse handling must not reselect the cell after clicking its padding")
        XCTAssertEqual(reportedSelection, [])
    }

    func testSharingAnchorsToArtworkRatherThanPortraitOrLandscapePadding() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.orderOut(nil) }
        let collection = fixture.grid.nsCollectionView
        for size in [NSSize(width: 80, height: 160), NSSize(width: 160, height: 80)] {
            let view = try setImage(size: size, at: IndexPath(item: 1, section: 0), in: collection)
            let imageView = try XCTUnwrap(view.imageView)
            let expected = imageView.convert(imageView.bounds, to: collection)
            let anchor = try XCTUnwrap(fixture.grid.sharingAnchorRect(forIDs: ["item-1"]))
            XCTAssertEqual(anchor, expected)
            XCTAssertNotEqual(anchor, view.convert(view.bounds, to: collection),
                              "Share must point to the file artwork, not the surrounding cell padding")
        }
        XCTAssertNil(fixture.grid.sharingAnchorRect(forIDs: []))
        XCTAssertNil(fixture.grid.sharingAnchorRect(forIDs: ["removed-item"]))
    }

    func testMultipleSharingKeepsFirstDisplayedFileWhenRightClickingALaterSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.orderOut(nil) }
        let collection = fixture.grid.nsCollectionView
        let first = try setImage(size: NSSize(width: 80, height: 160),
                                 at: IndexPath(item: 0, section: 0), in: collection)
        let last = try setImage(size: NSSize(width: 160, height: 80),
                                at: IndexPath(item: 2, section: 0), in: collection)
        fixture.grid.applySelection(["item-2"])
        fixture.grid.applySelection(["item-2", "item-0"])
        let menu = NSMenu(title: "Thumbnail actions")
        fixture.grid.setContextMenuProvider { menu }
        let lastImage = try XCTUnwrap(last.imageView)
        let point = lastImage.convert(NSPoint(x: lastImage.bounds.midX, y: lastImage.bounds.midY),
                                      to: collection)
        XCTAssertTrue(collection.menu(for: try mouseEvent(.rightMouseDown, at: point, in: collection)) === menu)
        XCTAssertEqual(collection.selectionIndexPaths,
                       [IndexPath(item: 0, section: 0), IndexPath(item: 2, section: 0)])
        let firstImage = try XCTUnwrap(first.imageView)
        XCTAssertEqual(fixture.grid.sharingAnchorRect(forIDs: ["item-2", "item-0"]),
                       firstImage.convert(firstImage.bounds, to: collection),
                       "The last clicked file must not move sharing away from the first displayed selection")
    }

    func testSharingSkipsOffscreenSelectionAndClipsAnchorToVisibleArtwork() async throws {
        let fixture = try await makeFixture(itemCount: 18)
        defer { fixture.window.orderOut(nil) }
        let collection = fixture.grid.nsCollectionView
        let path = IndexPath(item: 6, section: 0)
        collection.scrollToItems(at: [path], scrollPosition: .top)
        try await Task.sleep(for: .milliseconds(50))
        let second = try setImage(size: NSSize(width: 80, height: 160),
                                  at: path, in: collection)
        let imageView = try XCTUnwrap(second.imageView)
        let artwork = imageView.convert(imageView.bounds, to: collection)
        let scroll = try XCTUnwrap(collection.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: artwork.midY))
        scroll.reflectScrolledClipView(scroll.contentView)
        let visibleArtwork = artwork.intersection(collection.visibleRect)
        XCTAssertFalse(visibleArtwork.isEmpty)
        XCTAssertLessThan(visibleArtwork.height, artwork.height)
        XCTAssertEqual(fixture.grid.sharingAnchorRect(forIDs: ["item-0", "item-6"]), visibleArtwork)
        XCTAssertNil(fixture.grid.sharingAnchorRect(forIDs: ["item-0"]))
    }

    func testModifiedPaddingClicksMatchNativeEmptySpaceSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.orderOut(nil) }
        let collection = fixture.grid.nsCollectionView
        let view = try setImage(size: NSSize(width: 80, height: 160),
                                at: IndexPath(item: 0, section: 0), in: collection)
        let frame = try XCTUnwrap(view.imageView?.frame)
        let blank = view.convert(NSPoint(x: frame.minX / 2, y: frame.midY), to: collection)
        let native = try await makeNativeFixture()
        defer { native.window.orderOut(nil) }
        let selection: Set<IndexPath> = [IndexPath(item: 1, section: 0)]
        let nativeBlank = NSPoint(x: 0, y: 0)
        XCTAssertNil(native.collection.indexPathForItem(at: nativeBlank))

        for modifiers: NSEvent.ModifierFlags in [.command, .shift, [.command, .shift]] {
            native.collection.deselectItems(at: native.collection.selectionIndexPaths)
            native.collection.selectItems(at: selection, scrollPosition: [])
            try click(at: nativeBlank, in: native.collection, modifiers: modifiers)
            fixture.grid.applySelection(["item-1"])
            try click(at: blank, in: collection, modifiers: modifiers)
            XCTAssertEqual(collection.selectionIndexPaths, native.collection.selectionIndexPaths,
                           "Image padding must use AppKit's native empty-space behavior for \(modifiers)")
        }
        withExtendedLifetime(native.dataSource) {}
    }

    func testArtworkClicksKeepNativeSingleAndModifiedSelection() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.orderOut(nil) }
        let native = try await makeNativeFixture()
        defer { native.window.orderOut(nil) }
        let collection = fixture.grid.nsCollectionView
        let paths = (0..<3).map { IndexPath(item: $0, section: 0) }
        let centers = try paths.map { path in
            let view = try setImage(size: NSSize(width: 80, height: 160), at: path, in: collection)
            let frame = try XCTUnwrap(view.imageView?.frame)
            return view.convert(NSPoint(x: frame.midX, y: frame.midY), to: collection)
        }
        let nativeCenters = try paths.map { path in
            let view = try XCTUnwrap(native.collection.item(at: path)?.view)
            return view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: native.collection)
        }
        fixture.window.makeKeyAndOrderFront(nil)
        fixture.window.makeFirstResponder(collection)
        for (path, center) in zip(paths, centers) {
            XCTAssertEqual(collection.indexPathForItem(at: center), path)
        }
        try click(at: centers[0], in: collection)
        try click(at: nativeCenters[0], in: native.collection)
        XCTAssertEqual(collection.selectionIndexPaths, [paths[0]])
        try click(at: centers[1], in: collection, modifiers: .command)
        try click(at: nativeCenters[1], in: native.collection, modifiers: .command)
        XCTAssertEqual(collection.selectionIndexPaths, [paths[0], paths[1]])
        try click(at: centers[0], in: collection, modifiers: .command)
        try click(at: nativeCenters[0], in: native.collection, modifiers: .command)
        XCTAssertEqual(collection.selectionIndexPaths, [paths[1]],
                       "Command-click must toggle existing artwork selection")
        try click(at: centers[0], in: collection)
        try click(at: nativeCenters[0], in: native.collection)
        try click(at: centers[2], in: collection, modifiers: .shift)
        try click(at: nativeCenters[2], in: native.collection, modifiers: .shift)
        XCTAssertEqual(collection.selectionIndexPaths, native.collection.selectionIndexPaths,
                       "Shift-click must preserve AppKit's native grid selection behavior")
        collection.deselectItems(at: collection.selectionIndexPaths)
        fixture.window.makeFirstResponder(collection)
        collection.selectAll(nil)
        XCTAssertEqual(collection.selectionIndexPaths, Set(paths),
                       "Selecting all must not depend on mouse hit-testing")
        withExtendedLifetime(native.dataSource) {}
    }

    func testAnUnloadedThumbnailHasNoArtworkHitArea() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.orderOut(nil) }
        let collection = fixture.grid.nsCollectionView
        let item = try XCTUnwrap(collection.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailCollectionItem)
        item.prepareForReuse()
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: collection)
        XCTAssertNil(collection.indexPathForItem(at: center))
    }

    private func makeFixture(itemCount: Int = 3) async throws -> (grid: ThumbnailGridController, window: NSWindow) {
        _ = NSApplication.shared
        let grid = ThumbnailGridController()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        grid.updateItems((0..<itemCount).map {
            ThumbnailGridItem(id: "item-\($0)",
                              url: URL(fileURLWithPath: "/tmp/hermes-selection-fixture-\($0).png"),
                              status: .finished, mediaKind: .photo, contentVersion: 1)
        }, animatingDifferences: false)
        scroll.layoutSubtreeIfNeeded()
        grid.nsCollectionView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        // Allow missing-file thumbnail requests to finish before assigning test artwork.
        return (grid, window)
    }

    private func setImage(size: NSSize, at path: IndexPath,
                          in collection: NSCollectionView) throws -> ThumbnailItemView {
        let item = try XCTUnwrap(collection.item(at: path) as? ThumbnailCollectionItem)
        item.prepareForReuse()
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        let image = NSImage(size: size)
        item.imageView?.image = image
        item.imageView?.alphaValue = 1
        view.updateImageFrame(for: image)
        XCTAssertGreaterThan(view.bounds.width, 0)
        return view
    }

    private func makeNativeFixture() async throws -> (collection: NSCollectionView,
        window: NSWindow, dataSource: NSCollectionViewDiffableDataSource<String, String>) {
        let collection = NSCollectionView()
        ThumbnailCollectionStyle.prepare(collection)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        ThumbnailCollectionStyle.prepare(scroll, documentView: collection)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        let dataSource = NSCollectionViewDiffableDataSource<String, String>(collectionView: collection) {
            collection, path, _ in
            let item = collection.makeItem(withIdentifier: ThumbnailCollectionItem.identifier, for: path)
            if let view = item.view as? ThumbnailItemView {
                let image = NSImage(size: NSSize(width: 160, height: 160))
                item.imageView?.image = image
                view.updateImageFrame(for: image)
            }
            return item
        }
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        snapshot.appendSections(["main"])
        snapshot.appendItems(["item-0", "item-1", "item-2"])
        dataSource.apply(snapshot, animatingDifferences: false)
        scroll.layoutSubtreeIfNeeded()
        collection.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        return (collection, window, dataSource)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint,
                            in collection: NSCollectionView,
                            modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let window = try XCTUnwrap(collection.window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type,
            location: collection.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func click(at point: NSPoint, in collection: NSCollectionView,
                       modifiers: NSEvent.ModifierFlags = []) throws {
        let down = try mouseEvent(.leftMouseDown, at: point, in: collection, modifiers: modifiers)
        let up = try mouseEvent(.leftMouseUp, at: point, in: collection, modifiers: modifiers)
        collection.mouseDown(with: down)
        // Ordinary artwork selection is committed by AppKit on mouse-up.
        collection.mouseUp(with: up)
    }
}
