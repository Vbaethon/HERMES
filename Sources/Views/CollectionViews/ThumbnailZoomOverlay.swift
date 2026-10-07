import AppKit
import QuartzCore

/// Photos uses one 0.2s linear decoration value, retaining unfinished deltas
/// when its target changes. The grid's existing AppKit display link samples it.
struct ThumbnailZoomBadgeAnimation {
    static let duration: TimeInterval = 0.2
    private(set) var target: CGFloat = 1
    private(set) var opacity: CGFloat = 1
    private var changes: [Change] = []
    var isAnimating: Bool { !changes.isEmpty }

    private struct Change {
        let delta: CGFloat
        let start: TimeInterval
    }

    mutating func setSuppressed(_ suppressed: Bool, animated: Bool, at timestamp: TimeInterval) {
        let value: CGFloat = suppressed ? 0 : 1
        if !animated {
            target = value
            opacity = value
            changes.removeAll()
            return
        }
        guard target != value else { return }
        advance(at: timestamp)
        changes.append(Change(delta: target - value, start: timestamp))
        target = value
    }

    mutating func advance(at timestamp: TimeInterval) {
        changes.removeAll { timestamp - $0.start >= Self.duration }
        opacity = min(1, max(0, changes.reduce(target) { value, change in
            let progress = min(1, max(0, (timestamp - change.start) / Self.duration))
            return value + change.delta * CGFloat(1 - progress)
        }))
    }
}

struct ZoomLayerState {
    let spec: ZoomGridSpec
    let scale: CGFloat
    let offset: CGPoint
    let weight: CGFloat
    let opacity: Float
    let side: CGFloat

    init(spec: ZoomGridSpec, position: CGFloat, width: CGFloat, focusCenter: CGPoint,
         weights: [CGFloat], elasticScale: CGFloat = 1, metrics: ZoomMetrics = .demo) {
        self.spec = spec
        side = ZoomGeometry.side(width: width, position: position, metrics: metrics) * elasticScale
        scale = (side + metrics.gap) /
            (ZoomGeometry.side(width: width, columns: ZoomGeometry.columns[spec.level], metrics: metrics) + metrics.gap)
        weight = weights[spec.level]
        opacity = ZoomAlphaPresentation.coverOpacity(level: spec.level, weights: weights)
        let cell = spec.frame(index: spec.visualAnchorIndex, width: width, metrics: metrics)
        offset = CGPoint(x: focusCenter.x - cell.midX * scale, y: focusCenter.y - cell.midY * scale)
    }

    func cellFrame(index: Int, width: CGFloat, metrics: ZoomMetrics = .demo) -> CGRect {
        let frame = spec.frame(index: index, width: width, metrics: metrics)
        return CGRect(x: frame.midX * scale + offset.x - side / 2,
                      y: frame.midY * scale + offset.y - side / 2, width: side, height: side)
    }

    func visibleIndices(count: Int, width: CGFloat, height: CGFloat, metrics: ZoomMetrics) -> Range<Int> {
        let pitch = ZoomGeometry.side(width: width, columns: ZoomGeometry.columns[spec.level], metrics: metrics) + metrics.gap
        let columns = ZoomGeometry.columns[spec.level]
        let firstRow = max(0, Int(floor((-offset.y / scale - metrics.top) / pitch)) - 2)
        let lastRow = max(firstRow, Int(ceil(((height - offset.y) / scale - metrics.top) / pitch)) + 2)
        let first = min(count, max(0, firstRow * columns - spec.leadingSlots))
        let last = min(count, max(first, (lastRow + 1) * columns - spec.leadingSlots))
        return first..<last
    }
}

/// Native cell artwork is retained across all four layouts. Badge pixels come
/// from the existing AppKit labels; zoom doesn't introduce a second badge style.
struct ZoomArtwork {
    var image: CGImage?
    var badge: CGImage?
    var badgeSize: CGSize = .zero
    var ringColor: CGColor?
    var failure: CGImage?
    var failureSize: CGSize = .zero
}

@MainActor
final class ThumbnailZoomOverlay: NSView {
    private final class Tile: CALayer {
        let artwork = CALayer()
        let badge = CALayer()
        let ring = CALayer()
        let failure = CALayer()
        private var imageContents: CGImage?
        private var badgeContents: CGImage?
        private var failureContents: CGImage?
        private var imageAspect: CGFloat = 1

