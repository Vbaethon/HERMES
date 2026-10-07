import Foundation

struct ZoomMetrics: Equatable {
    var top: CGFloat = 24
    var left: CGFloat = 24
    var bottom: CGFloat = 24
    var right: CGFloat = 24
    var gap: CGFloat = 16
    static let demo = ZoomMetrics()
}

enum ZoomGeometry {
    static let columns = [9, 7, 5, 3]
    static let inset: CGFloat = 24
    static let gap: CGFloat = 16

    static func clamped(_ position: CGFloat) -> CGFloat { min(3, max(0, position)) }

    static func side(width: CGFloat, columns: Int, metrics: ZoomMetrics = .demo) -> CGFloat {
        max(1, (width - metrics.left - metrics.right - metrics.gap * CGFloat(columns - 1)) / CGFloat(columns))
    }

    static func side(width: CGFloat, position: CGFloat, metrics: ZoomMetrics = .demo) -> CGFloat {
        let p = clamped(position), lower = Int(floor(p)), upper = min(3, lower + 1)
        return mix(side(width: width, columns: columns[lower], metrics: metrics),
                   side(width: width, columns: columns[upper], metrics: metrics), p - CGFloat(lower))
    }

    // Only complete, discrete layouts have item frames. Zoom never interpolates
    // an item's x/y between its old and new row/column.
    static func frame(index: Int, width: CGFloat, level: Int, leadingSlots: Int = 0, metrics: ZoomMetrics = .demo) -> CGRect {
        let columns = columns[level], slot = index + leadingSlots
        let side = side(width: width, columns: columns, metrics: metrics)
        return CGRect(x: metrics.left + CGFloat(slot % columns) * (side + metrics.gap),
                      y: metrics.top + CGFloat(slot / columns) * (side + metrics.gap), width: side, height: side)
    }

    static func height(count: Int, width: CGFloat, level: Int, leadingSlots: Int = 0, metrics: ZoomMetrics = .demo) -> CGFloat {
        guard count > 0 else { return metrics.top + metrics.bottom }
        let rows = (count + leadingSlots + columns[level] - 1) / columns[level]
        return metrics.top + metrics.bottom + CGFloat(rows) * (side(width: width, columns: columns[level], metrics: metrics) + metrics.gap) - metrics.gap
    }

    static func position(forSide side: CGFloat, width: CGFloat, metrics: ZoomMetrics = .demo) -> CGFloat {
        let sides = columns.map { Self.side(width: width, columns: $0, metrics: metrics) }
        if side <= sides[0] { return 0 }
        for level in 0..<3 where side <= sides[level + 1] {
            return CGFloat(level) + (side - sides[level]) / (sides[level + 1] - sides[level])
        }
        return 3
    }

    static func nearestIndex(to point: CGPoint, count: Int, width: CGFloat, spec: ZoomGridSpec, metrics: ZoomMetrics = .demo) -> Int? {
        guard count > 0 else { return nil }
        let columns = Self.columns[spec.level]
        let pitch = side(width: width, columns: columns, metrics: metrics) + metrics.gap
        guard pitch.isFinite, pitch > 0, metrics.gap >= 0, point.x.isFinite, point.y.isFinite,
              metrics.top.isFinite, spec.leadingSlots >= 0 else {
            // Invalid geometry is not delivered by AppKit; preserve the old
            // distance/tie semantics rather than converting NaN to an integer.
            return (0..<count).min {
                distance(point, to: spec.frame(index: $0, width: width, metrics: metrics)) <
                    distance(point, to: spec.frame(index: $1, width: width, metrics: metrics))
            }
        }
        let firstSlot = spec.leadingSlots, lastSlot = firstSlot + count - 1
        let firstRow = firstSlot / columns, lastRow = lastSlot / columns
        let row = Int(min(CGFloat(lastRow), max(CGFloat(firstRow), floor((point.y - metrics.top) / pitch))))
        // Only the rows bordering the pointer and either incomplete boundary
        // can win. A complete nearer row dominates any farther complete row.
        // A partial boundary can instead lose to its neighbouring complete row.
        let rows = Set([row - 1, row, row + 1, firstRow, firstRow + 1, lastRow - 1, lastRow])
        var nearest: Int?
        var nearestDistance = CGFloat.infinity
        for row in rows where (firstRow...lastRow).contains(row) {
            let first = max(firstSlot, row * columns)
            let last = min(lastSlot, row * columns + columns - 1)
            guard first <= last else { continue }
            // Each supported preset has at most nine columns. Checking these
            // few cells retains exact rectangle-gap and equal-distance ties.
            for slot in first...last {
                let index = slot - firstSlot
                let candidate = distance(point, to: spec.frame(index: index, width: width, metrics: metrics))
                if nearest == nil || candidate < nearestDistance || (candidate == nearestDistance && index < nearest!) {
                    nearest = index
                    nearestDistance = candidate
                }
            }
        }
        return nearest
    }

