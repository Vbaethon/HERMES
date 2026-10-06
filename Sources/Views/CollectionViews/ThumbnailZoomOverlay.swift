import AppKit
import QuartzCore

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

        override init() {
            super.init()
            artwork.contentsGravity = .resizeAspect
            artwork.masksToBounds = true
            artwork.cornerCurve = .continuous
            artwork.minificationFilter = .trilinear
            ring.cornerCurve = .continuous
            addSublayer(artwork)
            addSublayer(ring)
            addSublayer(badge)
            addSublayer(failure)
        }
        override init(layer: Any) { super.init(layer: layer) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @MainActor func update(_ value: ZoomArtwork, cell: CGRect, scale: CGFloat) {
            frame = cell
            let aspect = value.image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1
            let w = min(cell.width, cell.height * aspect), h = min(cell.height, cell.width / aspect)
            let photo = CGRect(x: (cell.width - w) / 2, y: (cell.height - h) / 2, width: w, height: h)
            artwork.frame = photo
            artwork.contents = value.image
            artwork.cornerRadius = ThumbnailCollectionStyle.imageCornerRadius / scale
            ring.isHidden = value.ringColor == nil
            ring.frame = photo.insetBy(dx: -4 / scale, dy: -4 / scale)
            ring.borderColor = value.ringColor
            ring.borderWidth = ThumbnailCollectionStyle.stateRingLineWidth / scale
            ring.cornerRadius = (ThumbnailCollectionStyle.imageCornerRadius + 4) / scale
            badge.isHidden = value.badge == nil
            badge.contents = value.badge
            let badgeSize = CGSize(width: value.badgeSize.width / scale, height: value.badgeSize.height / scale)
            badge.frame = CGRect(x: photo.maxX - badgeSize.width - ThumbnailBadgeStyle.inset / scale,
                                 y: photo.maxY - badgeSize.height - ThumbnailBadgeStyle.inset / scale,
                                 width: badgeSize.width, height: badgeSize.height)
            failure.isHidden = value.failure == nil
            failure.contents = value.failure
            failure.frame = CGRect(x: photo.minX + 4 / scale, y: photo.minY + 4 / scale,
                                   width: min(value.failureSize.width / scale, max(0, photo.width - 8 / scale)),
                                   height: value.failureSize.height / scale)
        }
    }

    private final class Grid {
        let viewport = CALayer()
        let root = CALayer()
        var tiles: [Int: Tile] = [:]
        init() {
            viewport.masksToBounds = true
            viewport.allowsGroupOpacity = true
            root.anchorPoint = .zero
            root.position = .zero
            viewport.addSublayer(root)
        }
        func tile(at index: Int) -> Tile {
            if let tile = tiles[index] { return tile }
            let tile = Tile()
            root.addSublayer(tile)
            tiles[index] = tile
            return tile
        }
        func retain(_ indices: Set<Int>) {
            for index in Array(tiles.keys) where !indices.contains(index) {
                tiles.removeValue(forKey: index)?.removeFromSuperlayer()
            }
        }
    }

    private let grids = (0..<4).map { _ in Grid() }
    private let focalGrid = Grid()
    private var assets: [ZoomArtwork] = []
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

    func setAssets(_ values: [ZoomArtwork]) { assets = values }
    func image(at index: Int) -> CGImage? { assets.indices.contains(index) ? assets[index].image : nil }
    func replaceImage(_ image: CGImage, at index: Int) {
        guard assets.indices.contains(index) else { return }
        assets[index].image = image
    }

    func render(position: CGFloat, plan: ZoomPlan, weights: [CGFloat], elasticScale: CGFloat = 1) {
        guard !assets.isEmpty, bounds.width > 0 else { return }
        let width = bounds.width, height = bounds.height, metrics = plan.metrics
        let center = plan.focusCenter(width: width, height: height, count: assets.count,
                                      position: position, elasticScale: elasticScale)
        states = plan.specs.map {
            ZoomLayerState(spec: $0, position: position, width: width, focusCenter: center,
                           weights: weights, elasticScale: elasticScale, metrics: metrics)
        }
        focalFrames.removeAll(keepingCapacity: true)
        let master = states[plan.sourceSpec.level]
        let columns = ZoomGeometry.columns[master.spec.level]
        let rowStart = ((plan.anchor.index + master.spec.leadingSlots) / columns) * columns - master.spec.leadingSlots
        for index in max(0, rowStart)..<min(assets.count, rowStart + columns) {
            focalFrames[index] = master.cellFrame(index: index, width: width, metrics: metrics)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (level, grid) in grids.enumerated() {
            let state = states[level]
            grid.viewport.frame = bounds
            grid.viewport.backgroundColor = NSColor.windowBackgroundColor.cgColor
            grid.viewport.isHidden = state.weight == 0
            grid.viewport.opacity = state.opacity
            guard state.weight > 0 else { continue }
            grid.root.setAffineTransform(CGAffineTransform(a: state.scale, b: 0, c: 0, d: state.scale,
                                                          tx: state.offset.x, ty: state.offset.y))
            let visible = state.visibleIndices(count: assets.count, width: width, height: height, metrics: metrics)
            grid.retain(Set(visible))
            for index in visible {
                let tile = grid.tile(at: index)
                let canonical = state.spec.frame(index: index, width: width, metrics: metrics)
                let side = state.side / state.scale
                tile.update(assets[index], cell: CGRect(x: canonical.midX - side / 2, y: canonical.midY - side / 2,
                                                       width: side, height: side), scale: state.scale)
                let displayed = state.cellFrame(index: index, width: width, metrics: metrics)
                tile.isHidden = focalFrames[index].map {
                    abs($0.midX - displayed.midX) + abs($0.midY - displayed.midY) < 0.01
                } ?? false
            }
        }
        focalGrid.viewport.frame = CGRect(x: metrics.left, y: 0,
            width: max(0, width - metrics.left - metrics.right), height: height)
        focalGrid.retain(Set(focalFrames.keys))
        for (index, cell) in focalFrames {
            let tile = focalGrid.tile(at: index)
            tile.isHidden = false
            tile.opacity = 1
            tile.update(assets[index], cell: cell.offsetBy(dx: -metrics.left, dy: 0), scale: 1)
        }
        CATransaction.commit()
    }

    func focalOpacity(at index: Int) -> Float? { focalGrid.tiles[index]?.opacity }
    var retainedTileCount: Int { grids.reduce(focalGrid.tiles.count) { $0 + $1.tiles.count } }
}
