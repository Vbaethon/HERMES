import AppKit
import QuartzCore

@MainActor
final class ThumbnailGridLayout: NSCollectionViewLayout {
    let arrangement: ThumbnailGridArrangementController

    init(flow: ThumbnailGridArrangementController.Flow) {
        arrangement = ThumbnailGridArrangementController(flow: flow)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var viewportSize: CGSize { arrangement.viewportSize }
    var count: Int { arrangement.count }
    var spec: ZoomGridSpec { arrangement.spec }
    var sectionInset = ThumbnailCollectionStyle.sectionInset
    private var previousGeometry: (spec: ZoomGridSpec, count: Int, width: CGFloat, metrics: ZoomMetrics)?
    var metrics: ZoomMetrics {
        ZoomMetrics(top: sectionInset.top, left: sectionInset.left, bottom: sectionInset.bottom,
                    right: sectionInset.right, gap: ThumbnailCollectionStyle.itemSpacing)
    }
    override var collectionViewContentSize: NSSize {
        arrangement.contentSize
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

    func beginItemChange() {
        previousGeometry = (spec, count, viewportSize.width, metrics)
    }

    override func initialLayoutAttributesForAppearingItem(at path: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let attributes = layoutAttributesForItem(at: path) else { return nil }
        attributes.alpha = 0
        return attributes
    }

    override func finalLayoutAttributesForDisappearingItem(at path: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let previousGeometry, path.section == 0, (0..<previousGeometry.count).contains(path.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: path)
        // Fade in place while AppKit moves surviving items into their new slots.
        attributes.frame = previousGeometry.spec.frame(index: path.item, width: previousGeometry.width,
                                                       metrics: previousGeometry.metrics)
        attributes.alpha = 0
        return attributes
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        previousGeometry = nil
    }
}

/// AppKit owns gesture delivery, scrolling, reusable cells and the animation
/// clock. Prepared grids share one transform and crossfade rule for every item.
@MainActor
final class ThumbnailGridZoomController: NSObject {
    let layout: ThumbnailGridLayout
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
    private var displayLink: CADisplayLink?
    private var animation: Animation?
    private var elasticReturn: ZoomElasticReturn?
    private var applying = false
    private var handoffGeneration = 0
    private var imageTasks: [Int: Task<Void, Never>] = [:]
    private var imageGeneration = 0
    private var needsDisplay = false
    private var badgeBitmaps: [String: (image: CGImage?, size: CGSize)] = [:]
    private var badgeBackingScale: CGFloat = 0
    private var badgeAnimation = ThumbnailZoomBadgeAnimation()
    var badgesSuppressed: Bool { badgeAnimation.target == 0 }
    var badgeOpacity: CGFloat { badgeAnimation.opacity }
    private(set) var cellsSuppressed = false
    private var lastMagnification: CGFloat = 0
    private var lastViewportBounds: CGRect?
    private var lastViewportInsets: NSEdgeInsets?

    private struct Animation {
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let curve: NSAnimation
    }

    @MainActor private final class DisplayTarget: NSObject {
        weak var owner: ThumbnailGridZoomController?
        init(owner: ThumbnailGridZoomController) { self.owner = owner }
        @objc func displayFrame(_ displayLink: CADisplayLink) {
            guard let owner else { displayLink.invalidate(); return }
            owner.displayFrame(at: displayLink.targetTimestamp)
        }
    }

    isolated deinit {
        displayLink?.invalidate()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        imageTasks.values.forEach { $0.cancel() }
    }

    init(collection: NSCollectionView, items: @escaping () -> [ThumbnailGridItem], sectionInset: NSEdgeInsets,
         flow: ThumbnailGridArrangementController.Flow) {
        layout = ThumbnailGridLayout(flow: flow)
        self.collection = collection
        self.items = items
        super.init()
        layout.sectionInset = sectionInset
        _ = layout.arrangement.updateViewport(size: layout.viewportSize, metrics: layout.metrics, origin: 0)
        collection.collectionViewLayout = layout
    }

    func attachIfNeeded() {
        guard let collection, let enclosingScroll = collection.enclosingScrollView else { return }
        if scroll !== enclosingScroll {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let pinch { scroll?.removeGestureRecognizer(pinch) }
            scroll = enclosingScroll
            enclosingScroll.allowsMagnification = false
            // NSCollectionView owns the ordering of its reusable cell views.
            // Keep the temporary presentation above the document in AppKit's
            // clip view, where a newly inserted cell cannot cover it.
            enclosingScroll.contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
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

    func itemsWillChange(ids: [String]) {
        finishForInteraction()
        if cellsSuppressed {
            retainHandoffImages()
            applyNative(origin: scroll?.contentView.documentVisibleRect.minY ?? 0)
        }
        cancelImageTasks()
        let origin = scroll?.contentView.documentVisibleRect.minY ?? 0
        if let rebasedOrigin = layout.arrangement.prepareSnapshot(ids, origin: origin) {
            applyNative(origin: rebasedOrigin, layoutBeforeScrolling: false)
            CATransaction.flush()
        }
        layout.beginItemChange()
        layout.arrangement.beginPreparedSnapshot()
        // The diffable transaction invalidates the layout after it captures the
        // old items. Invalidating here would evict the old final index before
        // AppKit can remap that still-visible photo to its surviving index.
    }

    func itemsDidChange(snapshotCompleted: Bool = false) {
        if snapshotCompleted { layout.arrangement.snapshotDidComplete() }
        guard let scroll, let collection, collection.window != nil,
              scroll.contentView.bounds.width > 0, scroll.contentView.bounds.height > 0,
              collection.numberOfSections > 0,
              collection.numberOfItems(inSection: 0) == layout.count else { return }
        if scroll.contentView.bounds.size != layout.viewportSize {
            viewportChanged()
            return
        }
        guard let origin = layout.arrangement.finishSnapshot() else { return }
        // The controller has already resolved row-space and viewport together.
        // Install that viewport before native cell layout at every handoff.
        applyNative(origin: origin, layoutBeforeScrolling: false)
    }

    func updateSectionInset(_ inset: NSEdgeInsets) {
        guard !ThumbnailCollectionStyle.insetsEqual(layout.sectionInset, inset) else { return }
        finishForInteraction()
        let oldOrigin = scroll?.contentView.documentVisibleRect.minY ?? 0
        layout.sectionInset = inset
        let origin = layout.arrangement.updateViewport(size: layout.viewportSize, metrics: layout.metrics, origin: oldOrigin)
        applyNative(origin: origin)
    }

    var maximumOrigin: CGFloat { layout.arrangement.maximumOrigin }

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
        cancelImageTasks()
        plan = ZoomPlan(anchor: anchor, base: layout.spec, width: layout.viewportSize.width,
                        height: layout.viewportSize.height, count: layout.count, metrics: layout.metrics)
        alpha = ZoomAlphaPresentation(level: layout.spec.level)
        overlay.setAssets(makeArtwork(), count: layout.count)
        overlay.setZoomBadgeOpacity(badgeOpacity)
        prefetchPlanImages()
    }

    func prepareBadgeAppearance(for cell: ThumbnailCollectionItem) {
        cell.setZoomBadgeOpacity(badgeOpacity)
        cell.setZoomPresentationSuppressed(cellsSuppressed)
    }

    private func setCellsSuppressed(_ suppressed: Bool) {
        guard cellsSuppressed != suppressed else { return }
        cellsSuppressed = suppressed
        for case let cell as ThumbnailCollectionItem in collection?.visibleItems() ?? [] {
            cell.setZoomPresentationSuppressed(suppressed)
        }
    }

    private func updateBadgeVisibility() {
        let destination = animation?.to ?? position.rounded()
        let side = ZoomGeometry.side(width: layout.viewportSize.width, position: position, metrics: layout.metrics) * elasticScale
        let settledSide = ZoomGeometry.side(width: layout.viewportSize.width, position: destination, metrics: layout.metrics)
        // A released, unscaled layout can reveal metadata before the held
        // images hand off. An active gesture keeps it hidden even at a preset.
        let suppressed = plan != nil && (gesture != nil || abs(side / settledSide - 1) >= 0.001)
        let previousOpacity = badgeOpacity
        badgeAnimation.setSuppressed(suppressed,
            animated: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, at: CACurrentMediaTime())
        if badgeOpacity != previousOpacity { applyBadgeOpacity() }
        if badgeAnimation.isAnimating { resumeDisplayLink() }
    }

    private func applyBadgeOpacity() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.setZoomBadgeOpacity(badgeOpacity)
        for case let cell as ThumbnailCollectionItem in collection?.visibleItems() ?? [] {
            cell.setZoomBadgeOpacity(badgeOpacity)
        }
        CATransaction.commit()
    }

    func beginGesture(at point: CGPoint) {
        attachIfNeeded()
        stopAnimation()
        preparePlan(at: point)
        guard plan != nil else { return }
        gesture = ZoomGesture(position: position, width: layout.viewportSize.width,
                              elasticScale: elasticScale, metrics: layout.metrics)
        updateBadgeVisibility()
        applyOverlay()
    }

    @objc private func handlePinch(_ recognizer: NSMagnificationGestureRecognizer) {
        guard collection != nil else { return }
        if recognizer.state == .began {
            lastMagnification = 0
            // A trackpad gesture's location is recognizer-specific. Photos-like
            // zoom uses the visible mouse pointer, just like keyboard zoom.
            beginGesture(at: pointerInDocument())
        }
        if recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended {
            let magnification = recognizer.magnification
            changeGesture(magnification: magnification - lastMagnification)
            lastMagnification = magnification
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
        requestFrame()
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
            duration: 0.30,
            curve: NSAnimation(duration: 1, animationCurve: .easeInOut))
        if elasticScale != 1 { elasticReturn = ZoomElasticReturn(initialScale: elasticScale, start: CACurrentMediaTime()) }
        updateBadgeVisibility()
        applyOverlay()
        requestFrame()
    }

    private func requestFrame() {
        guard plan != nil else { return }
        needsDisplay = true
        resumeDisplayLink()
    }

    private func resumeDisplayLink() {
        guard let collection else { return }
        if displayLink == nil {
            displayLink = collection.displayLink(target: DisplayTarget(owner: self),
                selector: #selector(DisplayTarget.displayFrame(_:)))
            displayLink?.add(to: .main, forMode: .common)
        }
        displayLink?.isPaused = false
    }

    // Gesture events and bitmap completions update state immediately; AppKit's
    // display link presents their latest state once per screen refresh. The
    // same clock advances settlement, including while menus track events.
    func displayFrame(at timestamp: CFTimeInterval) {
        let presentsZoom = plan != nil && (needsDisplay || animation != nil || elasticReturn != nil)
        if presentsZoom {
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
            updateBadgeVisibility()
        }
        if badgeAnimation.isAnimating {
            let previousOpacity = badgeOpacity
            badgeAnimation.advance(at: timestamp)
            if badgeOpacity != previousOpacity { applyBadgeOpacity() }
        }
        // Badge-only frames change four decoration parents and native labels;
        // they never rebuild the prepared image geometry or start new loads.
        if presentsZoom {
            applyOverlay()
            if gesture == nil && animation == nil && elasticReturn == nil { commitPlan() }
        }
        if plan == nil && !badgeAnimation.isAnimating { stopDisplayLink() }
        else if !needsDisplay && animation == nil && elasticReturn == nil && !badgeAnimation.isAnimating {
            displayLink?.isPaused = true
        }
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
        layout.arrangement.commitZoom(plan.specs[level], origin: -state.offset.y)
        stopAnimation()
        gesture = nil
        self.plan = nil
        alpha = ZoomAlphaPresentation(level: level)
        elasticScale = 1
        updateBadgeVisibility()
        applyNative(origin: -state.offset.y, deferHandoff: true)
    }

    private func stopAnimation() {
        animation = nil
        elasticReturn = nil
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        needsDisplay = false
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
            if plan != nil { commitPlan() }
            let origin = layout.arrangement.updateViewport(size: size, metrics: layout.metrics, origin: oldOrigin)
            applyNative(origin: origin)
        }
        lastViewportBounds = scroll.contentView.documentVisibleRect
        lastViewportInsets = scroll.contentInsets
        itemsDidChange()
    }

    private func applyOverlay() {
        guard let plan, !applying, let scroll, collection != nil else { return }
        needsDisplay = false
        handoffGeneration += 1
        applying = true
        defer { applying = false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if overlay.frame != scroll.contentView.bounds { overlay.frame = scroll.contentView.bounds }
        if overlay.bounds.origin != .zero { overlay.bounds.origin = .zero }
        if scroll.contentView.subviews.last !== overlay {
            scroll.contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.render(position: position, plan: plan, weights: alpha.weights, elasticScale: elasticScale)
        setCellsSuppressed(true)
        overlay.isHidden = false
        CATransaction.commit()
    }

    private func applyNative(origin: CGFloat, deferHandoff: Bool = false, layoutBeforeScrolling: Bool = true) {
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
            // Install the target viewport before asking AppKit for its cells.
            // Laying out at the old scroll origin first creates a second set
            // of offscreen cells during the same native handoff.
            // Startup/toolbar sizing still needs AppKit's initial layout pass.
            if !deferHandoff && layoutBeforeScrolling { collection.layoutSubtreeIfNeeded() }
            let documentOrigin = CGPoint(x: 0, y: min(maximumOrigin, max(0, origin)))
            scroll.contentView.scroll(to: scroll.contentView.convert(documentOrigin, from: collection))
            scroll.reflectScrolledClipView(scroll.contentView)
            collection.layoutSubtreeIfNeeded()
            if holdingOverlay {
                overlay.frame = scroll.contentView.bounds
                overlay.bounds.origin = .zero
                scroll.contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
                retainHandoffImages()
            }
            // AppKit batches subtree layout for the collection. Flushing each
            // cell separately repeatedly runs the window's layout machinery.
            collection.layoutSubtreeIfNeeded()
            if !holdingOverlay {
                setCellsSuppressed(false)
                overlay.isHidden = true
            }
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
                collection.layoutSubtreeIfNeeded()
                self.setCellsSuppressed(false)
                self.overlay.isHidden = true
                self.cancelImageTasks()
                // Reusable cells inherit the same reveal phase as the held
                // overlay; handoff must not restart a second opacity timeline.
                self.applyBadgeOpacity()
                CATransaction.commit()
            }
        } else if plan == nil {
            // Reduce Motion can commit without ever revealing the overlay.
            // It needs the same prefetch/display-clock cleanup as a handoff.
            cancelImageTasks()
            updateBadgeVisibility()
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

    private func planImageCandidates() -> Set<Int> {
        guard let plan else { return [] }
        let width = layout.viewportSize.width, height = layout.viewportSize.height
        var candidates = Set<Int>()
        for level in 0..<4 {
            let p = CGFloat(level)
            let center = plan.focusCenter(width: width, height: height, count: layout.count, position: p)
            let state = ZoomLayerState(spec: plan.specs[level], position: p, width: width, focusCenter: center,
                weights: [0, 0, 0, 0], metrics: layout.metrics)
            candidates.formUnion(state.visibleIndices(count: layout.count, width: width, height: height, metrics: layout.metrics))
        }
        // The strongly resisted nine-column overshoot still reveals a few more
        // rows in tall windows. Include its full asymptotic range up front.
        let minimumScale = ZoomGesture.minimumElasticScale
        let reducedCenter = plan.focusCenter(width: width, height: height, count: layout.count,
                                            position: 0, elasticScale: minimumScale)
        let reduced = ZoomLayerState(spec: plan.specs[0], position: 0, width: width,
            focusCenter: reducedCenter, weights: [0, 0, 0, 0], elasticScale: minimumScale, metrics: layout.metrics)
        candidates.formUnion(reduced.visibleIndices(count: layout.count, width: width, height: height, metrics: layout.metrics))
        return candidates
    }

    private func makeArtwork() -> [Int: ZoomArtwork] {
        let scale = collection?.window?.backingScaleFactor ?? 2
        if badgeBackingScale != scale { badgeBitmaps.removeAll(); badgeBackingScale = scale }
        let entries = items()
        var artwork: [Int: ZoomArtwork] = [:]
        for index in planImageCandidates() where entries.indices.contains(index) {
            let item = entries[index]
            let cell = collection?.item(at: IndexPath(item: index, section: 0)) as? ThumbnailCollectionItem
            let view = cell?.view as? ThumbnailItemView
            let image = cell?.imageView?.image ?? SystemThumbnailProvider.shared.bestCachedThumbnail(
                for: item.url, scale: scale, contentVersion: item.contentVersion)
            var value = ZoomArtwork(image: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let loadedLabel = view?.badgeLabel
            let text = loadedLabel.flatMap { $0.stringValue.isEmpty ? nil : $0.stringValue }
                ?? item.mediaKind.formatBadgeText(for: item.url)
            if let text {
                if let cached = badgeBitmaps[text] { value.badge = cached.image; value.badgeSize = cached.size }
                else {
                    // Snapshot the native label style with full opacity. A live
                    // label may already be fading out for the previous pinch.
                    let badge = ThumbnailBadgeLabel(labelWithString: text)
                    badge.frame.size = ThumbnailBadgeStyle.size(for: text)
                    collection?.effectiveAppearance.performAsCurrentDrawingAppearance { value.badge = Self.bitmap(badge) }
                    value.badgeSize = badge.bounds.size
                    badgeBitmaps[text] = (value.badge, value.badgeSize)
                }
            }
            if let ring = view?.ringView, !ring.isHidden { value.ringColor = ring.layer?.borderColor }
            if let failure = view?.failureLabel, !failure.isHidden {
                value.failure = Self.bitmap(failure); value.failureSize = failure.bounds.size
            }
            artwork[index] = value
        }
        return artwork
    }

    private static func bitmap(_ view: NSView) -> CGImage? {
        guard !view.bounds.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    private func prefetchPlanImages() {
        guard let plan else { return }
        let candidates = planImageCandidates()
        let entries = items(), generation = imageGeneration
        // Reuse the displayed bitmap throughout the gesture. Preparing all
        // four layouts does not require regenerating every candidate at the
        // largest size; settled native cells request detail when necessary.
        let pointSize = ThumbnailCollectionStyle.cellSide
        let scale = collection?.window?.backingScaleFactor ?? 2
        for index in candidates.sorted(by: { abs($0 - plan.anchor.index) < abs($1 - plan.anchor.index) })
            where entries.indices.contains(index) && overlay.image(at: index) == nil {
            let item = entries[index]
            imageTasks[index] = Task { [weak self] in
                let result = await SystemThumbnailProvider.shared.thumbnail(for: item.url, pointSize: pointSize,
                    scale: scale, contentVersion: item.contentVersion, allowsCachedThumbnail: item.unavailableMessage == nil)
                guard !Task.isCancelled, let self, generation == self.imageGeneration,
                      let image = result.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                self.overlay.replaceImage(image, at: index)
                self.imageTasks[index] = nil
                self.requestFrame()
            }
        }
    }

    private func cancelImageTasks() {
        imageGeneration += 1
        imageTasks.values.forEach { $0.cancel() }
        imageTasks.removeAll()
    }
}