    static func distance(_ point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }

    static func mix(_ a: CGFloat, _ b: CGFloat, _ fraction: CGFloat) -> CGFloat { a + (b - a) * fraction }
}

struct ZoomAnchor {
    let index: Int
    let unitPoint: CGPoint
    let viewportPoint: CGPoint

    init(index: Int, frame: CGRect, documentPoint: CGPoint, viewportPoint: CGPoint) {
        self.index = index
        // A pointer in the inter-item gap is still a valid scale pivot. Clamping
        // its normalized point would move the grid on the very first frame.
        unitPoint = CGPoint(x: (documentPoint.x - frame.minX) / frame.width,
                            y: (documentPoint.y - frame.minY) / frame.height)
        self.viewportPoint = viewportPoint
    }
}

struct ZoomGridSpec: Equatable {
    let level: Int
    var leadingSlots = 0
    var visualAnchorIndex = 0

    static func endingAtNewest(level: Int, count: Int) -> ZoomGridSpec {
        let columns = ZoomGeometry.columns[level]
        // Chronological order runs left-to-right, top-to-bottom. Count slots
        // backwards from the newest asset so a partial row belongs at the top.
        let leading = count > 0 ? (columns - count % columns) % columns : 0
        return ZoomGridSpec(level: level, leadingSlots: leading)
    }

    func frame(index: Int, width: CGFloat, metrics: ZoomMetrics = .demo) -> CGRect {
        ZoomGeometry.frame(index: index, width: width, level: level, leadingSlots: leadingSlots, metrics: metrics)
    }

    func height(count: Int, width: CGFloat, metrics: ZoomMetrics = .demo) -> CGFloat {
        ZoomGeometry.height(count: count, width: width, level: level, leadingSlots: leadingSlots, metrics: metrics)
    }
}

/// Prepared before revealing the incoming grid. Row offsets survive the handoff
/// to NSCollectionView; no horizontal translation is animated back to zero.
struct ZoomPlan {
    let anchor: ZoomAnchor
    let sourceSpec: ZoomGridSpec
    let specs: [ZoomGridSpec]
    let metrics: ZoomMetrics
    let pinsToNewest: Bool

