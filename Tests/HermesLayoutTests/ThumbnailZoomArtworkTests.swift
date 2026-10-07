import AppKit
import QuartzCore
import XCTest
@testable import HermesThumbnailUI

@MainActor
final class ThumbnailZoomArtworkTests: XCTestCase {
    private func bitmap(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return try XCTUnwrap(context.makeImage())
    }

    private func plan(level: Int, count: Int = 80, index: Int = 40,
                      width: CGFloat = 1000, height: CGFloat = 600) -> ZoomPlan {
        let spec = ZoomGridSpec.endingAtNewest(level: level, count: count)
        let frame = spec.frame(index: index, width: width)
        let anchor = ZoomAnchor(index: index, frame: frame,
            documentPoint: CGPoint(x: frame.midX, y: frame.midY),
            viewportPoint: CGPoint(x: frame.midX, y: 300))
        return ZoomPlan(anchor: anchor, base: spec, width: width, height: height,
                        count: count, endsAtNewest: true)
    }

    private func focalTile(in overlay: ThumbnailZoomOverlay, index: Int,
                           metrics: ZoomMetrics) throws -> CALayer {
        let viewport = try XCTUnwrap(overlay.layer?.sublayers?.last)
        let root = try XCTUnwrap(viewport.sublayers?.first)
        let frame = try XCTUnwrap(overlay.focalFrames[index])
        return try XCTUnwrap(root.sublayers?.first { $0.frame == frame })
    }

