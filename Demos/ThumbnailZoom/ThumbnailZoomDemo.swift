import AppKit
import QuartzCore
import ImageIO

// An isolated prototype. It reads image files, never HERMES records/settings or
// the Photos library, and doesn't link any production target.

struct DemoAsset: @unchecked Sendable {
    let url: URL
    let image: CGImage
}

@MainActor
final class PhotoTile: NSView {
    private let artwork = CALayer()
    private let selection = CALayer()
    var bitmap: CGImage? {
        didSet { artwork.contents = bitmap; needsLayout = true }
    }
    var selected = false {
        didSet { selection.isHidden = !selected }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        artwork.contentsGravity = .resizeAspect
        artwork.cornerRadius = 6
        artwork.cornerCurve = .continuous
        artwork.masksToBounds = true
        artwork.minificationFilter = .trilinear
        artwork.magnificationFilter = .linear
        selection.borderWidth = 3
        selection.cornerRadius = 9
        selection.cornerCurve = .continuous
        selection.isHidden = true
        layer?.addSublayer(artwork)
        layer?.addSublayer(selection)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let aspect = bitmap.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1
        let width = min(bounds.width, bounds.height * aspect)
        let height = min(bounds.height, bounds.width / aspect)
        artwork.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                               width: width, height: height)
        selection.frame = artwork.frame.insetBy(dx: -4, dy: -4)
        selection.borderColor = NSColor.controlAccentColor.cgColor
        CATransaction.commit()
    }
}

@MainActor
final class PhotoItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ZoomDemoPhoto")
    override func loadView() { view = PhotoTile(frame: .zero) }
    override var isSelected: Bool {
        didSet { (view as? PhotoTile)?.selected = isSelected }
    }
    override func apply(_ layoutAttributes: NSCollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }
    func configure(_ asset: DemoAsset) {
        let tile = view as! PhotoTile
        tile.bitmap = asset.image
        tile.toolTip = asset.url.lastPathComponent
        tile.setAccessibilityLabel(asset.url.lastPathComponent)
    }
}

/// The collection view retains reusable items for selection, scrolling and the
/// settled layout. During a gesture, ZoomOverlay displays whole-grid dissolves.
@MainActor
final class PointerGridLayout: NSCollectionViewLayout {
    var viewportSize = CGSize(width: 900, height: 600)
    var count = 0
    var spec = ZoomGridSpec(level: 0)

    override var collectionViewContentSize: NSSize {
        NSSize(width: viewportSize.width,
               height: max(viewportSize.height, spec.height(count: count, width: viewportSize.width)))
    }

    override func layoutAttributesForItem(at path: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard path.section == 0, path.item >= 0, path.item < count else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: path)
        attributes.frame = spec.frame(index: path.item, width: viewportSize.width)
        return attributes
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        (0..<count).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
            .filter { $0.frame.intersects(rect) }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        // Ordinary scrolling must not rebuild the layout on every tick.
        newBounds.size != viewportSize
    }
}

@MainActor
final class ZoomCollectionView: NSCollectionView {
    weak var zoom: ZoomController?
    override func accessibilityChildren() -> [Any]? {
        visibleItems().sorted {
            (indexPath(for: $0)?.item ?? 0) < (indexPath(for: $1)?.item ?? 0)
        }.map(\.view)
    }
    override func mouseDown(with event: NSEvent) {
        zoom?.finishForInteraction()
        super.mouseDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        zoom?.finishForInteraction()
        super.scrollWheel(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if ["+", "="].contains(event.charactersIgnoringModifiers ?? "") {
            zoom?.step(1)
        } else if event.charactersIgnoringModifiers == "-" {
            zoom?.step(-1)
        } else if event.keyCode == 53 {
            zoom?.endGesture(cancelled: true)
        } else { super.keyDown(with: event) }
    }
}

@MainActor
final class NativeZoomAnimation: NSAnimation, @unchecked Sendable {
    nonisolated(unsafe) var frameHandler: (@MainActor @Sendable () -> Void)?
    override var currentProgress: NSAnimation.Progress {
        get { super.currentProgress }
        set {
            super.currentProgress = newValue
            // This clock runs with AppKit's nonblocking mode on the main loop.
            let handler = frameHandler
            MainActor.assumeIsolated { handler?() }
        }
    }
    override var runLoopModesForAnimating: [RunLoop.Mode]? { [.common] }
}

@MainActor
final class ZoomController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let collection = ZoomCollectionView()
    let scroll = NSScrollView()
    let layout = PointerGridLayout()
    let overlay = ZoomOverlay(frame: .zero)
    private(set) var assets: [DemoAsset] = []
    private(set) var position: CGFloat = 0
    private(set) var gesture: ZoomGesture?
    private(set) var plan: ZoomPlan?
    private(set) var alpha = ZoomAlphaPresentation(level: 0)
    private(set) var elasticScale: CGFloat = 1
    var anchor: ZoomAnchor? { plan?.anchor }
    private var appKitAnimation: NativeZoomAnimation?
    private var animation: Animation?
    private var elasticReturn: ZoomElasticReturn?
    private var pendingCompletion: (() -> Void)?
    private var applying = false
    private var boundsObserver: NSObjectProtocol?
    private var demoGeneration = 0
    private var handoffGeneration = 0
    private var lastPinchFactor: CGFloat = 1
    var onChange: ((Int, Int, Bool) -> Void)?

