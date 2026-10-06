import AppKit
import QuartzCore

@MainActor
final class ThumbnailGridLayout: NSCollectionViewLayout {
    var viewportSize = CGSize(width: 900, height: 600)
    var count = 0
    var spec = ZoomGridSpec(level: 2)
    var sectionInset = ThumbnailCollectionStyle.sectionInset
    var metrics: ZoomMetrics {
        ZoomMetrics(top: sectionInset.top, left: sectionInset.left, bottom: sectionInset.bottom,
                    right: sectionInset.right, gap: ThumbnailCollectionStyle.itemSpacing)
    }
    override var collectionViewContentSize: NSSize {
        NSSize(width: viewportSize.width,
               height: max(viewportSize.height, spec.height(count: count, width: viewportSize.width, metrics: metrics)))
    }
    override func layoutAttributesForItem(at path: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard path.section == 0, (0..<count).contains(path.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: path)
        attributes.frame = spec.frame(index: path.item, width: viewportSize.width, metrics: metrics)
        return attributes
    }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let columns = ZoomGeometry.columns[spec.level]
        let pitch = ZoomGeometry.side(width: viewportSize.width, columns: columns, metrics: metrics) + metrics.gap
        let first = min(count, max(0, Int(floor((rect.minY - metrics.top) / pitch)) * columns - spec.leadingSlots))
        let last = min(count, max(first, (Int(ceil((rect.maxY - metrics.top) / pitch)) + 1) * columns - spec.leadingSlots))
        return (first..<last).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
            .filter { $0.frame.intersects(rect) }
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.size != viewportSize
    }
}

@MainActor
private final class ThumbnailZoomAnimation: NSAnimation, @unchecked Sendable {
    nonisolated(unsafe) var frameHandler: (@MainActor @Sendable () -> Void)?
    override var currentProgress: NSAnimation.Progress {
        get { super.currentProgress }
        set {
            super.currentProgress = newValue
            let handler = frameHandler
            MainActor.assumeIsolated { handler?() }
        }
    }
    override var runLoopModesForAnimating: [RunLoop.Mode]? { [.common] }
}

/// AppKit owns gesture delivery, scrolling, reusable cells and the animation
/// clock. The accepted prototype's prepared layouts/opaque focal row own zoom.
@MainActor
final class ThumbnailGridZoomController: NSObject {
    let layout = ThumbnailGridLayout()
    let overlay = ThumbnailZoomOverlay(frame: .zero)
    private weak var collection: NSCollectionView?
    private weak var scroll: NSScrollView?
    private let items: () -> [ThumbnailGridItem]
    private var pinch: NSMagnificationGestureRecognizer?
    private var boundsObserver: NSObjectProtocol?
    private(set) var position: CGFloat = 2
    private(set) var gesture: ZoomGesture?
    private(set) var plan: ZoomPlan?
    private var alpha = ZoomAlphaPresentation(level: 2)
    private(set) var elasticScale: CGFloat = 1
    private var clock: ThumbnailZoomAnimation?
    private var animation: Animation?
    private var elasticReturn: ZoomElasticReturn?
    private var applying = false
    private var handoffGeneration = 0
    private var imageTasks: [Int: Task<Void, Never>] = [:]
    private var imageGeneration = 0
    private var lastPinchFactor: CGFloat = 1
    private var hasShownNewest = false
    private var pendingItems: ItemChange?
    private var lastViewportBounds: CGRect?
    private var lastViewportInsets: NSEdgeInsets?

    private struct ItemChange {
        let followsNewest: Bool
        let anchor: ZoomAnchor?
        let anchorID: String?
        let origin: CGFloat
    }

    private struct Animation {
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let curve: NSAnimation
    }

    init(collection: NSCollectionView, items: @escaping () -> [ThumbnailGridItem], sectionInset: NSEdgeInsets) {
        self.collection = collection
        self.items = items
        super.init()
        layout.sectionInset = sectionInset
        collection.collectionViewLayout = layout
    }

