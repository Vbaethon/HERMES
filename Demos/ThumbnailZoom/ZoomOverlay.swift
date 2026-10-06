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
         weights: [CGFloat], elasticScale: CGFloat = 1) {
        self.spec = spec
        side = ZoomGeometry.side(width: width, position: position) * elasticScale
        scale = (side + ZoomGeometry.gap) /
            (ZoomGeometry.side(width: width, columns: ZoomGeometry.columns[spec.level]) + ZoomGeometry.gap)
        weight = weights[spec.level]
        opacity = ZoomAlphaPresentation.coverOpacity(level: spec.level, weights: weights)
        let cell = spec.frame(index: spec.visualAnchorIndex, width: width)
        // Align precomputed focal rows through one shared center. At an endpoint,
        // tx is exactly zero; there is no independent recentering animation.
        offset = CGPoint(x: focusCenter.x - cell.midX * scale,
                         y: focusCenter.y - cell.midY * scale)
    }

    func map(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX * scale + offset.x, y: frame.minY * scale + offset.y,
               width: frame.width * scale, height: frame.height * scale)
    }

    func cellFrame(index: Int, width: CGFloat) -> CGRect {
        let frame = spec.frame(index: index, width: width)
        return CGRect(x: frame.midX * scale + offset.x - side / 2,
                      y: frame.midY * scale + offset.y - side / 2, width: side, height: side)
    }
}

@MainActor
final class ZoomOverlay: NSView {
    private struct Grid {
        let viewport: CALayer
        let root: CALayer
        let tiles: [CALayer]
    }
    private var grids: [Grid] = []
    private var assets: [DemoAsset] = []
    private var preparedWidth: CGFloat = 0
    private var preparedSpecs: [ZoomGridSpec] = []
    private var focalTiles: [CALayer] = []
    private let focalViewport = CALayer()
    private(set) var states: [ZoomLayerState] = []
    private(set) var focalFrames: [Int: CGRect] = [:]
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        focalViewport.masksToBounds = true
        layer?.addSublayer(focalViewport)
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setAssets(_ assets: [DemoAsset]) {
        for grid in grids { grid.viewport.removeFromSuperlayer() }
        for tile in focalTiles { tile.removeFromSuperlayer() }
        self.assets = assets
        grids = (0..<4).map { _ in
            let viewport = CALayer()
            viewport.masksToBounds = true
            viewport.allowsGroupOpacity = true
            let root = CALayer()
            root.anchorPoint = .zero
            root.position = .zero
            viewport.addSublayer(root)
            let tiles = assets.map { asset in
                let tile = CALayer()
                tile.contents = asset.image
                tile.contentsGravity = .resizeAspect
                tile.cornerRadius = 6
                tile.cornerCurve = .continuous
                tile.masksToBounds = true
                tile.minificationFilter = .trilinear
                root.addSublayer(tile)
                return tile
            }
            layer?.insertSublayer(viewport, below: focalViewport)
            return Grid(viewport: viewport, root: root, tiles: tiles)
        }
        preparedWidth = 0
        preparedSpecs = []
        focalTiles = assets.map { asset in
            let tile = CALayer()
            tile.contents = asset.image
            tile.contentsGravity = .resizeAspect
            tile.cornerRadius = 6
            tile.cornerCurve = .continuous
            tile.masksToBounds = true
            tile.minificationFilter = .trilinear
            tile.isHidden = true
            focalViewport.addSublayer(tile)
            return tile
        }
    }

    private func artworkFrame(cell: CGRect, image: CGImage) -> CGRect {
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        let width = min(cell.width, cell.height * aspect)
        let height = min(cell.height, cell.width / aspect)
        return CGRect(x: cell.midX - width / 2, y: cell.midY - height / 2, width: width, height: height)
    }

    func render(position: CGFloat, plan: ZoomPlan, weights: [CGFloat], elasticScale: CGFloat = 1) {
        guard !assets.isEmpty, bounds.width > 0 else { return }
        let width = bounds.width, height = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if preparedWidth != width || preparedSpecs != plan.specs {
            for (level, grid) in grids.enumerated() {
                let spec = plan.specs[level]
                grid.root.bounds = CGRect(x: 0, y: 0, width: width, height: spec.height(count: assets.count, width: width))
                for (index, tile) in grid.tiles.enumerated() {
                    tile.frame = artworkFrame(cell: spec.frame(index: index, width: width), image: assets[index].image)
                }
            }
            preparedWidth = width
            preparedSpecs = plan.specs
        }
        let center = plan.focusCenter(width: width, height: height, count: assets.count,
                                      position: position, elasticScale: elasticScale)
        states = plan.specs.map {
            ZoomLayerState(spec: $0, position: position, width: width, focusCenter: center,
                           weights: weights, elasticScale: elasticScale)
        }
        focalFrames = [:]
        // Never promote an incoming row into the opaque foreground. The retained
        // images are exactly those visible in the source row at gesture start.
        let master = states[plan.sourceSpec.level]
        let columns = ZoomGeometry.columns[master.spec.level]
        let rowStart = ((plan.anchor.index + master.spec.leadingSlots) / columns) * columns - master.spec.leadingSlots
        for index in max(0, rowStart)..<min(assets.count, rowStart + columns) {
            focalFrames[index] = master.cellFrame(index: index, width: width)
        }
        for (level, grid) in grids.enumerated() {
            let state = states[level]
            // The opaque, untransformed background guarantees a real dissolve
            // even when the two artwork rectangles have different aspect ratios.
            grid.viewport.frame = bounds
            grid.viewport.backgroundColor = NSColor.windowBackgroundColor.cgColor
            grid.viewport.isHidden = state.weight == 0
            grid.viewport.opacity = state.opacity
            guard state.weight > 0 else { continue }
            grid.root.setAffineTransform(CGAffineTransform(a: state.scale, b: 0, c: 0, d: state.scale,
                                                          tx: state.offset.x, ty: state.offset.y))
            for (index, tile) in grid.tiles.enumerated() {
                let canonical = state.spec.frame(index: index, width: width)
                let localSide = state.side / state.scale
                tile.frame = artworkFrame(cell: CGRect(x: canonical.midX - localSide / 2,
                    y: canonical.midY - localSide / 2, width: localSide, height: localSide), image: assets[index].image)
                let displayed = state.cellFrame(index: index, width: width)
                tile.isHidden = focalFrames[index].map {
                    abs($0.midX - displayed.midX) + abs($0.midY - displayed.midY) < 0.01
                } ?? false
            }
        }
        for (index, tile) in focalTiles.enumerated() {
            tile.isHidden = focalFrames[index] == nil
            tile.opacity = 1
            if let cell = focalFrames[index] {
                tile.frame = artworkFrame(cell: cell, image: assets[index].image).offsetBy(dx: -ZoomGeometry.inset, dy: 0)
            }
        }
        focalViewport.frame = bounds.insetBy(dx: ZoomGeometry.inset, dy: 0)
        CATransaction.commit()
    }

    func sharesBitmap(_ image: CGImage, at index: Int) -> Bool {
        grids.allSatisfy { grid in
            guard grid.tiles.indices.contains(index) else { return false }
            return (grid.tiles[index].contents as AnyObject?) === image
        }
    }

    func focalOpacity(at index: Int) -> Float? {
        guard focalTiles.indices.contains(index), !focalTiles[index].isHidden else { return nil }
        return focalTiles[index].opacity
    }
}
