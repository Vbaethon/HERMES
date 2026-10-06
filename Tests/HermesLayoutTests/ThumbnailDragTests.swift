import AppKit
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailDragTests: XCTestCase {
    func testDragShadowMatchesPortraitAndLandscapeArtworkWithoutChangingTheSource() throws {
        _ = NSApplication.shared
        for size in [NSSize(width: 80, height: 160), NSSize(width: 160, height: 80)] {
            let item = ThumbnailCollectionItem()
            let view = try XCTUnwrap(item.view as? ThumbnailItemView)
            let sourceView = try XCTUnwrap(item.imageView)
            let sourceImage = try makeImage(size: size)
            sourceView.image = sourceImage
            sourceView.alphaValue = 0.75
            view.updateImageFrame(for: sourceImage)
            view.setBadge("LIVE")
            item.isSelected = true
            view.layoutSubtreeIfNeeded()
            let artworkFrame = sourceView.frame
            let sourcePixels = try XCTUnwrap(sourceImage.tiffRepresentation)

            for _ in 0..<2 {
                let components = item.draggingImageComponents
                XCTAssertEqual(components.count, 1, "One media item must produce one artwork shadow")
                let component = try XCTUnwrap(components.first)
                let shadow = try XCTUnwrap(component.contents as? NSImage)
                XCTAssertEqual(component.key, .icon)
                XCTAssertEqual(component.frame, artworkFrame,
                               "The return destination must match the artwork rather than the cell padding")
                XCTAssertEqual(shadow.size, artworkFrame.size)
                XCTAssertNotEqual(component.frame, view.bounds)
                XCTAssertFalse(shadow === sourceImage)
                XCTAssertTrue(item.imageView === sourceView)
                XCTAssertTrue(sourceView.superview === view)
                XCTAssertTrue(sourceView.image === sourceImage)
                XCTAssertEqual(sourceView.frame, artworkFrame)
                XCTAssertEqual(sourceView.alphaValue, 0.75)
                XCTAssertFalse(sourceView.isHidden, "Preparing a copy drag must leave the source visible")
                XCTAssertEqual(sourceImage.tiffRepresentation, sourcePixels)
            }
        }
    }

    func testDragShadowRetainsRoundedArtworkAfterTheSourceCellIsReused() throws {
        _ = NSApplication.shared
        let item = ThumbnailCollectionItem()
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        let sourceImage = try makeImage(size: NSSize(width: 80, height: 160))
        item.imageView?.image = sourceImage
        item.imageView?.alphaValue = 1
        view.updateImageFrame(for: sourceImage)
        let component = try XCTUnwrap(item.draggingImageComponents.first)
        let shadow = try XCTUnwrap(component.contents as? NSImage)
        let size = shadow.size

        item.prepareForReuse()
        XCTAssertNil(item.imageView?.image)
        let rendered = try render(shadow)
        XCTAssertEqual(shadow.size, size)
        let center = try XCTUnwrap(rendered.colorAt(x: rendered.pixelsWide / 2,
                                                   y: rendered.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(center.redComponent, 0.9, accuracy: 0.03,
                       "The shadow must retain the actual thumbnail pixels independently of cell reuse")
        XCTAssertEqual(center.greenComponent, 0.1, accuracy: 0.03)
        XCTAssertEqual(center.blueComponent, 0.2, accuracy: 0.03)
        XCTAssertGreaterThan(center.alphaComponent, 0.99)
        for point in [(0, 0), (rendered.pixelsWide - 1, 0),
                      (0, rendered.pixelsHigh - 1), (rendered.pixelsWide - 1, rendered.pixelsHigh - 1)] {
            XCTAssertLessThan(try XCTUnwrap(rendered.colorAt(x: point.0, y: point.1)).alphaComponent, 0.01,
                              "The drag shadow must keep the visible thumbnail's rounded transparent corners")
        }
    }

    func testLivePhotoDragCopiesBothSourceFilesWithOneVisibleShadow() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-drag-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let still = directory.appendingPathComponent("source.png")
        let motion = directory.appendingPathComponent("source.mov")
        let image = try makeImage(size: NSSize(width: 80, height: 160))
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let stillBytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let motionBytes = Data("exact motion file payload".utf8)
        try stillBytes.write(to: still)
        try motionBytes.write(to: motion)

        let grid = ThumbnailGridController()
        grid.updateItems([ThumbnailGridItem(id: "pair", url: still, status: .finished,
            mediaKind: .livePhoto, contentVersion: 1, resourceURLs: [still, motion])],
            animatingDifferences: false)
        // Let the diffable snapshot finish before checking the native payload.
        await Task.yield()
        let sourceFrame = NSRect(x: 37, y: 59, width: 72, height: 144)
        let original = NSDraggingItem(pasteboardWriter: still as NSURL)
        original.setDraggingFrame(sourceFrame, contents: image)
        let expanded = grid.expandedDraggingItems([original])

        XCTAssertEqual(expanded.compactMap { ($0.item as? NSURL).map { $0 as URL } }, [still, motion])
        XCTAssertEqual(expanded.count, 2)
        XCTAssertTrue(expanded.first === original, "The native artwork item must survive resource expansion")
        XCTAssertTrue(expanded.allSatisfy { $0.draggingFrame == sourceFrame },
                      "The still and motion resources must share one spatial origin")
        XCTAssertEqual(expanded.reduce(0) { $0 + ($1.imageComponents?.count ?? 0) }, 1,
                       "The motion resource must not introduce another shadow or file icon")
        XCTAssertEqual(try Data(contentsOf: still), stillBytes)
        XCTAssertEqual(try Data(contentsOf: motion), motionBytes)
        XCTAssertEqual(grid.resourceURLs(forIDs: ["pair"]), [still, motion],
                       "Preparing the drag must retain both source files in the grid")
        grid.updateItems([], animatingDifferences: false, defersCompletionRemoval: false)
        await Task.yield()
    }

    func testNativeBuilderKeepsVisibleSourceAndOffscreenSelectionWhileExportingTheirFiles() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-visible-drag-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try makeImage(size: NSSize(width: 80, height: 160))
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        let imageBytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let stills = try (0..<40).map { index -> URL in
            let url = directory.appendingPathComponent("source-\(index).png")
            try imageBytes.write(to: url)
            return url
        }
        let motion = directory.appendingPathComponent("source-0.mov")
        try Data("exact paired motion".utf8).write(to: motion)
        let grid = ThumbnailGridController()
        let collection = grid.nsCollectionView
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        ThumbnailCollectionStyle.prepare(scroll, documentView: collection)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.orderFront(nil)
        defer {
            for cell in collection.visibleItems() { cell.prepareForReuse() }
            grid.updateItems([], animatingDifferences: false, defersCompletionRemoval: false)
            window.orderOut(nil)
        }
        grid.updateItems(stills.enumerated().map { index, url in
            ThumbnailGridItem(id: "item-\(index)", url: url, status: .finished,
                mediaKind: index == 0 ? .livePhoto : .photo, contentVersion: 1,
                resourceURLs: index == 0 ? [url, motion] : [url])
        }, animatingDifferences: false)
        scroll.layoutSubtreeIfNeeded()
        collection.layoutSubtreeIfNeeded()
        await Task.yield()
        // The chronological grid opens at the newest end. This export fixture
        // intentionally exercises the first visible item plus a distant item.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        collection.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let first = IndexPath(item: 0, section: 0)
        let distant = IndexPath(item: 39, section: 0)
        let source = try XCTUnwrap(collection.item(at: first) as? ThumbnailCollectionItem)
        source.prepareForReuse()
        let sourceView = try XCTUnwrap(source.view as? ThumbnailItemView)
        let sourceImageView = try XCTUnwrap(source.imageView)
        sourceImageView.image = image
        sourceImageView.alphaValue = 1
        sourceView.updateImageFrame(for: image)
        grid.applySelection(["item-0", "item-39"])
        XCTAssertNil(collection.item(at: distant), "The fixture must include a selected item outside the viewport")
        let selection = collection.selectionIndexPaths
        let sourceFrame = sourceImageView.frame

        let draggingItems = grid.nativeDraggingItems(at: [first, distant])

        XCTAssertEqual(draggingItems.compactMap { ($0.item as? NSURL).map { $0 as URL } },
                       [stills[0], motion, stills[39]],
                       "Offscreen selections must export their original resources alongside visible selections")
        XCTAssertEqual(draggingItems.reduce(0) { $0 + ($1.imageComponents?.count ?? 0) }, 1,
                       "Only the visible artwork should contribute a drag shadow")
        let component = try XCTUnwrap(draggingItems.first?.imageComponents?.first)
        let shadow = try XCTUnwrap(component.contents as? NSImage)
        XCTAssertFalse(shadow === image)
        XCTAssertLessThan(abs(component.frame.minX - sourceFrame.minX) + abs(component.frame.minY - sourceFrame.minY)
            + abs(component.frame.width - sourceFrame.width) + abs(component.frame.height - sourceFrame.height), 0.00001)
        XCTAssertTrue(collection.item(at: first) === source)
        XCTAssertTrue(sourceImageView.image === image)
        XCTAssertEqual(sourceImageView.frame, sourceFrame)
        XCTAssertEqual(sourceImageView.alphaValue, 1)
        XCTAssertFalse(sourceView.isHidden, "Starting a copy must leave the original cell visible")
        XCTAssertFalse(sourceImageView.isHidden)
        XCTAssertEqual(collection.selectionIndexPaths, selection)
        XCTAssertEqual(selection, [first, distant])
        XCTAssertNil(collection.item(at: distant), "Payload creation must not bring offscreen media into view")
        XCTAssertEqual(grid.resourceURLs(forIDs: ["item-0", "item-39"]),
                       [stills[0], motion, stills[39]])
        grid.updateItems([], animatingDifferences: false, defersCompletionRemoval: false)
        try await Task.sleep(for: .milliseconds(150))
    }

    private func makeImage(size: NSSize) throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let color = NSColor(deviceRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide { bitmap.setColor(color, atX: x, y: y) }
        }
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    private func render(_ image: NSImage) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let bounds = NSRect(origin: .zero, size: image.size)
        context.cgContext.clear(bounds)
        image.draw(in: bounds)
        context.flushGraphics()
        return bitmap
    }
}
