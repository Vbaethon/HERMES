import AppKit
import QuartzCore
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailBadgeRenderingTests: XCTestCase {
    func testDisplayedFormatAndDurationBadgesPaintOnlyOneCopyOfTheirText() async throws {
        _ = NSApplication.shared
        let item = ThumbnailCollectionItem()
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        view.frame.size = CGSize(width: 180, height: 180)
        let image = NSImage(size: CGSize(width: 120, height: 160), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        item.imageView?.image = image
        view.updateImageFrame(for: image)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }

        let badge = try XCTUnwrap(view.badgeLabel)
        let reference = NSView()
        let nativeLabel = NSTextField(labelWithString: "")
        nativeLabel.alignment = .center
        nativeLabel.lineBreakMode = .byClipping
        nativeLabel.textColor = ThumbnailBadgeStyle.textColor
        nativeLabel.wantsLayer = true
        nativeLabel.translatesAutoresizingMaskIntoConstraints = false
        reference.addSubview(nativeLabel)
        NSLayoutConstraint.activate([
            nativeLabel.centerXAnchor.constraint(equalTo: reference.centerXAnchor),
            nativeLabel.centerYAnchor.constraint(equalTo: reference.centerYAnchor)
        ])
        reference.wantsLayer = true
        reference.layer?.cornerRadius = ThumbnailBadgeStyle.cornerRadius
        reference.layer?.masksToBounds = true
        view.addSubview(reference)
        for text in ["PNG", "HEIC", "JPG", "WEBP", "0:09", "12:34", "PNG"] {
            view.setBadge(text)
            nativeLabel.stringValue = text
            nativeLabel.font = ThumbnailBadgeStyle.font(for: text)
            reference.frame = badge.frame.offsetBy(dx: -60, dy: 0)
            item.isSelected.toggle()
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            window.displayIfNeeded()
            CATransaction.flush()
            let actualLayer = try XCTUnwrap(badge.layer)
            let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            reference.layer?.backgroundColor = NSColor.black.withAlphaComponent(opaque ? 1 : 0.62).cgColor
            let actual = try pixels(of: actualLayer, scale: window.backingScaleFactor)
            let expected = try pixels(of: XCTUnwrap(reference.layer), scale: window.backingScaleFactor)
            let differences = zip(actual, expected).filter { $0 != $1 }.count
            XCTAssertEqual(differences, 0,
                           "\(text): the displayed badge must match one native label, including after selection and reuse")
            let label = try XCTUnwrap(badge.subviews.first as? NSTextField)
            XCTAssertEqual(label.frame.height, label.intrinsicContentSize.height,
                           "The background must not stretch AppKit's native text line")
            let alignment = label.alignmentRect(forFrame: label.frame)
            // Native alignment rects can round to half a backing pixel.
            let rounding = 0.5 / window.backingScaleFactor
            XCTAssertEqual(alignment.midX, badge.bounds.midX, accuracy: rounding)
            XCTAssertEqual(alignment.midY, badge.bounds.midY, accuracy: rounding)
            try assertTextCentered(in: actual, size: badge.bounds.size, scale: window.backingScaleFactor, text: text)

            // Pinch artwork takes a snapshot before attaching the label to a window.
            let unattached = ThumbnailBadgeLabel(labelWithString: text)
            unattached.frame.size = badge.bounds.size
            let scale = window.backingScaleFactor
            let snapshot = try XCTUnwrap(unattached.bitmap(scale: scale))
            XCTAssertEqual(snapshot.width, Int(ceil(badge.bounds.width * scale)))
            XCTAssertEqual(snapshot.height, Int(ceil(badge.bounds.height * scale)))
            let referenceSnapshot = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: snapshot.width, pixelsHigh: snapshot.height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            referenceSnapshot.size = reference.bounds.size
            reference.cacheDisplay(in: reference.bounds, to: referenceSnapshot)
            let snapshotLayer = CALayer()
            snapshotLayer.bounds = badge.bounds
            snapshotLayer.contents = snapshot
            snapshotLayer.contentsScale = window.backingScaleFactor
            snapshotLayer.contentsGravity = .resize
            let zoomPixels = try pixels(of: snapshotLayer, scale: window.backingScaleFactor)
            snapshotLayer.contents = try XCTUnwrap(referenceSnapshot.cgImage)
            let nativeSnapshotPixels = try pixels(of: snapshotLayer, scale: window.backingScaleFactor)
            XCTAssertEqual(zip(zoomPixels, nativeSnapshotPixels).filter { $0 != $1 }.count, 0,
                           "\(text): zoom artwork must retain the same native text and rounded background")
            try assertTextCentered(in: zoomPixels, size: badge.bounds.size, scale: scale, text: text)
        }
    }

    private func assertTextCentered(in pixels: Data, size: NSSize, scale: CGFloat, text: String) throws {
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        var xs: [Int] = [], ys: [Int] = []
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset] > 180 && pixels[offset + 1] > 180 && pixels[offset + 2] > 180 {
                    xs.append(x); ys.append(y)
                }
            }
        }
        let minX = try XCTUnwrap(xs.min()), maxX = try XCTUnwrap(xs.max())
        let minY = try XCTUnwrap(ys.min()), maxY = try XCTUnwrap(ys.max())
        XCTAssertEqual(Double(minX + maxX) / 2, Double(width - 1) / 2, accuracy: 1,
                       "\(text): visible glyphs must have balanced left and right padding")
        XCTAssertEqual(Double(minY + maxY) / 2, Double(height - 1) / 2, accuracy: 1,
                       "\(text): visible glyphs must have balanced top and bottom padding")
    }

    func testBadgeRetainsReadableStaticTextSemanticsWhenItsValueChanges() throws {
        _ = NSApplication.shared
        let badge = ThumbnailBadgeLabel(labelWithString: "HEIC")
        badge.frame.size = ThumbnailBadgeStyle.size(for: "HEIC")
        for text in ["HEIC", "0:09", "", "PNG"] {
            badge.stringValue = text
            badge.layoutSubtreeIfNeeded()
            let label = try XCTUnwrap(badge.accessibilityChildren()?.first as? NSTextFieldCell)
            XCTAssertTrue(label.isAccessibilityElement())
            XCTAssertEqual(label.accessibilityRole(), .staticText)
            XCTAssertEqual(label.accessibilityValue() as? String, text)
            XCTAssertNil(badge.hitTest(.zero))
        }
    }

    private func pixels(of layer: CALayer, scale: CGFloat) throws -> Data {
        let width = Int(ceil(layer.bounds.width * scale))
        let height = Int(ceil(layer.bounds.height * scale))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return Data(bytes: try XCTUnwrap(context.data), count: width * height * 4)
    }
}