    init(anchor: ZoomAnchor, base: ZoomGridSpec, width: CGFloat, height: CGFloat, count: Int,
         metrics: ZoomMetrics = .demo, endsAtNewest: Bool = false, pinsToNewest: Bool = false) {
        self.anchor = anchor
        self.metrics = metrics
        self.pinsToNewest = pinsToNewest
        sourceSpec = base
        // Prepare every preset against the same photo-local pointer point.
        // The old left/center/right pivot family could send a photo near the
        // right side of a nine-column grid to the leftmost three-column slot.
        // Choose the actual nearest feasible slot, rather than a coarse pivot.
        specs = (0..<4).map { level in
            if level == base.level {
                var spec = base
                spec.visualAnchorIndex = anchor.index
                return spec
            }
            let columns = ZoomGeometry.columns[level]
            let side = ZoomGeometry.side(width: width, columns: columns, metrics: metrics)
            let desiredColumn = min(columns - 1, max(0, Int(((anchor.viewportPoint.x - metrics.left
                - anchor.unitPoint.x * side) / (side + metrics.gap)).rounded())))
            let offset = (desiredColumn - anchor.index % columns + columns) % columns
            let shifted = ZoomGridSpec(level: level, leadingSlots: offset, visualAnchorIndex: anchor.index)
            let desiredY = anchor.viewportPoint.y + (0.5 - anchor.unitPoint.y) * side
            let centerY = shifted.frame(index: anchor.index, width: width, metrics: metrics).midY
            let maxOrigin = max(0, shifted.height(count: count, width: width, metrics: metrics) - height)
            let origin = min(maxOrigin, max(0, centerY - desiredY))
            if endsAtNewest {
                var canonical = ZoomGridSpec.endingAtNewest(level: level, count: count)
                canonical.visualAnchorIndex = anchor.index
                let firstRowBottom = shifted.frame(index: 0, width: width, metrics: metrics).maxY + metrics.gap
                let lastRowTop = shifted.frame(index: max(0, count - 1), width: width, metrics: metrics).minY
                // Plan both library boundaries before the incoming grid becomes
                // visible. Interior focal alignment uses the same pivot family;
                // newest-visible layouts use the same chronological end slots.
                return origin < firstRowBottom || lastRowTop < origin + height ? canonical : shifted
            }
            if offset == 0 || origin >= shifted.frame(index: 0, width: width, metrics: metrics).maxY + metrics.gap {
                return shifted
            }
            // A complete first row must retain the original focal asset too.
            // Choose its real slot in this layout before showing the grid;
            // never exchange the focal identity for a neighbouring photo.
            return ZoomGridSpec(level: level, visualAnchorIndex: anchor.index)
        }
    }

    func focusCenterX(width: CGFloat, position: CGFloat, elasticScale: CGFloat = 1) -> CGFloat {
        let p = ZoomGeometry.clamped(position), lower = Int(floor(p)), upper = min(3, lower + 1)
        let a = specs[lower].frame(index: specs[lower].visualAnchorIndex, width: width, metrics: metrics).midX
        let b = specs[upper].frame(index: specs[upper].visualAnchorIndex, width: width, metrics: metrics).midX
        let side = ZoomGeometry.side(width: width, position: p, metrics: metrics)
        // Fixed-width endpoint columns constrain the normal zoom pivot. An
        // elastic extension has no new endpoint slot: scale it around the same
        // normalized point instead of leaving the photo center stationary.
        return ZoomGeometry.mix(a, b, p - CGFloat(lower))
            + (0.5 - anchor.unitPoint.x) * side * (elasticScale - 1)
    }

    func focusCenter(width: CGFloat, height: CGFloat, count: Int, position: CGFloat,
                     elasticScale: CGFloat = 1) -> CGPoint {
        let p = ZoomGeometry.clamped(position), lower = Int(floor(p)), upper = min(3, lower + 1)
        let side = ZoomGeometry.side(width: width, position: p, metrics: metrics) * elasticScale
        let desiredY = anchor.viewportPoint.y + (0.5 - anchor.unitPoint.y) * side
        func boundedY(_ level: Int) -> CGFloat {
            let spec = specs[level]
            let scale = (side + metrics.gap) /
                (ZoomGeometry.side(width: width, columns: ZoomGeometry.columns[level], metrics: metrics) + metrics.gap)
            let centerY = spec.frame(index: spec.visualAnchorIndex, width: width, metrics: metrics).midY * scale
            let maxOrigin = max(0, spec.height(count: count, width: width, metrics: metrics) * scale - height)
            return centerY - min(maxOrigin, max(0, centerY - desiredY))
        }
        // All grids use one boundary adjustment. Independently clamping each
        // grid's scroll origin separates their focal rows near the library ends.
        return CGPoint(x: focusCenterX(width: width, position: p, elasticScale: elasticScale),
                       y: ZoomGeometry.mix(boundedY(lower), boundedY(upper), p - CGFloat(lower)))
    }
}

