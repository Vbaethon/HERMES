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
                        count: count)
    }

    private func focalTile(in overlay: ThumbnailZoomOverlay, index: Int,
                           metrics: ZoomMetrics) throws -> CALayer {
        let level = try XCTUnwrap(overlay.states.first { $0.weight > 0 }).spec.level
        let viewport = try XCTUnwrap(overlay.layer?.sublayers?[level])
        let root = try XCTUnwrap(viewport.sublayers?.first)
        let frame = try XCTUnwrap(overlay.focalFrames[index])
        return try XCTUnwrap(root.sublayers?.dropLast().first {
            let displayed = $0.frame.applying(root.affineTransform())
            return abs(displayed.midX - frame.midX) + abs(displayed.midY - frame.midY) < 0.01
        })
    }

    func testMovingFocalArtworkClipsAtTheActualViewportRatherThanLayoutPadding() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        overlay.setAssets((0..<80).map { _ in ZoomArtwork(image: try? bitmap(width: 300, height: 400)) })
        let plan = plan(level: 1, index: 42)
        overlay.render(position: 2.8, plan: plan, weights: [0, 0, 0.1, 0.9])
        let viewports = try XCTUnwrap(overlay.layer?.sublayers)
        XCTAssertEqual(viewports.count, 4)
        XCTAssertTrue(viewports.allSatisfy { $0.frame == overlay.bounds },
                      "A moving focal image must not be cut off by a different inset clipping rectangle")
        let tile = try focalTile(in: overlay, index: plan.anchor.index, metrics: plan.metrics)
        let displayed = tile.frame.applying(try XCTUnwrap(tile.superlayer).affineTransform())
        let expected = try XCTUnwrap(overlay.focalFrames[plan.anchor.index])
        XCTAssertEqual(displayed.midX, expected.midX, accuracy: 0.01)
        XCTAssertEqual(displayed.midY, expected.midY, accuracy: 0.01)
    }

    func testFiveToThreeFadesTheOuterPointerRowPhotoWhileTheAlignedPhotoKeepsItsColor() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        overlay.backgroundColor = .white
        let image = try bitmap(width: 120, height: 120)
        overlay.setAssets([40: ZoomArtwork(image: image), 42: ZoomArtwork(image: image)], count: 80)
        let plan = plan(level: 2, index: 42)
        overlay.isHidden = false
        func red(at x: Int) throws -> Double {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 600,
                bitsPerComponent: 8, bytesPerRow: 4000, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            try XCTUnwrap(overlay.layer).render(in: context)
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return Double(pixels[(300 * 1000 + x) * 4]) / 255
        }
        overlay.render(position: 2, plan: plan, weights: [0, 0, 1, 0])
        let originalRed = try red(at: 500)
        XCTAssertLessThan(originalRed, 0.5, "The control must contain real image pixels")
        overlay.render(position: 2.5, plan: plan, weights: [0, 0, 0.5, 0.5])
        // The source row's outer photo is clipped at the left viewport edge.
        // Its corresponding three-column photo has moved into the prior row.
        let departingRed = try red(at: 50)
        let alignedRed = try red(at: 500)
        XCTAssertEqual(departingRed, (originalRed + 1) / 2, accuracy: 0.02,
                       "The red-box neighbour must render at half weight, not remain opaque")
        XCTAssertEqual(alignedRed, originalRed, accuracy: 0.02,
                       "The identical aligned photo must not wash out during the common crossfade")
        XCTAssertNil(overlay.focalFrames[40])
        XCTAssertNotNil(overlay.focalFrames[42])
    }

    private func focalBadge(in overlay: ThumbnailZoomOverlay, tile: CALayer) throws -> CALayer {
        let root = try XCTUnwrap(tile.superlayer)
        let decorations = try XCTUnwrap(root.sublayers?.last)
        return try XCTUnwrap(decorations.sublayers?.first { tile.frame.contains($0.frame) })
    }

    private func assertBackgroundBadgesFollowTheirTiles(_ overlay: ThumbnailZoomOverlay,
                                                       file: StaticString = #filePath, line: UInt = #line) throws {
        for viewport in try XCTUnwrap(overlay.layer?.sublayers) {
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
                let scale = try XCTUnwrap(tile.superlayer).affineTransform().a
                XCTAssertFalse(badgeLayer.isHidden)
                XCTAssertEqual(badgeFrame.width * scale, 28, accuracy: 0.001)
                XCTAssertEqual(badgeFrame.height * scale, 18, accuracy: 0.001)
                XCTAssertEqual((photo.maxX - badgeFrame.maxX) * scale, ThumbnailBadgeStyle.inset, accuracy: 0.001)
                XCTAssertEqual((photo.maxY - badgeFrame.maxY) * scale, ThumbnailBadgeStyle.inset, accuracy: 0.001)
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
        for viewport in try XCTUnwrap(overlay.layer?.sublayers) {
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
        for viewport in try XCTUnwrap(overlay.layer?.sublayers) {
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

    func testBadgeFadeUsesTheVerifiedNativeLinearCurve() {
        var animation = ThumbnailZoomBadgeAnimation()
        animation.setSuppressed(true, animated: true, at: 10)
        for (time, opacity) in [(10.0, 1.0), (10.05, 0.75), (10.1, 0.5), (10.15, 0.25), (10.21, 0.0)] {
            animation.advance(at: time)
            XCTAssertEqual(animation.opacity, opacity, accuracy: 0.0001,
                           "The native decoration curve is linear over 0.2 seconds")
        }
        XCTAssertFalse(animation.isAnimating)
        animation.setSuppressed(false, animated: true, at: 11)
        for (time, opacity) in [(11.05, 0.25), (11.1, 0.5), (11.15, 0.75), (11.21, 1.0)] {
            animation.advance(at: time)
            XCTAssertEqual(animation.opacity, opacity, accuracy: 0.0001)
        }
        XCTAssertFalse(animation.isAnimating)
    }

    func testRapidBadgeReentryKeepsUnfinishedNativeDeltasWithoutOpacityJumps() {
        var animation = ThumbnailZoomBadgeAnimation()
        animation.setSuppressed(true, animated: true, at: 10)
        animation.advance(at: 10.1)
        XCTAssertEqual(animation.opacity, 0.5, accuracy: 0.0001)
        animation.setSuppressed(false, animated: true, at: 10.1)
        XCTAssertEqual(animation.opacity, 0.5, accuracy: 0.0001)
        animation.advance(at: 10.15)
        XCTAssertEqual(animation.opacity, 0.5, accuracy: 0.0001,
                       "Native additive retargeting retains the unfinished fade rather than restarting an easing curve")
        animation.advance(at: 10.25)
        XCTAssertEqual(animation.opacity, 0.75, accuracy: 0.0001)
        animation.setSuppressed(true, animated: true, at: 10.25)
        XCTAssertEqual(animation.opacity, 0.75, accuracy: 0.0001)
        animation.advance(at: 10.3)
        XCTAssertEqual(animation.opacity, 0.75, accuracy: 0.0001)
        animation.advance(at: 10.35)
        XCTAssertEqual(animation.opacity, 0.5, accuracy: 0.0001)
        animation.advance(at: 10.46)
        XCTAssertEqual(animation.opacity, 0)
        XCTAssertFalse(animation.isAnimating)
        animation.setSuppressed(false, animated: false, at: 11)
        XCTAssertEqual(animation.opacity, 1)
        XCTAssertFalse(animation.isAnimating, "Reduce Motion clears the common animation once")
    }

    func testSuppressedOverlayBadgesRemainSuppressedAfterNewImagesAndLayersArrive() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        let image = try bitmap(width: 60, height: 120)
        let badge = try bitmap(width: 56, height: 36)
        let art = ZoomArtwork(image: image, badge: badge, badgeSize: CGSize(width: 28, height: 18))
        overlay.setAssets([40: art, 41: art], count: 80)
        let plan = plan(level: 2)
        overlay.setZoomBadgeOpacity(0)
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
        overlay.setZoomBadgeOpacity(1)
        let tile = try focalTile(in: overlay, index: 40, metrics: plan.metrics)
        XCTAssertEqual(try focalBadge(in: overlay, tile: tile).superlayer?.opacity, 1)
    }

    func testNativeAsyncTextAndReuseRespectZoomBadgeSuppression() throws {
        let item = ThumbnailCollectionItem()
        let view = try XCTUnwrap(item.view as? ThumbnailItemView)
        let badge = try XCTUnwrap(view.badgeLabel)
        item.setZoomBadgeOpacity(0)
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
        item.setZoomBadgeOpacity(1)
        XCTAssertEqual(badge.alphaValue, 1)
        XCTAssertEqual(badge.stringValue, "JPG")
        item.setZoomBadgeOpacity(0)
        XCTAssertEqual(badge.alphaValue, 0, "A second gesture must cancel a pending reveal")
    }

    func testEveryOverlayGridUsesTheCommonOpacityWithoutIndependentAnimations() throws {
        let overlay = ThumbnailZoomOverlay(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        overlay.setAssets([40: ZoomArtwork(image: try bitmap(width: 60, height: 120))], count: 80)
        overlay.setZoomBadgeOpacity(0.35)
        for viewport in try XCTUnwrap(overlay.layer?.sublayers) {
            let root = try XCTUnwrap(viewport.sublayers?.first)
            let decorations = try XCTUnwrap(root.sublayers?.last)
            XCTAssertEqual(decorations.opacity, 0.35, accuracy: 0.001)
            XCTAssertTrue(decorations.animationKeys()?.isEmpty ?? true,
                          "The prepared grids project one value instead of owning competing fade timelines")
        }
    }
}