    private struct Animation {
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let curve: NSAnimation
    }

    override init() {
        super.init()
        collection.zoom = self
        collection.wantsLayer = true
        collection.backgroundColors = [.windowBackgroundColor]
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.register(PhotoItem.self, forItemWithIdentifier: PhotoItem.identifier)
        scroll.wantsLayer = true
        scroll.contentView.wantsLayer = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.allowsMagnification = false
        scroll.documentView = collection
        scroll.addSubview(overlay, positioned: .above, relativeTo: nil)
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        scroll.addGestureRecognizer(pinch)
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.viewportChanged() }
            }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { assets.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PhotoItem.identifier, for: path) as! PhotoItem
        item.configure(assets[path.item])
        return item
    }

    func setAssets(_ assets: [DemoAsset]) {
        self.assets = assets
        layout.count = assets.count
        overlay.setAssets(assets)
        collection.reloadData()
        applyNative(origin: 0)
        publish()
    }

    private func pointerInDocument() -> CGPoint {
        guard let window = collection.window else {
            return CGPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        }
        let point = collection.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return scroll.contentView.bounds.contains(point) ? point :
            CGPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
    }

    private func nativeAnchor(at point: CGPoint) -> ZoomAnchor? {
        guard let index = ZoomGeometry.nearestIndex(to: point, count: assets.count,
            width: layout.viewportSize.width, spec: layout.spec) else { return nil }
        return ZoomAnchor(index: index, frame: layout.spec.frame(index: index, width: layout.viewportSize.width),
            documentPoint: point, viewportPoint: CGPoint(x: point.x, y: point.y - scroll.contentView.bounds.minY))
    }

    private func preparePlan(at point: CGPoint) {
        // An interrupted dissolve retains the exact prepared grids and pivot.
        // Replacing them midway would make the existing images jump sideways.
        guard plan == nil, let anchor = nativeAnchor(at: point) else { return }
        plan = ZoomPlan(anchor: anchor, base: layout.spec, width: layout.viewportSize.width,
                        height: layout.viewportSize.height, count: assets.count)
        alpha = ZoomAlphaPresentation(level: layout.spec.level)
    }

    func beginGesture(at point: CGPoint) {
        cancelDemoCycle()
        stopAnimation()
        preparePlan(at: point)
        guard plan != nil else { return }
        gesture = ZoomGesture(position: position, width: layout.viewportSize.width, elasticScale: elasticScale)
        applyOverlay()
        publish()
    }

    @objc private func handlePinch(_ recognizer: NSMagnificationGestureRecognizer) {
        if recognizer.state == .began {
            lastPinchFactor = 1
            beginGesture(at: recognizer.location(in: collection))
        }
        if recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended {
            let factor = max(0.01, 1 + recognizer.magnification)
            changeGesture(magnification: factor / lastPinchFactor - 1)
            lastPinchFactor = factor
        }
        if recognizer.state == .ended { endGesture() }
        if recognizer.state == .cancelled || recognizer.state == .failed { endGesture(cancelled: true) }
    }

    func changeGesture(magnification: CGFloat) {
        guard var gesture else { return }
        gesture.update(magnification: magnification, width: layout.viewportSize.width)
        self.gesture = gesture
        position = gesture.position
        elasticScale = gesture.elasticScale
        alpha.update(position: position)
        applyOverlay()
        publish()
    }

    func endGesture(cancelled: Bool = false) {
        guard let gesture else { return }
        self.gesture = nil
        animate(to: gesture.destination(cancelled: cancelled))
    }

    func step(_ direction: Int) {
        let base = animation?.to ?? position.rounded()
        zoom(to: Int(min(3, max(0, base + CGFloat(direction)))))
    }

    func zoom(to level: Int) {
        guard !assets.isEmpty else { return }
        cancelDemoCycle()
        stopAnimation()
        gesture = nil
        preparePlan(at: pointerInDocument())
        animate(to: CGFloat(min(3, max(0, level))))
    }

    private func animate(to target: CGFloat, duration: CFTimeInterval? = nil, completion: (() -> Void)? = nil) {
        stopAnimation()
        guard plan != nil else { return }
        pendingCompletion = completion
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            position = target
            commitPlan()
            return
        }
        animation = Animation(from: position, to: target, start: CACurrentMediaTime(),
                              duration: duration ?? (0.30 + min(0.1, Double(abs(target - position)) * 0.025)),
                              curve: NSAnimation(duration: 1, animationCurve: .easeInOut))
        if elasticScale != 1 { elasticReturn = ZoomElasticReturn(initialScale: elasticScale, start: CACurrentMediaTime()) }
        startAppKitAnimation()
        applyOverlay()
        publish()
    }

    private func startAppKitAnimation() {
        let start = CACurrentMediaTime()
        let duration = max(animation?.duration ?? 0, elasticReturn?.duration ?? 0) + 1.0 / 60
        let clock = NativeZoomAnimation(duration: duration, animationCurve: .linear)
        clock.animationBlockingMode = .nonblocking
        clock.frameRate = 120
        clock.frameHandler = { [weak self, weak clock] in
            guard let self, let clock else { return }
            self.advanceAnimation(at: start + Double(clock.currentProgress) * duration)
        }
        appKitAnimation = clock
        clock.start()
    }

    func advanceAnimation(at timestamp: CFTimeInterval) {
        guard plan != nil else { stopAnimation(); return }
        if let animation {
            let fraction = min(1, max(0, (timestamp - animation.start) / animation.duration))
            animation.curve.currentProgress = Float(fraction)
            let eased = CGFloat(animation.curve.currentValue)
            position = ZoomGeometry.mix(animation.from, animation.to, eased)
            if fraction >= 1 { self.animation = nil; position = animation.to }
        }
        if let elasticReturn {
            elasticScale = elasticReturn.scale(at: timestamp)
            if elasticReturn.isFinished(at: timestamp) { elasticScale = 1; self.elasticReturn = nil }
        }
        alpha.update(position: position)
        applyOverlay()
        if gesture == nil && animation == nil && elasticReturn == nil { commitPlan() }
    }

    private func commitPlan() {
        guard let plan else { return }
        let level = Int(position.rounded())
        position = CGFloat(level)
        let weights: [CGFloat] = (0..<4).map { $0 == level ? 1 : 0 }
        let state = ZoomLayerState(spec: plan.specs[level], position: position,
            width: layout.viewportSize.width, focusCenter: plan.focusCenter(width: layout.viewportSize.width,
                height: layout.viewportSize.height, count: assets.count, position: position), weights: weights)
        // Also render the final frame when an interaction interrupts settling.
        // Keep this frame visible while AppKit prepares its item views.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.render(position: position, plan: plan, weights: weights)
        CATransaction.commit()
        layout.spec = plan.specs[level]
        let completion = pendingCompletion
        stopAnimation()
        gesture = nil
        self.plan = nil
        alpha = ZoomAlphaPresentation(level: level)
        elasticScale = 1
        // The final layer and native item frames have identical scale, row
        // offset, x origin and scroll origin. Handoff has no correction phase.
        applyNative(origin: -state.offset.y, deferHandoff: true)
        publish()
        completion?()
    }

    private func stopAnimation() {
        appKitAnimation?.frameHandler = nil
        appKitAnimation?.stop()
        appKitAnimation = nil
        animation = nil
        elasticReturn = nil
        pendingCompletion = nil
    }

    func finishForInteraction() {
        cancelDemoCycle()
        if plan != nil { commitPlan() }
    }

    func viewportChanged() {
        guard !applying else { return }
        let size = scroll.contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if size == layout.viewportSize {
            normalizeLibraryStartIfNeeded()
            return
        }
        if plan != nil { commitPlan() }
        let top = nativeAnchor(at: CGPoint(x: layout.viewportSize.width / 2,
                                           y: scroll.contentView.bounds.minY + 1))
        layout.viewportSize = size
        let origin = top.map { anchor in
            let frame = layout.spec.frame(index: anchor.index, width: size.width)
            return frame.minY + frame.height * anchor.unitPoint.y - anchor.viewportPoint.y
        } ?? scroll.contentView.bounds.minY
        applyNative(origin: origin)
        normalizeLibraryStartIfNeeded()
    }

    private func normalizeLibraryStartIfNeeded() {
        guard plan == nil, layout.spec.leadingSlots != 0 else { return }
        let firstRowBottom = ZoomGeometry.inset + ZoomGeometry.side(width: layout.viewportSize.width,
            columns: ZoomGeometry.columns[layout.spec.level])
        let origin = scroll.contentView.bounds.minY
        guard origin < firstRowBottom else { return }
        // A shift created deep in the library must not expose blank slots when
        // the user later scrolls back to its beginning. Ordinary native layout
        // takes over here; no per-item movement animation is introduced.
        layout.spec = ZoomGridSpec(level: layout.spec.level)
        applyNative(origin: origin)
    }

    private func applyOverlay() {
        guard let plan, !applying else { return }
        handoffGeneration += 1
        applying = true
        defer { applying = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = scroll.contentView.frame
        overlay.render(position: position, plan: plan, weights: alpha.weights, elasticScale: elasticScale)
        overlay.isHidden = false
        collection.alphaValue = 0
        CATransaction.commit()
    }

    private func applyNative(origin: CGFloat, deferHandoff: Bool = false) {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        handoffGeneration += 1
        let generation = handoffGeneration
        let holdingOverlay = deferHandoff && !overlay.isHidden
        let size = scroll.contentView.bounds.size
        if size.width > 0, size.height > 0 { layout.viewportSize = size }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            collection.setFrameSize(layout.collectionViewContentSize)
            layout.invalidateLayout()
            collection.layoutSubtreeIfNeeded()
            let maxY = max(0, layout.collectionViewContentSize.height - layout.viewportSize.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: min(maxY, max(0, origin))))
            scroll.reflectScrolledClipView(scroll.contentView)
            collection.layoutSubtreeIfNeeded()
            for item in collection.visibleItems() { item.view.layoutSubtreeIfNeeded() }
            if !holdingOverlay {
                overlay.isHidden = true
                collection.alphaValue = 1
            }
        }
        CATransaction.commit()
        if holdingOverlay {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.plan == nil, generation == self.handoffGeneration else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    context.allowsImplicitAnimation = false
                    self.collection.layoutSubtreeIfNeeded()
                    for item in self.collection.visibleItems() { item.view.layoutSubtreeIfNeeded() }
                    self.overlay.isHidden = true
                    self.collection.alphaValue = 1
                }
                CATransaction.commit()
            }
        }
    }

    private func publish() {
        onChange?(ZoomGeometry.columns[Int(position.rounded())], assets.count, plan != nil)
    }

    func cancelDemoCycle() { demoGeneration += 1 }

    func demoCycle(slow: Bool = false) {
        guard !assets.isEmpty else { return }
        cancelDemoCycle()
        let generation = demoGeneration
        let base = Int(position.rounded())
        let levels = slow ? [base == 3 ? 2 : base + 1] : [1, 2, 3, 2, 1, 0]
        func next(_ index: Int) {
            guard generation == demoGeneration, index < levels.count else { return }
            preparePlan(at: CGPoint(x: scroll.contentView.bounds.width * 0.6,
                                    y: scroll.contentView.bounds.minY + scroll.contentView.bounds.height * 0.45))
            animate(to: CGFloat(levels[index]), duration: slow ? 3 : nil) { [weak self] in
                guard self != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { next(index + 1) }
            }
        }
        stopAnimation()
        gesture = nil
        next(0)
    }

    func demoElastic() {
        guard !assets.isEmpty else { return }
        cancelDemoCycle()
        let generation = demoGeneration
        let endpoint: CGFloat = position >= 1.5 ? 3 : 0
        stopAnimation()
        gesture = nil
        preparePlan(at: pointerInDocument())
        animate(to: endpoint) { [weak self] in
            guard let self, generation == self.demoGeneration else { return }
            self.beginGesture(at: self.pointerInDocument())
            self.changeGesture(magnification: endpoint == 3 ? 0.6 : -0.6)
            self.endGesture()
        }
    }
}