        override init() {
            super.init()
            artwork.contentsGravity = .resizeAspect
            artwork.masksToBounds = true
            artwork.cornerCurve = .continuous
            artwork.minificationFilter = .trilinear
            ring.cornerCurve = .continuous
            addSublayer(artwork)
            addSublayer(ring)
            addSublayer(failure)
        }
        override init(layer: Any) { super.init(layer: layer) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @MainActor func update(_ value: ZoomArtwork, cell: CGRect, scale: CGFloat) {
            if frame != cell { frame = cell }
            // Core Animation retains the bitmap until it changes. Reassigning
            // every tile's contents on each gesture event needlessly rebuilds
            // the same render state, including the AppKit badge snapshots.
            if imageContents !== value.image {
                imageContents = value.image
                artwork.contents = value.image
                imageAspect = value.image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1
            }
            let w = min(cell.width, cell.height * imageAspect), h = min(cell.height, cell.width / imageAspect)
            let photo = CGRect(x: (cell.width - w) / 2, y: (cell.height - h) / 2, width: w, height: h)
            artwork.frame = photo
            artwork.cornerRadius = ThumbnailCollectionStyle.imageCornerRadius / scale
            ring.isHidden = value.image == nil || value.ringColor == nil
            if !ring.isHidden {
                ring.frame = photo.insetBy(dx: -4 / scale, dy: -4 / scale)
                ring.borderColor = value.ringColor
                ring.borderWidth = ThumbnailCollectionStyle.stateRingLineWidth / scale
                ring.cornerRadius = (ThumbnailCollectionStyle.imageCornerRadius + 4) / scale
            }
            // An offscreen asset can have badge text before its thumbnail is
            // available. It must not leave a floating badge on an empty tile.
            badge.isHidden = isHidden || value.image == nil || value.badge == nil
            if badgeContents !== value.badge {
                badgeContents = value.badge
                badge.contents = value.badge
                if let image = value.badge, value.badgeSize.width > 0 {
                    badge.contentsScale = CGFloat(image.width) / value.badgeSize.width
                }
            }
            if value.badge != nil {
                let badgeSize = CGSize(width: value.badgeSize.width / scale, height: value.badgeSize.height / scale)
                badge.frame = CGRect(x: photo.maxX - badgeSize.width - ThumbnailBadgeStyle.inset / scale,
                                 y: photo.maxY - badgeSize.height - ThumbnailBadgeStyle.inset / scale,
                                 width: badgeSize.width, height: badgeSize.height)
                .offsetBy(dx: cell.minX, dy: cell.minY)
            }
            failure.isHidden = value.failure == nil
            if failureContents !== value.failure {
                failureContents = value.failure
                failure.contents = value.failure
                if let image = value.failure, value.failureSize.width > 0 {
                    failure.contentsScale = CGFloat(image.width) / value.failureSize.width
                }
            }
            if !failure.isHidden {
                failure.frame = CGRect(x: photo.minX + 4 / scale, y: photo.minY + 4 / scale,
                                   width: min(value.failureSize.width / scale, max(0, photo.width - 8 / scale)),
                                   height: value.failureSize.height / scale)
            }
        }

        func setPresentationHidden(_ hidden: Bool) {
            isHidden = hidden
            badge.isHidden = hidden || imageContents == nil || badgeContents == nil
        }
    }

    private final class Grid {
        let viewport = CALayer()
        let root = CALayer()
        let decorations = CALayer()
        var tiles: [Int: Tile] = [:]
        private var visibleRange = 0..<0
        private var reusableTiles: [Tile] = []
        init() {
            viewport.masksToBounds = true
            viewport.allowsGroupOpacity = true
            root.anchorPoint = .zero
            root.position = .zero
            decorations.anchorPoint = .zero
            decorations.position = .zero
            root.addSublayer(decorations)
            viewport.addSublayer(root)
        }
        func tile(at index: Int) -> Tile {
            if let tile = tiles[index] { return tile }
            let tile = reusableTiles.popLast() ?? Tile()
            root.insertSublayer(tile, below: decorations)
            decorations.addSublayer(tile.badge)
            tiles[index] = tile
            return tile
        }
        func retain(_ indices: Range<Int>) {
            guard indices != visibleRange else { return }
            for index in visibleRange where !indices.contains(index) {
                if let tile = tiles.removeValue(forKey: index) {
                    tile.removeFromSuperlayer()
                    tile.badge.removeFromSuperlayer()
                    reusableTiles.append(tile)
                }
            }
            visibleRange = indices
        }
    }

