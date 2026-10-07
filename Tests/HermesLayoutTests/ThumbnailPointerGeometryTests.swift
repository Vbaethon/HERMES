import Foundation
import XCTest
@testable import HermesThumbnailUI

final class ThumbnailPointerGeometryTests: XCTestCase {
    func testEveryInteriorPresetChoosesTheClosestPhotoLocalPointerSlot() {
        let count = 5000, width: CGFloat = 1000, height: CGFloat = 600
        let metrics = ZoomMetrics(top: 22, left: 44, bottom: 208, right: 44, gap: 20)
        for level in 0..<4 {
            let base = ZoomGridSpec(level: level)
            let columns = ZoomGeometry.columns[level]
            for column in 0..<columns {
                let index = (1500 / columns) * columns + column
                let frame = base.frame(index: index, width: width, metrics: metrics)
                for unitX: CGFloat in [0.15, 0.5, 0.85] {
                    let point = CGPoint(x: frame.minX + frame.width * unitX, y: frame.midY)
                    let anchor = ZoomAnchor(index: index, frame: frame, documentPoint: point,
                        viewportPoint: CGPoint(x: point.x, y: 300))
                    let plan = ZoomPlan(anchor: anchor, base: base, width: width, height: height,
                                        count: count, metrics: metrics, endsAtNewest: true)
                    for target in 0..<4 {
                        let cell = plan.specs[target].frame(index: index, width: width, metrics: metrics)
                        let displacement = abs(cell.minX + cell.width * unitX - point.x)
                        let side = ZoomGeometry.side(width: width, columns: ZoomGeometry.columns[target], metrics: metrics)
                        let best = (0..<ZoomGeometry.columns[target]).map {
                            abs(metrics.left + CGFloat($0) * (side + metrics.gap) + side * unitX - point.x)
                        }.min()!
                        XCTAssertEqual(displacement, best, accuracy: 0.001,
                            "A pointer on column \(column) of preset \(level) must not jump across the gallery in preset \(target)")
                    }
                }
            }
        }
    }
    private func exhaustiveNearest(_ point: CGPoint, count: Int, width: CGFloat,
                                   spec: ZoomGridSpec, metrics: ZoomMetrics) -> Int? {
        (0..<count).min {
            ZoomGeometry.distance(point, to: spec.frame(index: $0, width: width, metrics: metrics)) <
                ZoomGeometry.distance(point, to: spec.frame(index: $1, width: width, metrics: metrics))
        }
    }