    func attachIfNeeded() {
        guard let collection, let enclosingScroll = collection.enclosingScrollView else { return }
        if scroll !== enclosingScroll {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let pinch { scroll?.removeGestureRecognizer(pinch) }
            scroll = enclosingScroll
            enclosingScroll.allowsMagnification = false
            // Keep the presentation in the scroll document. Native toolbar and
            // scroll-edge effects must see the same content throughout a pinch.
            collection.addSubview(overlay, positioned: .above, relativeTo: nil)
            let recognizer = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            enclosingScroll.addGestureRecognizer(recognizer)
            pinch = recognizer
            enclosingScroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: enclosingScroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.viewportChanged() }
                }
        }
        viewportChanged()
        itemsDidChange()
    }

    func itemsWillChange(count: Int) {
        finishForInteraction()
        cancelImageTasks()
        let origin = scroll?.contentView.documentVisibleRect.minY ?? 0
        let anchor = nativeAnchor(at: CGPoint(x: layout.viewportSize.width / 2, y: origin + 1))
        let previousItems = items()
        let anchorID = anchor.flatMap { previousItems.indices.contains($0.index) ? previousItems[$0.index].id : nil }
        pendingItems = ItemChange(followsNewest: !hasShownNewest || isAtNewest,
                                 anchor: anchor, anchorID: anchorID, origin: origin)
        layout.count = count
        layout.spec = .endingAtNewest(level: Int(position.rounded()), count: count)
        layout.invalidateLayout()
    }

    func itemsDidChange() {
        guard let pendingItems, let scroll, let collection, collection.window != nil,
              scroll.contentView.bounds.width > 0, scroll.contentView.bounds.height > 0,
              collection.numberOfSections > 0,
              collection.numberOfItems(inSection: 0) == layout.count else { return }
        if scroll.contentView.bounds.size != layout.viewportSize {
            viewportChanged()
            return
        }
        var origin = pendingItems.origin
        if pendingItems.followsNewest { origin = maximumOrigin }
        else if let anchor = pendingItems.anchor, let id = pendingItems.anchorID,
                let index = items().firstIndex(where: { $0.id == id }) {
            let frame = layout.spec.frame(index: index, width: layout.viewportSize.width, metrics: layout.metrics)
            origin = frame.minY + frame.height * anchor.unitPoint.y - anchor.viewportPoint.y
        }
        self.pendingItems = nil
        if layout.count > 0 { hasShownNewest = true }
        applyNative(origin: origin)
    }

    func updateSectionInset(_ inset: NSEdgeInsets) {
        guard !ThumbnailCollectionStyle.insetsEqual(layout.sectionInset, inset) else { return }
        finishForInteraction()
        let oldOrigin = scroll?.contentView.documentVisibleRect.minY ?? 0
        let wasAtBottom = isAtNewest
        layout.sectionInset = inset
        applyNative(origin: wasAtBottom ? maximumOrigin : oldOrigin)
    }

    var maximumOrigin: CGFloat { max(0, layout.collectionViewContentSize.height - layout.viewportSize.height) }
    private var isAtNewest: Bool {
        layout.count > 0 && (maximumOrigin == 0 || (scroll?.contentView.documentVisibleRect.minY ?? 0) >= maximumOrigin - 1)
    }

    private func nativeAnchor(at point: CGPoint, origin: CGFloat? = nil) -> ZoomAnchor? {
        let width = layout.viewportSize.width
        guard let index = ZoomGeometry.nearestIndex(to: point, count: layout.count,
            width: width, spec: layout.spec, metrics: layout.metrics) else { return nil }
        return ZoomAnchor(index: index, frame: layout.spec.frame(index: index, width: width, metrics: layout.metrics),
            documentPoint: point, viewportPoint: CGPoint(x: point.x, y: point.y - (origin ?? scroll?.contentView.documentVisibleRect.minY ?? 0)))
    }

    private func pointerInDocument() -> CGPoint {
        guard let collection, let scroll else { return .zero }
        let visible = scroll.contentView.documentVisibleRect
        let center = CGPoint(x: visible.midX, y: visible.midY)
        guard let window = collection.window else { return center }
        let point = collection.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return visible.contains(point) ? point : center
    }

    private func preparePlan(at point: CGPoint) {
        guard plan == nil, let anchor = nativeAnchor(at: point) else { return }
        plan = ZoomPlan(anchor: anchor, base: layout.spec, width: layout.viewportSize.width,
                        height: layout.viewportSize.height, count: layout.count, metrics: layout.metrics,
                        endsAtNewest: true, pinsToNewest: isAtNewest)
        alpha = ZoomAlphaPresentation(level: layout.spec.level)
        overlay.setAssets(makeArtwork())
        prefetchPlanImages()
    }

    func beginGesture(at point: CGPoint) {
        attachIfNeeded()
        stopAnimation()
        preparePlan(at: point)
        guard plan != nil else { return }
        gesture = ZoomGesture(position: position, width: layout.viewportSize.width,
                              elasticScale: elasticScale, metrics: layout.metrics)
        applyOverlay()
    }

    @objc private func handlePinch(_ recognizer: NSMagnificationGestureRecognizer) {
        guard let collection else { return }
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
    }

    func endGesture(cancelled: Bool = false) {
        guard let gesture else { return }
        self.gesture = nil
        animate(to: gesture.destination(cancelled: cancelled))
    }

    func step(_ direction: Int) {
        zoom(to: Int(min(3, max(0, (animation?.to ?? position.rounded()) + CGFloat(direction)))))
    }

    func zoom(to level: Int) {
        attachIfNeeded()
        guard layout.count > 0 else { return }
        stopAnimation()
        gesture = nil
        preparePlan(at: pointerInDocument())
        animate(to: CGFloat(min(3, max(0, level))))
    }

    private func animate(to target: CGFloat) {
        stopAnimation()
        guard plan != nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            position = target
            commitPlan()
            return
        }
        animation = Animation(from: position, to: target, start: CACurrentMediaTime(),
            duration: 0.30 + min(0.1, Double(abs(target - position)) * 0.025),
            curve: NSAnimation(duration: 1, animationCurve: .easeInOut))
        if elasticScale != 1 { elasticReturn = ZoomElasticReturn(initialScale: elasticScale, start: CACurrentMediaTime()) }
        let start = CACurrentMediaTime()
        let duration = max(animation?.duration ?? 0, elasticReturn?.duration ?? 0) + 1.0 / 60
        let clock = ThumbnailZoomAnimation(duration: duration, animationCurve: .linear)
        clock.animationBlockingMode = .nonblocking
        clock.frameRate = 120
        clock.frameHandler = { [weak self, weak clock] in
            guard let self, let clock else { return }
            self.advanceAnimation(at: start + Double(clock.currentProgress) * duration)
        }
        self.clock = clock
        clock.start()
        applyOverlay()
    }

    func advanceAnimation(at timestamp: CFTimeInterval) {
        guard plan != nil else { stopAnimation(); return }
        if let animation {
            let fraction = min(1, max(0, (timestamp - animation.start) / animation.duration))
            animation.curve.currentProgress = Float(fraction)
            position = ZoomGeometry.mix(animation.from, animation.to, CGFloat(animation.curve.currentValue))
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
        let center = plan.focusCenter(width: layout.viewportSize.width, height: layout.viewportSize.height,
                                      count: layout.count, position: position)
        let state = ZoomLayerState(spec: plan.specs[level], position: position,
            width: layout.viewportSize.width, focusCenter: center, weights: weights, metrics: layout.metrics)
        overlay.render(position: position, plan: plan, weights: weights)
        layout.spec = plan.specs[level]
        stopAnimation()
        gesture = nil
        self.plan = nil
        alpha = ZoomAlphaPresentation(level: level)
        elasticScale = 1
        applyNative(origin: -state.offset.y, deferHandoff: true)
    }

    private func stopAnimation() {
        clock?.frameHandler = nil
        clock?.stop()
        clock = nil
        animation = nil
        elasticReturn = nil
    }

    func finishForInteraction() { if plan != nil { commitPlan() } }

    func viewportChanged() {
        guard !applying, let scroll else { return }
        let size = scroll.contentView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let insetsChanged = lastViewportInsets.map { !ThumbnailCollectionStyle.insetsEqual($0, scroll.contentInsets) } ?? false
        if size != layout.viewportSize || insetsChanged {
            // AppKit can adjust the toolbar inset after a page joins a window,
            // even when the clip size is unchanged. Preserve the pre-layout
            // bottom/reading anchor just as for a native window resize.
            let oldOrigin = lastViewportBounds?.minY ?? scroll.contentView.documentVisibleRect.minY
            let wasAtBottom = pendingItems?.followsNewest == true
                || (layout.count > 0 && (maximumOrigin == 0 || oldOrigin >= maximumOrigin - 1))
            if plan != nil { commitPlan() }
            let top = nativeAnchor(at: CGPoint(x: layout.viewportSize.width / 2, y: oldOrigin + 1), origin: oldOrigin)
            layout.viewportSize = size
            let origin = top.map {
                let frame = layout.spec.frame(index: $0.index, width: size.width, metrics: layout.metrics)
                return frame.minY + frame.height * $0.unitPoint.y - $0.viewportPoint.y
            } ?? oldOrigin
            applyNative(origin: wasAtBottom ? maximumOrigin : origin)
        }
        lastViewportBounds = scroll.contentView.documentVisibleRect
        lastViewportInsets = scroll.contentInsets
        itemsDidChange()
        normalizeLibraryEndsIfNeeded()
    }

    private func normalizeLibraryEndsIfNeeded() {
        guard plan == nil, pendingItems == nil, layout.count > 0, let scroll else { return }
        let canonical = ZoomGridSpec.endingAtNewest(level: layout.spec.level, count: layout.count)
        guard layout.spec.leadingSlots != canonical.leadingSlots else { return }
        let firstRowBottom = layout.metrics.top + ZoomGeometry.side(width: layout.viewportSize.width,
            columns: ZoomGeometry.columns[layout.spec.level], metrics: layout.metrics)
        let origin = scroll.contentView.documentVisibleRect.minY
        let last = layout.spec.frame(index: layout.count - 1, width: layout.viewportSize.width, metrics: layout.metrics)
        guard origin < firstRowBottom || last.minY < origin + layout.viewportSize.height else { return }
        let followsNewest = isAtNewest
        layout.spec = canonical
        let newLast = canonical.frame(index: layout.count - 1, width: layout.viewportSize.width, metrics: layout.metrics)
        let newOrigin = origin < firstRowBottom ? origin : origin + newLast.maxY - last.maxY
        applyNative(origin: followsNewest ? maximumOrigin : newOrigin)
    }

    private func applyOverlay() {
        guard let plan, !applying, let scroll, let collection else { return }
        handoffGeneration += 1
        applying = true
        defer { applying = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = scroll.contentView.documentVisibleRect
        if collection.subviews.last !== overlay { collection.addSubview(overlay, positioned: .above, relativeTo: nil) }
        overlay.render(position: position, plan: plan, weights: alpha.weights, elasticScale: elasticScale)
        overlay.isHidden = false
        CATransaction.commit()
    }

    private func applyNative(origin: CGFloat, deferHandoff: Bool = false) {
        guard !applying, let scroll, let collection else { return }
        applying = true
        defer { applying = false }
        handoffGeneration += 1
        let generation = handoffGeneration
        let holdingOverlay = deferHandoff && !overlay.isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            collection.setFrameSize(layout.collectionViewContentSize)
            layout.invalidateLayout()
            collection.layoutSubtreeIfNeeded()
            let documentOrigin = CGPoint(x: 0, y: min(maximumOrigin, max(0, origin)))
            scroll.contentView.scroll(to: scroll.contentView.convert(documentOrigin, from: collection))
            scroll.reflectScrolledClipView(scroll.contentView)
            collection.layoutSubtreeIfNeeded()
            if holdingOverlay {
                overlay.frame = scroll.contentView.documentVisibleRect
                collection.addSubview(overlay, positioned: .above, relativeTo: nil)
                retainHandoffImages()
            }
            for item in collection.visibleItems() { item.view.layoutSubtreeIfNeeded() }
            if !holdingOverlay { overlay.isHidden = true }
        }
        lastViewportBounds = scroll.contentView.documentVisibleRect
        lastViewportInsets = scroll.contentInsets
        CATransaction.commit()
        if holdingOverlay {
            DispatchQueue.main.async { [weak self, weak collection] in
                guard let self, let collection, self.plan == nil, generation == self.handoffGeneration else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                collection.layoutSubtreeIfNeeded()
                self.retainHandoffImages()
                for item in collection.visibleItems() { item.view.layoutSubtreeIfNeeded() }
                self.overlay.isHidden = true
                self.cancelImageTasks()
                CATransaction.commit()
            }
        }
    }

    private func retainHandoffImages() {
        guard let collection else { return }
        let entries = items()
        for case let cell as ThumbnailCollectionItem in collection.visibleItems() {
            guard let path = collection.indexPath(for: cell), entries.indices.contains(path.item),
                  let image = overlay.image(at: path.item) else { continue }
            let item = entries[path.item]
            cell.retainZoomThumbnail(image, for: item.url, contentVersion: item.contentVersion)
        }
    }

    private func makeArtwork() -> [ZoomArtwork] {
        let scale = collection?.window?.backingScaleFactor ?? 2
        return items().enumerated().map { index, item in
            let cell = collection?.item(at: IndexPath(item: index, section: 0)) as? ThumbnailCollectionItem
            let view = cell?.view as? ThumbnailItemView
            let image = cell?.imageView?.image ?? SystemThumbnailProvider.shared.cachedThumbnail(for: item.url,
                pointSize: ThumbnailCollectionStyle.cellSide, scale: scale, contentVersion: item.contentVersion)
            var value = ZoomArtwork(image: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let badge: NSTextField?
            if let label = view?.badgeLabel, !label.isHidden { badge = label }
            else if let text = item.mediaKind.formatBadgeText(for: item.url) {
                let label = ThumbnailBadgeLabel(labelWithString: text)
                label.frame.size = ThumbnailBadgeStyle.size(for: text)
                badge = label
            } else { badge = nil }
            if let badge { value.badge = Self.bitmap(badge); value.badgeSize = badge.bounds.size }
            if let ring = view?.ringView, !ring.isHidden { value.ringColor = ring.layer?.borderColor }
            if let failure = view?.failureLabel, !failure.isHidden {
                value.failure = Self.bitmap(failure); value.failureSize = failure.bounds.size
            }
            return value
        }
    }

    private static func bitmap(_ view: NSView) -> CGImage? {
        guard !view.bounds.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private func prefetchPlanImages() {
        guard let plan else { return }
        let width = layout.viewportSize.width, height = layout.viewportSize.height
        var candidates = Set<Int>()
        for level in 0..<4 {
            let p = CGFloat(level)
            let center = plan.focusCenter(width: width, height: height, count: layout.count, position: p)
            let state = ZoomLayerState(spec: plan.specs[level], position: p, width: width, focusCenter: center,
                weights: [0, 0, 0, 0], metrics: layout.metrics)
            candidates.formUnion(state.visibleIndices(count: layout.count, width: width, height: height, metrics: layout.metrics))
        }
        let entries = items(), generation = imageGeneration
        let pointSize = ZoomGeometry.side(width: width, columns: 3, metrics: layout.metrics)
        let scale = collection?.window?.backingScaleFactor ?? 2
        for index in candidates.sorted(by: { abs($0 - plan.anchor.index) < abs($1 - plan.anchor.index) }) where entries.indices.contains(index) {
            let item = entries[index]
            imageTasks[index] = Task { [weak self] in
                let result = await SystemThumbnailProvider.shared.thumbnail(for: item.url, pointSize: pointSize,
                    scale: scale, contentVersion: item.contentVersion, allowsCachedThumbnail: item.unavailableMessage == nil)
                guard !Task.isCancelled, let self, generation == self.imageGeneration,
                      let image = result.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                self.overlay.replaceImage(image, at: index)
                self.imageTasks[index] = nil
                self.applyOverlay()
            }
        }
    }

    private func cancelImageTasks() {
        imageGeneration += 1
        imageTasks.values.forEach { $0.cancel() }
        imageTasks.removeAll()
    }
}