@MainActor
final class DemoDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let zoom = ZoomController()
    private var window: NSWindow!
    private let levels = NSSegmentedControl(labels: ["9", "7", "5", "3"], trackingMode: .selectOne,
                                            target: nil, action: nil)
    private let status = NSTextField(labelWithString: "正在读取缩略图…")
    private var preload: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 750),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "缩略图缩放 · Demo"
        window.subtitle = "9 / 7 / 5 / 3 列"
        window.minSize = NSSize(width: 680, height: 420)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("")

        let root = NSView()
        window.contentView = root
        levels.target = self
        levels.action = #selector(selectLevel(_:))
        levels.selectedSegment = 0
        levels.setAccessibilityLabel("每行缩略图数量")
        let minus = NSButton(image: NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "缩小")!,
                             target: self, action: #selector(zoomOut))
        let plus = NSButton(image: NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "放大")!,
                            target: self, action: #selector(zoomIn))
        minus.bezelStyle = .accessoryBarAction
        plus.bezelStyle = .accessoryBarAction
        let cycle = NSButton(title: "演示", target: self, action: #selector(demoCycle))
        cycle.bezelStyle = .rounded
        let slow = NSButton(title: "慢放", target: self, action: #selector(slowDemo))
        slow.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: "双指缩放，围绕指针所在的照片")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)
        let controls = NSStackView(views: [minus, levels, plus, hint, cycle, slow])
        controls.orientation = .horizontal
        controls.spacing = 12
        controls.alignment = .centerY
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        for view in [controls, zoom.scroll, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            controls.heightAnchor.constraint(equalToConstant: 28),
            zoom.scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            zoom.scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            zoom.scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            zoom.scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -28),
            status.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -7)
        ])
        zoom.onChange = { [weak self] columns, count, changing in
            guard let self else { return }
            self.levels.selectedSegment = ZoomGeometry.columns.firstIndex(of: columns) ?? 0
            self.status.stringValue = "每行 \(columns) 张 · \(count) 张图片" + (changing ? " · 缩放中" : "")
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        window.makeFirstResponder(zoom.collection)
        root.layoutSubtreeIfNeeded()
        zoom.viewportChanged()
        loadAssets()
    }

    private func loadAssets() {
        let directory: URL
        if let option = CommandLine.arguments.firstIndex(of: "--images"), CommandLine.arguments.count > option + 1 {
            directory = URL(fileURLWithPath: CommandLine.arguments[option + 1])
        } else {
            directory = Bundle.main.resourceURL!.appendingPathComponent("Previews", isDirectory: true)
        }
        preload = Task { [weak self] in
            let assets = await Task.detached(priority: .userInitiated) {
                Self.readAssets(in: directory)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.zoom.setAssets(assets)
            if assets.isEmpty { self.status.stringValue = "此目录没有可预览的图片" }
        }
    }

    nonisolated private static func readAssets(in directory: URL) -> [DemoAsset] {
        let extensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "webp", "avif", "tiff"]
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        let urls = enumerator.compactMap { $0 as? URL }.filter {
            extensions.contains($0.pathExtension.lowercased()) &&
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.prefix(180)
        return urls.compactMap { url in
            autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { return nil }
                return DemoAsset(url: url, image: image)
            }
        }
    }

    private func createMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Demo")
        appItem.submenu?.addItem(withTitle: "退出缩放 Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn), keyEquivalent: "+").target = self
        viewMenu.addItem(withTitle: "缩小", action: #selector(zoomOut), keyEquivalent: "-").target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "演示缩放", action: #selector(demoCycle), keyEquivalent: "d").target = self
        viewMenu.addItem(withTitle: "慢速查看叠化", action: #selector(slowDemo), keyEquivalent: "D").target = self
        viewMenu.addItem(withTitle: "演示边界回弹", action: #selector(demoElastic), keyEquivalent: "r").target = self
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        NSApplication.shared.mainMenu = menu
    }

    @objc private func selectLevel(_ sender: NSSegmentedControl) { zoom.zoom(to: sender.selectedSegment) }
    @objc private func zoomIn() { zoom.step(1) }
    @objc private func zoomOut() { zoom.step(-1) }
    @objc private func demoCycle() { zoom.demoCycle() }
    @objc private func slowDemo() { zoom.demoCycle(slow: true) }
    @objc private func demoElastic() { zoom.demoElastic() }
    func windowDidResize(_ notification: Notification) { zoom.viewportChanged() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { preload?.cancel() }
}

@main
struct ThumbnailZoomDemo {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") {
            ZoomChecks.run()
            return
        }
        let app = NSApplication.shared
        let delegate = DemoDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