    private let grids = (0..<4).map { _ in Grid() }
    private let focalGrid = Grid()
    private var assets: [Int: ZoomArtwork] = [:]
    private var assetCount = 0
    private var resolvedBackground: CGColor?
    /// The gallery fill behind any transparent collection/scroll backgrounds.
    var backgroundColor: NSColor = .windowBackgroundColor {
        didSet {
            guard backgroundColor != oldValue else { return }
            resolvedBackground = nil
            updateBackgroundIfNeeded()
        }
    }
    private(set) var states: [ZoomLayerState] = []
    private(set) var focalFrames: [Int: CGRect] = [:]
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for grid in grids { layer?.addSublayer(grid.viewport) }
        layer?.addSublayer(focalGrid.viewport)
        isHidden = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolvedBackground = nil
        updateBackgroundIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolvedBackground = nil
        updateBackgroundIfNeeded()
    }

    private func updateBackgroundIfNeeded() {
        guard resolvedBackground == nil else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedBackground = backgroundColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = resolvedBackground
        for grid in grids { grid.viewport.backgroundColor = resolvedBackground }
        CATransaction.commit()
    }

    func setAssets(_ values: [ZoomArtwork]) {
        setAssets(Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.offset, $0.element) }),
                  count: values.count)
    }
    func setAssets(_ values: [Int: ZoomArtwork], count: Int) {
        assetCount = max(0, count)
        assets = values
    }
    func image(at index: Int) -> CGImage? { assets[index]?.image }
    func replaceImage(_ image: CGImage, at index: Int) {
        guard (0..<assetCount).contains(index) else { return }
        assets[index, default: ZoomArtwork()].image = image
    }

    func setZoomBadgeOpacity(_ opacity: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let value = Float(min(1, max(0, opacity)))
        for grid in grids + [focalGrid] {
            if grid.decorations.opacity != value { grid.decorations.opacity = value }
        }
        CATransaction.commit()
    }

    func render(position: CGFloat, plan: ZoomPlan, weights: [CGFloat], elasticScale: CGFloat = 1) {
        guard assetCount > 0, bounds.width > 0 else { return }
        updateBackgroundIfNeeded()
        let width = bounds.width, height = bounds.height, metrics = plan.metrics
        let center = plan.focusCenter(width: width, height: height, count: assetCount,
                                      position: position, elasticScale: elasticScale)
        states = plan.specs.map {
            ZoomLayerState(spec: $0, position: position, width: width, focusCenter: center,
                           weights: weights, elasticScale: elasticScale, metrics: metrics)
        }
        focalFrames.removeAll(keepingCapacity: true)
        let master = states[plan.sourceSpec.level]
        let columns = ZoomGeometry.columns[master.spec.level]
        let rowStart = ((plan.anchor.index + master.spec.leadingSlots) / columns) * columns - master.spec.leadingSlots
        let focalRange = max(0, rowStart)..<min(assetCount, rowStart + columns)
        for index in focalRange {
            focalFrames[index] = master.cellFrame(index: index, width: width, metrics: metrics)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (level, grid) in grids.enumerated() {
            let state = states[level]
            grid.viewport.frame = bounds
            grid.viewport.isHidden = state.weight == 0
            grid.viewport.opacity = state.opacity
            guard state.weight > 0 else { continue }
            grid.root.setAffineTransform(CGAffineTransform(a: state.scale, b: 0, c: 0, d: state.scale,
                                                          tx: state.offset.x, ty: state.offset.y))
            let visible = state.visibleIndices(count: assetCount, width: width, height: height, metrics: metrics)
            grid.retain(visible)
            for index in visible {
                let tile = grid.tile(at: index)
                let canonical = state.spec.frame(index: index, width: width, metrics: metrics)
                let side = state.side / state.scale
                tile.update(assets[index] ?? ZoomArtwork(), cell: CGRect(x: canonical.midX - side / 2, y: canonical.midY - side / 2,
                                                       width: side, height: side), scale: state.scale)
                let displayed = state.cellFrame(index: index, width: width, metrics: metrics)
                tile.setPresentationHidden(focalFrames[index].map {
                    abs($0.midX - displayed.midX) + abs($0.midY - displayed.midY) < 0.01
                } ?? false)
            }
        }
        // Every zoom grid clips at the same actual viewport edge. A fixed
        // layout inset here cuts a moving focal photo with a white rectangle.
        focalGrid.viewport.frame = bounds
        focalGrid.retain(focalRange)
        for (index, cell) in focalFrames {
            let tile = focalGrid.tile(at: index)
            tile.setPresentationHidden(false)
            tile.opacity = 1
            tile.update(assets[index] ?? ZoomArtwork(), cell: cell, scale: 1)
        }
        CATransaction.commit()
    }

    func focalOpacity(at index: Int) -> Float? { focalGrid.tiles[index]?.opacity }
    var retainedTileCount: Int { grids.reduce(focalGrid.tiles.count) { $0 + $1.tiles.count } }
}