    func testMovingFocalArtworkClipsAtTheActualViewportRatherThanLayoutPadding() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        overlay.setAssets((0..<80).map { _ in ZoomArtwork(image: try? bitmap(width: 300, height: 400)) })
        let plan = plan(level: 1, index: 42)
        overlay.render(position: 2.8, plan: plan, weights: [0, 0, 0.1, 0.9])
        let viewports = try XCTUnwrap(overlay.layer?.sublayers)
        XCTAssertEqual(viewports.count, 5)
        XCTAssertTrue(viewports.allSatisfy { $0.frame == overlay.bounds },
                      "A moving focal image must not be cut off by a different inset clipping rectangle")
        let tile = try focalTile(in: overlay, index: plan.anchor.index, metrics: plan.metrics)
        XCTAssertEqual(tile.frame, overlay.focalFrames[plan.anchor.index])
    }

    private func focalBadge(in overlay: ThumbnailZoomOverlay, tile: CALayer) throws -> CALayer {
        let root = try XCTUnwrap(tile.superlayer)
        let decorations = try XCTUnwrap(root.sublayers?.last)
        return try XCTUnwrap(decorations.sublayers?.first { tile.frame.contains($0.frame) })
    }

    private func assertBackgroundBadgesFollowTheirTiles(_ overlay: ThumbnailZoomOverlay,
                                                       file: StaticString = #filePath, line: UInt = #line) throws {
        for viewport in try XCTUnwrap(overlay.layer?.sublayers?.dropLast()) {
            let root = try XCTUnwrap(viewport.sublayers?.first)
            let decorations = try XCTUnwrap(root.sublayers?.last)
            for tile in try XCTUnwrap(root.sublayers?.dropLast()) {
                let badge = try XCTUnwrap(decorations.sublayers?.first { tile.frame.contains($0.frame) })
                if tile.isHidden {
                    XCTAssertTrue(badge.isHidden,
                                  "Hiding a duplicate focal tile must also hide its decoration", file: file, line: line)
                }
            }
            XCTAssertEqual(decorations.sublayers?.count ?? 0, root.sublayers!.count - 1,
                           "Every retained tile owns one attached badge; evicted badges must not survive",
                           file: file, line: line)
        }
    }

    func testUnavailableArtworkHasNoDetachedFormatBadgeOrSelectionRing() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let badge = try bitmap(width: 56, height: 36)
        let art = ZoomArtwork(image: nil, badge: badge, badgeSize: CGSize(width: 28, height: 18),
                              ringColor: NSColor.selectedContentBackgroundColor.cgColor)
        overlay.setAssets(Array(repeating: art, count: 80))
        let plan = plan(level: 2)
        overlay.render(position: 2, plan: plan, weights: [0, 0, 1, 0])
        let tile = try focalTile(in: overlay, index: 40, metrics: plan.metrics)
        let layers = try XCTUnwrap(tile.sublayers)
        let badgeLayer = try focalBadge(in: overlay, tile: tile)
        XCTAssertTrue(layers[1].isHidden, "A selection ring must stay attached to a real thumbnail")
        XCTAssertTrue(badgeLayer.isHidden, "Cached badge text must not appear on an empty photo tile")

        overlay.replaceImage(try bitmap(width: 60, height: 120), at: 40)
        overlay.render(position: 2, plan: plan, weights: [0, 0, 1, 0])
        XCTAssertFalse(layers[1].isHidden)
        XCTAssertFalse(badgeLayer.isHidden)
    }

    func testFocalBadgesRemainAttachedAndKeepNativePointSizeInAllAdjacentDirections() throws {
        let image = try bitmap(width: 120, height: 180)
        let badge = try bitmap(width: 56, height: 36)
        let art = ZoomArtwork(image: image, badge: badge, badgeSize: CGSize(width: 28, height: 18))
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        overlay.setAssets(Array(repeating: art, count: 80))
        for (from, to) in [(0, 1), (1, 0), (1, 2), (2, 1), (2, 3), (3, 2)] {
            let plan = plan(level: from)
            for progress in [0.0, 0.15, 0.5, 0.85, 1.0] {
                let position = CGFloat(from) + CGFloat(to - from) * progress
                var alpha = ZoomAlphaPresentation(level: from)
                alpha.update(position: position)
                overlay.render(position: position, plan: plan, weights: alpha.weights)
                try assertBackgroundBadgesFollowTheirTiles(overlay)
                let tile = try focalTile(in: overlay, index: 40, metrics: plan.metrics)
                let layers = try XCTUnwrap(tile.sublayers)
                let badgeLayer = try focalBadge(in: overlay, tile: tile)
                let photo = layers[0].frame
                let badgeFrame = badgeLayer.frame.offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY)
                XCTAssertFalse(badgeLayer.isHidden)
                XCTAssertEqual(badgeFrame.width, 28, accuracy: 0.001)
                XCTAssertEqual(badgeFrame.height, 18, accuracy: 0.001)
                XCTAssertEqual(photo.maxX - badgeFrame.maxX, ThumbnailBadgeStyle.inset, accuracy: 0.001)
                XCTAssertEqual(photo.maxY - badgeFrame.maxY, ThumbnailBadgeStyle.inset, accuracy: 0.001)
                XCTAssertTrue(photo.contains(badgeFrame))
                XCTAssertEqual(badgeLayer.contentsScale, 2)
                XCTAssertEqual(tile.opacity, 1)
            }
        }
    }

    func testZoomBackgroundUsesTheViewAppearanceEvenInsideAnOppositeDrawingAppearance() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        overlay.appearance = aqua
        overlay.setAssets(Array(repeating: ZoomArtwork(image: try bitmap(width: 60, height: 120)), count: 80))
        let plan = plan(level: 2)
        var expected: NSColor?
        aqua.performAsCurrentDrawingAppearance {
            expected = NSColor(cgColor: NSColor.windowBackgroundColor.cgColor)?.usingColorSpace(.deviceRGB)
        }
        dark.performAsCurrentDrawingAppearance {
            overlay.render(position: 1.5, plan: plan, weights: [0, 0.5, 0.5, 0])
        }
        let expectedColor = try XCTUnwrap(expected)
        let actual = try XCTUnwrap(overlay.layer?.backgroundColor)
        let actualColor = try XCTUnwrap(NSColor(cgColor: actual)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(actualColor.redComponent, expectedColor.redComponent, accuracy: 0.001)
        XCTAssertEqual(actualColor.greenComponent, expectedColor.greenComponent, accuracy: 0.001)
        XCTAssertEqual(actualColor.blueComponent, expectedColor.blueComponent, accuracy: 0.001)
        XCTAssertEqual(actualColor.alphaComponent, 1, accuracy: 0.001)
        for viewport in try XCTUnwrap(overlay.layer?.sublayers?.dropLast()) {
            XCTAssertEqual(viewport.backgroundColor, actual)
        }
    }

    func testNativeBadgeKeepsItsTextWhileWaitingForArtworkAndReturnsAttachedToTheImage() throws {
        let item = ThumbnailCollectionItem()
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        let imageView = try XCTUnwrap(item.imageView)
        let badge = try XCTUnwrap(view.badgeLabel)
        let failure = try XCTUnwrap(view.failureLabel)
        let placeholder = try XCTUnwrap(view.placeholderLabel)
        failure.stringValue = "原文件不可用"
        failure.isHidden = false
        placeholder.stringValue = "example.jpg"
        placeholder.isHidden = false

        view.setBadge("JPG")
        view.updateImageFrame(for: nil)
        XCTAssertEqual(badge.stringValue, "JPG")
        XCTAssertTrue(badge.isHidden)
        XCTAssertFalse(failure.isHidden, "The unavailable message must keep its native fallback presentation")
        XCTAssertFalse(placeholder.isHidden)

        let image = NSImage(cgImage: try bitmap(width: 60, height: 120), size: CGSize(width: 60, height: 120))
        imageView.image = image
        imageView.alphaValue = 1
        view.updateImageFrame(for: image)
        XCTAssertFalse(badge.isHidden)
        XCTAssertTrue(imageView.frame.contains(badge.frame))
        XCTAssertEqual(imageView.frame.minY + ThumbnailBadgeStyle.inset, badge.frame.minY, accuracy: 1)

        imageView.image = nil
        view.updateImageFrame(for: nil)
        XCTAssertTrue(badge.isHidden)
        XCTAssertEqual(badge.stringValue, "JPG")
        view.setBadge("0:42")
        XCTAssertTrue(badge.isHidden)
        imageView.image = image
        view.updateImageFrame(for: image)
        XCTAssertEqual(badge.stringValue, "0:42")
        XCTAssertFalse(badge.isHidden, "A loaded duration must return when the real image returns")
        item.prepareForReuse()
        XCTAssertTrue(badge.isHidden)
        XCTAssertEqual(badge.stringValue, "")
    }

    func testSparseArtworkUsesTheLibraryCountAndAllowsNewVisibleImagesToArrive() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let image = try bitmap(width: 60, height: 120)
        let libraryCount = 20_000
        let focal = 10_000
        overlay.setAssets([focal: ZoomArtwork(image: image)], count: libraryCount)
        let plan = plan(level: 2, count: libraryCount, index: focal)
        overlay.render(position: 2, plan: plan, weights: [0, 0, 1, 0])
        XCTAssertNotNil(overlay.focalFrames[focal], "Sparse bitmap storage must preserve the real item index")
        XCTAssertEqual(overlay.focalFrames.count, 5)
        XCTAssertTrue(overlay.image(at: focal) === image)
        XCTAssertNil(overlay.image(at: focal + 1))
        overlay.replaceImage(image, at: focal + 1)
        XCTAssertTrue(overlay.image(at: focal + 1) === image)
        overlay.render(position: 2.5, plan: plan, weights: [0, 0, 0.5, 0.5])
        XCTAssertLessThan(overlay.retainedTileCount, 300,
                          "Rendered layer count must depend on the viewport, not library count")
        overlay.replaceImage(image, at: libraryCount)
        XCTAssertNil(overlay.image(at: libraryCount))
    }

    func testEveryDissolvingGridUsesTheRealGalleryBackground() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        overlay.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        overlay.backgroundColor = .white
        overlay.setAssets([40: ZoomArtwork(image: try bitmap(width: 60, height: 120))], count: 80)
        let plan = plan(level: 2)
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        dark.performAsCurrentDrawingAppearance {
            overlay.render(position: 1.5, plan: plan, weights: [0, 0.5, 0.5, 0])
        }
        let actual = try XCTUnwrap(overlay.layer?.backgroundColor)
        let color = try XCTUnwrap(NSColor(cgColor: actual)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 1, accuracy: 0.001)
        for viewport in try XCTUnwrap(overlay.layer?.sublayers?.dropLast()) {
            XCTAssertEqual(viewport.backgroundColor, actual)
        }
        overlay.backgroundColor = .controlBackgroundColor
        var expected: CGColor?
        overlay.effectiveAppearance.performAsCurrentDrawingAppearance {
            expected = NSColor.controlBackgroundColor.cgColor
        }
        XCTAssertEqual(overlay.layer?.backgroundColor, expected,
                       "Changing the native gallery background must invalidate the resolved color")
    }

    func testSuppressedOverlayBadgesRemainSuppressedAfterNewImagesAndLayersArrive() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let image = try bitmap(width: 60, height: 120)
        let badge = try bitmap(width: 56, height: 36)
        let art = ZoomArtwork(image: image, badge: badge, badgeSize: CGSize(width: 28, height: 18))
        overlay.setAssets([40: art, 41: art], count: 80)
        let plan = plan(level: 2)
        overlay.beginBadgeSuppression(animated: false)
        for position in [2.0, 2.2, 2.8, 3.0, 2.0] {
            var alpha = ZoomAlphaPresentation(level: 2)
            alpha.update(position: position)
            overlay.render(position: position, plan: plan, weights: alpha.weights)
            for viewport in try XCTUnwrap(overlay.layer?.sublayers) {
                let root = try XCTUnwrap(viewport.sublayers?.first)
                let decorations = try XCTUnwrap(root.sublayers?.last)
                XCTAssertEqual(decorations.opacity, 0,
                               "A new tile must inherit the same parent opacity throughout pinch and handoff")
            }
        }
        overlay.setZoomBadgeSuppressed(false, animated: false)
        let tile = try focalTile(in: overlay, index: 40, metrics: plan.metrics)
        XCTAssertEqual(try focalBadge(in: overlay, tile: tile).superlayer?.opacity, 1)
    }

    func testNativeAsyncTextAndReuseRespectZoomBadgeSuppression() throws {
        let item = ThumbnailCollectionItem()
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        let badge = try XCTUnwrap(view.badgeLabel)
        item.setZoomBadgeSuppressed(true, animated: false)
        view.setBadge("0:42")
        let image = NSImage(cgImage: try bitmap(width: 60, height: 120), size: CGSize(width: 60, height: 120))
        item.imageView?.image = image
        view.updateImageFrame(for: image)
        XCTAssertEqual(badge.stringValue, "0:42")
        XCTAssertEqual(badge.alphaValue, 0)
        XCTAssertFalse(badge.isHidden, "The stored text is positioned on its image; the common suppression owns alpha")
        item.prepareForReuse()
        view.setBadge("JPG")
        item.imageView?.image = image
        view.updateImageFrame(for: image)
        XCTAssertEqual(badge.alphaValue, 0, "Cell reuse must not briefly reveal metadata during an active gesture")
        item.setZoomBadgeSuppressed(false, animated: false)
        XCTAssertEqual(badge.alphaValue, 1)
        XCTAssertEqual(badge.stringValue, "JPG")
        item.setZoomBadgeSuppressed(true, animated: false)
        XCTAssertEqual(badge.alphaValue, 0, "A second gesture must cancel a pending reveal")
    }

    func testOverlayReentryBeginsAtTheNativePresentationOpacity() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        overlay.setAssets([40: ZoomArtwork(image: try bitmap(width: 60, height: 120))], count: 80)
        overlay.beginBadgeSuppression(animated: false)
        overlay.beginBadgeSuppression(animated: true, fromOpacity: 0.35)
        for viewport in try XCTUnwrap(overlay.layer?.sublayers) {
            let root = try XCTUnwrap(viewport.sublayers?.first)
            let decorations = try XCTUnwrap(root.sublayers?.last)
            XCTAssertEqual(decorations.opacity, 0)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = try XCTUnwrap(decorations.animation(forKey: "thumbnailZoomBadgeOpacity") as? CABasicAnimation)
                XCTAssertEqual(try XCTUnwrap(fade.fromValue as? NSNumber).floatValue, 0.35, accuracy: 0.001)
                XCTAssertEqual(fade.duration, ThumbnailZoomBadgeAnimation.duration)
            }
        }
    }
}