/// Size and opacity have the same interactive progress. The focal source row
/// stays opaque; the surrounding pair of grids dissolves with finger motion.
struct ZoomAlphaPresentation {
    private(set) var weights: [CGFloat]

    init(level: Int) {
        weights = (0..<4).map { $0 == level ? 1 : 0 }
    }

    mutating func update(position: CGFloat) {
        let p = ZoomGeometry.clamped(position), lower = Int(floor(p)), upper = min(3, lower + 1)
        let f = p - CGFloat(lower), blend = f * f * (3 - 2 * f)
        weights = (0..<4).map { $0 == lower ? 1 - blend : ($0 == upper ? blend : 0) }
    }

    /// Opaque viewport containers use source-over. These cover opacities yield
    /// the requested linear color weights without a dark flash at 50/50.
    static func coverOpacity(level: Int, weights: [CGFloat]) -> Float {
        let sum = weights[...level].reduce(0, +)
        return sum > 0 ? Float(weights[level] / sum) : 0
    }
}

struct ZoomGesture {
    private static let enlargedResistance: CGFloat = 0.32
    private static let reducedResistance: CGFloat = 5
    let metrics: ZoomMetrics
    let startPosition: CGFloat
    let startSide: CGFloat
    private var inputLogScale: CGFloat = 0
    var position: CGFloat
    private(set) var elasticScale: CGFloat = 1

    init(position: CGFloat, width: CGFloat, elasticScale: CGFloat = 1, metrics: ZoomMetrics = .demo) {
        self.metrics = metrics
        startPosition = position
        self.position = position
        startSide = ZoomGeometry.side(width: width, position: position, metrics: metrics)
        self.elasticScale = elasticScale
        if elasticScale != 1 {
            if elasticScale > 1 {
                let resistance = Self.enlargedResistance
                inputLogScale = resistance * expm1((elasticScale - 1) / resistance)
            } else {
                let compression = min(1 - 0.000001, (1 - elasticScale) * Self.reducedResistance)
                inputLogScale = -compression / (1 - compression)
            }
        }
    }

    mutating func update(magnification: CGFloat, width: CGFloat) {
        guard magnification.isFinite else { return }
        inputLogScale += log(max(0.0001, 1 + magnification)) * 0.5
        let maximum = log(ZoomGeometry.side(width: width, columns: 3, metrics: metrics) / startSide)
        let minimum = log(ZoomGeometry.side(width: width, columns: 9, metrics: metrics) / startSide)
        let bounded = min(maximum, max(minimum, inputLogScale))
        position = inputLogScale >= maximum ? 3 : (inputLogScale <= minimum ? 0 :
            ZoomGeometry.position(forSide: startSide * exp(bounded), width: width, metrics: metrics))
        let excess = inputLogScale - bounded
        if excess >= 0 {
            let resistance = Self.enlargedResistance
            elasticScale = 1 + resistance * log1p(excess / resistance)
        } else {
            // The small-grid endpoint is deliberately much stiffer. It tends
            // toward a finite compression, so prolonged input cannot collapse
            // the grid to zero. This is continuous resistance, not a hard clamp.
            let pull = -excess
            elasticScale = 1 - (pull / (1 + pull)) / Self.reducedResistance
        }
    }

    func destination(cancelled: Bool = false) -> CGFloat {
        cancelled ? startPosition.rounded() : position.rounded()
    }
}

struct ZoomElasticReturn {
    let initialScale: CGFloat
    let start: CFTimeInterval

    func scale(at time: CFTimeInterval) -> CGFloat {
        // Native settings' default zoom stiffness=150, damping ratio=1.
        // A critically damped return avoids adding a decorative oscillation.
        let t = max(0, time - start), omega = sqrt(150.0)
        return 1 + (initialScale - 1) * CGFloat((1 + omega * t) * exp(-omega * t))
    }

    func isFinished(at time: CFTimeInterval) -> Bool { abs(scale(at: time) - 1) < 0.0001 }

    var duration: CFTimeInterval {
        var time: CFTimeInterval = 0
        while !isFinished(at: start + time) { time += 1.0 / 60 }
        return time
    }
}