    func testNearestCellCandidatesMatchExhaustiveSearchAcrossPresetsAndIncompleteRows() {
        var seed: UInt64 = 0x4845524d4553
        func fraction() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 11) / CGFloat(UInt64(1) << 53)
        }
        let production = ZoomMetrics(top: 22, left: 44, bottom: 208, right: 44, gap: 20)
        for (level, columns) in ZoomGeometry.columns.enumerated() {
            for leading in 0..<columns {
                let spec = ZoomGridSpec(level: level, leadingSlots: leading)
                for count in [1, 2, 9, 68, 71, 5000] {
                    for width: CGFloat in [680, 1000] {
                        for metrics in [ZoomMetrics.demo, production] {
                            let height = spec.height(count: count, width: width, metrics: metrics)
                            for _ in 0..<20 {
                                let point = CGPoint(x: (fraction() * 1.8 - 0.4) * width,
                                                    y: (fraction() * 1.4 - 0.2) * height)
                                XCTAssertEqual(ZoomGeometry.nearestIndex(to: point, count: count, width: width,
                                                                       spec: spec, metrics: metrics),
                                               exhaustiveNearest(point, count: count, width: width,
                                                                 spec: spec, metrics: metrics),
                                               "level \(level), leading \(leading), count \(count), point \(point)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testPointerInCellGapsKeepsTheOriginalRectangleDistanceAndTieOrder() {
        let width: CGFloat = 1000, count = 68
        for (level, columns) in ZoomGeometry.columns.enumerated() {
            for leading in 0..<columns {
                let spec = ZoomGridSpec(level: level, leadingSlots: leading)
                for index in 0..<(count - 1) {
                    let a = spec.frame(index: index, width: width)
                    let b = spec.frame(index: index + 1, width: width)
                    if a.minY == b.minY {
                        for portion: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
                            let point = CGPoint(x: a.maxX + (b.minX - a.maxX) * portion, y: a.midY)
                            XCTAssertEqual(ZoomGeometry.nearestIndex(to: point, count: count, width: width, spec: spec),
                                           exhaustiveNearest(point, count: count, width: width, spec: spec, metrics: .demo))
                        }
                    }
                    if index + columns < count {
                        let below = spec.frame(index: index + columns, width: width)
                        let point = CGPoint(x: a.midX, y: (a.maxY + below.minY) / 2)
                        XCTAssertEqual(ZoomGeometry.nearestIndex(to: point, count: count, width: width, spec: spec),
                                       exhaustiveNearest(point, count: count, width: width, spec: spec, metrics: .demo))
                    }
                }
            }
        }
    }

    func testPointerOutsideLibraryAndVeryDistantPointsPreserveTheFirstWinningIndex() {
        let width: CGFloat = 1000, count = 71
        for (level, columns) in ZoomGeometry.columns.enumerated() {
            for leading in 0..<columns {
                let spec = ZoomGridSpec(level: level, leadingSlots: leading)
                let height = spec.height(count: count, width: width)
                for x: CGFloat in [-1e150, -10000, 0, width / 2, width, 10000, 1e150] {
                    for y: CGFloat in [-1e150, -10000, 0, height / 2, height, height + 10000, 1e150] {
                        let point = CGPoint(x: x, y: y)
                        XCTAssertEqual(ZoomGeometry.nearestIndex(to: point, count: count, width: width, spec: spec),
                                       exhaustiveNearest(point, count: count, width: width, spec: spec, metrics: .demo))
                    }
                }
            }
        }
        XCTAssertNil(ZoomGeometry.nearestIndex(to: .zero, count: 0, width: width, spec: ZoomGridSpec(level: 0)))
    }

    private func cursorPoint(plan: ZoomPlan, width: CGFloat, height: CGFloat, count: Int,
                             position: CGFloat, elasticScale: CGFloat = 1) -> CGPoint {
        let center = plan.focusCenter(width: width, height: height, count: count,
                                      position: position, elasticScale: elasticScale)
        let side = ZoomGeometry.side(width: width, position: position, metrics: plan.metrics) * elasticScale
        return CGPoint(x: center.x + (plan.anchor.unitPoint.x - 0.5) * side,
                       y: center.y + (plan.anchor.unitPoint.y - 0.5) * side)
    }

    func testSixAdjacentDirectionsMeasureActualCursorPointAtHeadBodyAndTail() {
        let width: CGFloat = 1000, height: CGFloat = 600, count = 71
        let metrics = ZoomMetrics(top: 22, left: 44, bottom: 208, right: 44, gap: 20)
        for (from, to) in [(0, 1), (1, 0), (1, 2), (2, 1), (2, 3), (3, 2)] {
            let source = ZoomGridSpec.endingAtNewest(level: from, count: count)
            let maximumOrigin = max(0, source.height(count: count, width: width, metrics: metrics) - height)
            for index in [0, count / 2, count - 1] {
                let cell = source.frame(index: index, width: width, metrics: metrics)
                for unit in [CGPoint(x: 0.12, y: 0.23), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.87, y: 0.74)] {
                    let documentPoint = CGPoint(x: cell.minX + cell.width * unit.x,
                                                y: cell.minY + cell.height * unit.y)
                    let origin = index == 0 ? 0 : (index == count - 1 ? maximumOrigin :
                        min(maximumOrigin, max(0, documentPoint.y - 230)))
                    let pointer = CGPoint(x: documentPoint.x, y: documentPoint.y - origin)
                    let anchor = ZoomAnchor(index: index, frame: cell, documentPoint: documentPoint, viewportPoint: pointer)
                    let plan = ZoomPlan(anchor: anchor, base: source, width: width, height: height, count: count,
                                        metrics: metrics, endsAtNewest: true, pinsToNewest: index == count - 1)
                    let initial = cursorPoint(plan: plan, width: width, height: height, count: count, position: CGFloat(from))
                    XCTAssertEqual(initial.x, pointer.x, accuracy: 0.0001)
                    XCTAssertEqual(initial.y, pointer.y, accuracy: 0.0001)
                    let endpoint = cursorPoint(plan: plan, width: width, height: height, count: count, position: CGFloat(to))
                    var previousX = initial.x
                    for step in 1...40 {
                        let position = CGFloat(from) + CGFloat(to - from) * CGFloat(step) / 40
                        let displayed = cursorPoint(plan: plan, width: width, height: height, count: count, position: position)
                        if endpoint.x >= initial.x { XCTAssertGreaterThanOrEqual(displayed.x, previousX - 0.0001) }
                        else { XCTAssertLessThanOrEqual(displayed.x, previousX + 0.0001) }
                        previousX = displayed.x
                    }
                    // At an integer endpoint AppKit receives the exact planned
                    // slot and only an admissible native vertical scroll origin.
                    let target = plan.specs[to].frame(index: index, width: width, metrics: metrics)
                    let center = plan.focusCenter(width: width, height: height, count: count, position: CGFloat(to))
                    XCTAssertEqual(center.x, target.midX, accuracy: 0.0001)
                    let targetMaximum = max(0, plan.specs[to].height(count: count, width: width, metrics: metrics) - height)
                    let targetOrigin = target.midY - center.y
                    XCTAssertGreaterThanOrEqual(targetOrigin, -0.0001)
                    XCTAssertLessThanOrEqual(targetOrigin, targetMaximum + 0.0001)
                    let desiredOrigin = target.minY + target.height * unit.y - pointer.y
                    if (0...targetMaximum).contains(desiredOrigin) {
                        XCTAssertEqual(endpoint.y, pointer.y, accuracy: 0.0001,
                                       "A usable pointer anchor must not be overridden by a previous bottom pin")
                    }
                }
            }
        }
    }

    func testStartingAtBottomCanZoomIntoAnOlderFocusWhoseTargetTailLeavesTheViewport() {
        let width: CGFloat = 1000, height: CGFloat = 600, count = 71
        let metrics = ZoomMetrics(top: 22, left: 44, bottom: 208, right: 44, gap: 20)
        let source = ZoomGridSpec.endingAtNewest(level: 0, count: count)
        let cell = source.frame(index: 46, width: width, metrics: metrics)
        let origin = source.height(count: count, width: width, metrics: metrics) - height
        let point = CGPoint(x: cell.minX + cell.width * 0.32, y: cell.minY + cell.height * 0.61)
        let pointer = CGPoint(x: point.x, y: point.y - origin)
        let anchor = ZoomAnchor(index: 46, frame: cell, documentPoint: point, viewportPoint: pointer)
        let pinned = ZoomPlan(anchor: anchor, base: source, width: width, height: height, count: count,
                              metrics: metrics, endsAtNewest: true, pinsToNewest: true)
        let unpinned = ZoomPlan(anchor: anchor, base: source, width: width, height: height, count: count,
                                metrics: metrics, endsAtNewest: true, pinsToNewest: false)
        XCTAssertEqual(pinned.specs, unpinned.specs, "Being at the source tail does not force all target layouts to stay there")
        XCTAssertNotEqual(pinned.specs[2].leadingSlots, ZoomGridSpec.endingAtNewest(level: 2, count: count).leadingSlots,
                          "An offscreen target tail must allow the compatible focal column")
        let focused = cursorPoint(plan: pinned, width: width, height: height, count: count, position: 2)
        XCTAssertEqual(focused.y, pointer.y, accuracy: 0.0001)
        let center = pinned.focusCenter(width: width, height: height, count: count, position: 2)
        let target = pinned.specs[2].frame(index: anchor.index, width: width, metrics: metrics)
        let last = pinned.specs[2].frame(index: count - 1, width: width, metrics: metrics)
        XCTAssertGreaterThan(last.minY - (target.midY - center.y), height,
                             "The target tail is outside the focused viewport")
    }

    func testElasticScalingRetainsTheSameNormalizedHorizontalPointerAtBothEndpoints() {
        let width: CGFloat = 1000, height: CGFloat = 600, count = 5000
        for level in [0, 3] {
            let source = ZoomGridSpec.endingAtNewest(level: level, count: count)
            let cell = source.frame(index: count / 2, width: width)
            for unit in [CGPoint(x: 0.1, y: 0.27), CGPoint(x: 0.85, y: 0.73)] {
                let point = CGPoint(x: cell.minX + cell.width * unit.x, y: cell.minY + cell.height * unit.y)
                let pointer = CGPoint(x: point.x, y: 240)
                let anchor = ZoomAnchor(index: count / 2, frame: cell, documentPoint: point, viewportPoint: pointer)
                let plan = ZoomPlan(anchor: anchor, base: source, width: width, height: height, count: count, endsAtNewest: true)
                for scale: CGFloat in level == 0 ? [0.805, 0.94, 1] : [1, 1.08, 1.5, 2.4] {
                    let displayed = cursorPoint(plan: plan, width: width, height: height, count: count,
                                                position: CGFloat(level), elasticScale: scale)
                    XCTAssertEqual(displayed.x, pointer.x, accuracy: 0.0001,
                                   "Elasticity must scale around the photo's pointer point, not its center")
                    XCTAssertEqual(displayed.y, pointer.y, accuracy: 0.0001)
                }
            }
        }
    }

}
