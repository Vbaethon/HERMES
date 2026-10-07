import AppKit
import QuartzCore

final class ThumbnailCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCollectionItem")
    private var representedURL: URL?
    private var representedContentVersion: TimeInterval?
    private var thumbnailStatus: PairItem.Status = .finished
    private var mediaKind: ThumbnailMediaKind = .photo
    private var thumbnailTask: Task<Void, Never>?
    private var badgeTask: Task<Void, Never>?
    private var unavailableMessage: String?
    private var previewMessage: String?
    private var requestedThumbnailSide: CGFloat = 0
    private var lastAppliedSize: CGSize = .zero
    private var zoomPresentationSuppressed = false
    private var layoutOpacity: CGFloat = 1
    private struct Appearance: Equatable {
        let url: URL?
        let status: PairItem.Status
        let kind: ThumbnailMediaKind
        let selected: Bool
        let availability: String?
    }
    private var lastAppearance: Appearance?
    private weak var lastAppearanceImage: NSImage?
    private var thumbnailView: ThumbnailItemView? { view as? ThumbnailItemView }
    var isPresentingComposition: Bool { thumbnailView?.compositionEffect.isPresenting == true }
    var onCompositionPresentationEnded: (() -> Void)? {
        get { thumbnailView?.compositionEffect.onPresentationEnded }
        set { thumbnailView?.compositionEffect.onPresentationEnded = newValue }
    }

    deinit {
        thumbnailTask?.cancel()
        badgeTask?.cancel()
    }

    override func loadView() {
        let rootView = ThumbnailItemView(frame: NSRect(origin: .zero, size: ThumbnailCollectionStyle.itemSize))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        let imageView = ThumbnailImageView(frame: rootView.bounds)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = ThumbnailCollectionStyle.imageCornerRadius
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true

        rootView.addSubview(imageView)
        rootView.imageView = imageView
        self.imageView = imageView

        rootView.addSubview(rootView.compositionEffect)

        let ringView = ThumbnailStateRingView(frame: .zero)
        ringView.isHidden = true
        ringView.wantsLayer = true
        ringView.layer?.cornerRadius = ThumbnailCollectionStyle.imageCornerRadius
            + ThumbnailCollectionStyle.stateRingGap
            + ThumbnailCollectionStyle.stateRingLineWidth
        ringView.layer?.cornerCurve = .continuous
        ringView.layer?.borderWidth = ThumbnailCollectionStyle.stateRingLineWidth
        rootView.addSubview(ringView)
        rootView.ringView = ringView

        let badgeLabel = ThumbnailBadgeLabel(labelWithString: "")
        badgeLabel.alignment = .center
        badgeLabel.font = ThumbnailBadgeStyle.font
        badgeLabel.textColor = ThumbnailBadgeStyle.textColor
        badgeLabel.isBordered = false
        badgeLabel.drawsBackground = false
        badgeLabel.lineBreakMode = .byClipping
        badgeLabel.wantsLayer = true
        badgeLabel.isHidden = true
        rootView.addSubview(badgeLabel)
        rootView.badgeLabel = badgeLabel
        let failureLabel = NSTextField(labelWithString: "失败")
        failureLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        failureLabel.textColor = .labelColor
        failureLabel.backgroundColor = .windowBackgroundColor
        failureLabel.drawsBackground = true
        failureLabel.isHidden = true
        rootView.addSubview(failureLabel)
        rootView.failureLabel = failureLabel
        let placeholderLabel = NSTextField(labelWithString: "")
        placeholderLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.lineBreakMode = .byTruncatingMiddle
        placeholderLabel.isHidden = true
        rootView.addSubview(placeholderLabel)
        rootView.placeholderLabel = placeholderLabel
        rootView.onEffectiveAppearanceChanged = { [weak self] in
            self?.lastAppearance = nil
            self?.updateBorderAppearance(isSelected: self?.isSelected ?? false)
        }
        view = rootView
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        badgeTask?.cancel()
        thumbnailTask = nil
        badgeTask = nil
        representedURL = nil
        representedContentVersion = nil
        requestedThumbnailSide = 0
        lastAppliedSize = .zero
        zoomPresentationSuppressed = false
        layoutOpacity = 1
        applyZoomPresentationVisibility()
        unavailableMessage = nil
        previewMessage = nil
        lastAppearance = nil
        lastAppearanceImage = nil
        view.setAccessibilityLabel(nil)
        view.setAccessibilityValue(nil)
        thumbnailView?.compositionEffect.reset()
        thumbnailView?.failureLabel?.isHidden = true
        thumbnailView?.placeholderLabel?.isHidden = true
        imageView?.layer?.removeAnimation(forKey: "opacity")
        imageView?.image = nil
        imageView?.alphaValue = 0
        thumbnailView?.setBadge(nil)
        thumbnailView?.updateImageFrame(for: nil)
    }

    override var isSelected: Bool {
        didSet {
            if oldValue != isSelected { updateBorderAppearance(isSelected: isSelected) }
        }
    }

    override func apply(_ layoutAttributes: NSCollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        layoutOpacity = layoutAttributes.alpha
        applyZoomPresentationVisibility()
        let sizeChanged = lastAppliedSize != view.bounds.size
        lastAppliedSize = view.bounds.size
        if sizeChanged { view.needsLayout = true }
        // Keep the displayed bitmap while requesting enough pixels for a larger
        // settled preset. Resizing/status changes must not restart its fade.
        if let url = representedURL,
           SystemThumbnailProvider.requestSize(for: min(view.bounds.width, view.bounds.height)) > requestedThumbnailSide
                || (sizeChanged && thumbnailTask != nil && imageView?.image != nil) {
            startThumbnailLoad(for: url)
        }
    }

    func setZoomPresentationSuppressed(_ suppressed: Bool) {
        zoomPresentationSuppressed = suppressed
        applyZoomPresentationVisibility()
    }

    private func applyZoomPresentationVisibility() {
        let alpha: CGFloat = zoomPresentationSuppressed ? 0 : layoutOpacity
        guard view.alphaValue != alpha else { return }
        // Reusable native cells keep their identity and decoded image, but
        // only the prepared presentation draws during a pinch and handoff.
        view.alphaValue = alpha
    }

    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard let imageView, let image = imageView.image?.copy() as? NSImage else { return [] }
        view.layoutSubtreeIfNeeded()
        var frame = imageView.convert(imageView.bounds, to: view)
        guard !frame.isEmpty else { return [] }
        // AppKit drag components use bottom-left coordinates, even in flipped cells.
        if view.isFlipped { frame.origin.y = view.bounds.maxY - frame.maxY }
        let shadow = NSImage(size: frame.size, flipped: false) { bounds in
            NSBezierPath(roundedRect: bounds,
                         xRadius: ThumbnailCollectionStyle.imageCornerRadius,
                         yRadius: ThumbnailCollectionStyle.imageCornerRadius).addClip()
            image.draw(in: bounds)
            return true
        }
        let component = NSDraggingImageComponent(key: .icon)
        component.frame = frame
        component.contents = shadow
        return [component]
    }

    func setSelectedAppearance(_ selected: Bool) {
        updateBorderAppearance(isSelected: selected)
    }

    func setZoomBadgeOpacity(_ opacity: CGFloat) {
        thumbnailView?.setZoomBadgeOpacity(opacity)
    }

    func retainZoomThumbnail(_ image: CGImage, for url: URL, contentVersion: TimeInterval) {
        guard representedURL == url, representedContentVersion == contentVersion else { return }
        // A held frame can be checked twice while AppKit completes its layout.
        // Retain the existing NSImage and its native drawing state when the
        // bitmap is already installed; don't start another layout/redraw pass.
        if imageView?.alphaValue == 1,
           imageView?.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) === image { return }
        let scale = view.window?.backingScaleFactor ?? 2
        showLoadedThumbnail(NSImage(cgImage: image,
            size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)), animated: false)
        updateBorderAppearance(isSelected: isSelected)
    }

    func configure(with url: URL, status: PairItem.Status = .finished, mediaKind: ThumbnailMediaKind = .photo, contentVersion: TimeInterval = 0, unavailableMessage: String? = nil) {
        if representedURL == url, representedContentVersion == contentVersion, self.unavailableMessage == unavailableMessage {
            thumbnailStatus = status
            let kindChanged = self.mediaKind != mediaKind
            self.mediaKind = mediaKind
            if kindChanged { badgeTask?.cancel(); badgeTask = nil; thumbnailView?.setBadge(nil) }
            if kindChanged || (mediaKind.showsDuration && badgeTask == nil && thumbnailView?.badgeLabel?.stringValue.isEmpty == true) {
                loadBadgeIfNeeded(for: url, mediaKind: mediaKind)
            }
            updateBorderAppearance(isSelected: isSelected)
            if imageView?.image == nil, thumbnailTask == nil {
                startThumbnailLoad(for: url)
            }
            return
        }

        thumbnailTask?.cancel()
        badgeTask?.cancel()
        thumbnailTask = nil
        badgeTask = nil
        thumbnailView?.setBadge(nil)
        representedURL = url
        representedContentVersion = contentVersion
        requestedThumbnailSide = 0
        self.unavailableMessage = unavailableMessage
        previewMessage = nil
        thumbnailView?.placeholderLabel?.isHidden = true
        thumbnailStatus = status
        self.mediaKind = mediaKind
        thumbnailView?.compositionEffect.reset()
        imageView?.alphaValue = 0
        imageView?.image = nil
        thumbnailView?.updateImageFrame(for: nil)
        loadBadgeIfNeeded(for: url, mediaKind: mediaKind)
        updateBorderAppearance(isSelected: isSelected)
        view.toolTip = url.lastPathComponent

        startThumbnailLoad(for: url)
    }

    private func startThumbnailLoad(for url: URL) {
        thumbnailTask?.cancel()
        let displayScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let contentVersion = representedContentVersion ?? 0
        let pointSize = SystemThumbnailProvider.requestSize(for: min(view.bounds.width, view.bounds.height))
        requestedThumbnailSide = pointSize
        let allowsCachedThumbnail = unavailableMessage == nil
        if allowsCachedThumbnail, let cached = SystemThumbnailProvider.shared.cachedThumbnail(for: url,
            pointSize: pointSize, scale: displayScale, contentVersion: contentVersion) {
            thumbnailTask = nil
            showLoadedThumbnail(cached, animated: false)
            updateBorderAppearance(isSelected: isSelected)
            return
        }
        if imageView?.image == nil, allowsCachedThumbnail,
           let cached = SystemThumbnailProvider.shared.bestCachedThumbnail(for: url,
                scale: displayScale, contentVersion: contentVersion) {
            showLoadedThumbnail(cached, animated: false)
        }
        let hasArtwork = imageView?.image != nil
        thumbnailTask = Task { [weak self] in
            // Resizing a window or animating a sidebar keeps the current
            // bitmap on screen. Generate extra detail only after sizing rests.
            try? await Task.sleep(for: hasArtwork ? .milliseconds(140) : .milliseconds(35))
            while self?.view.inLiveResize == true && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled else { return }
            let result = await SystemThumbnailProvider.shared.thumbnail(
                for: url,
                pointSize: pointSize,
                scale: displayScale,
                contentVersion: contentVersion,
                allowsCachedThumbnail: allowsCachedThumbnail
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.representedURL == url,
                      self.representedContentVersion == contentVersion, !Task.isCancelled else { return }
                self.thumbnailTask = nil
                self.previewMessage = result.unavailableMessage
                let shouldFadeIn = self.imageView?.image == nil
                self.showLoadedThumbnail(result.image ?? Self.unavailableThumbnail(), animated: shouldFadeIn)
                self.thumbnailView?.placeholderLabel?.stringValue = url.lastPathComponent
                self.thumbnailView?.placeholderLabel?.isHidden = result.image != nil
                self.updateBorderAppearance(isSelected: self.isSelected)
            }
        }
    }

    private static func unavailableThumbnail() -> NSImage {
        let size = ThumbnailCollectionStyle.itemSize
        return NSImage(size: size, flipped: false) { bounds in
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
            symbol?.draw(in: NSRect(x: (size.width - 44) / 2, y: 54, width: 44, height: 40))
            return true
        }
    }

    @MainActor
    private func showLoadedThumbnail(_ image: NSImage, animated: Bool) {
        guard let imageView else { return }
        // Changing the model alpha does not cancel a fade still presenting on
        // the recycled image layer. Never carry it into another artwork.
        imageView.layer?.removeAnimation(forKey: "opacity")
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            imageView.alphaValue = 0
            imageView.image = image
            thumbnailView?.updateImageFrame(for: image)
            // Retain AppKit's timing curve with the grid's calmer transition
            // duration. Cached revisits paint immediately without another fade.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ThumbnailCollectionAnimation.duration()
                imageView.animator().alphaValue = 1
            }
        } else {
            imageView.image = image
            thumbnailView?.updateImageFrame(for: image)
            imageView.alphaValue = 1
        }
    }

    private func loadBadgeIfNeeded(for url: URL, mediaKind: ThumbnailMediaKind) {
        if let formatText = mediaKind.formatBadgeText(for: url) {
            thumbnailView?.setBadge(formatText)
            return
        }

        guard mediaKind.showsDuration else {
            thumbnailView?.setBadge(nil)
            return
        }

        let contentVersion = representedContentVersion ?? 0
        if let cached = thumbnailDurationCache.cache.object(forKey:
            thumbnailDurationCache.key(for: url, contentVersion: contentVersion)) {
            thumbnailView?.setBadge(cached as String)
            return
        }
        guard badgeTask == nil else { return }
        badgeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            let durationText = await loadVideoDurationText(from: url, contentVersion: contentVersion)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.representedURL == url, self.representedContentVersion == contentVersion,
                      self.mediaKind == mediaKind, !Task.isCancelled else { return }
                self.badgeTask = nil
                self.thumbnailView?.setBadge(durationText)
            }
        }
    }

    private func updateBorderAppearance(isSelected: Bool) {
        let availability = unavailableMessage ?? previewMessage
        let appearance = Appearance(url: representedURL, status: thumbnailStatus,
            kind: mediaKind, selected: isSelected, availability: availability)
        guard lastAppearance != appearance || lastAppearanceImage !== imageView?.image else { return }
        lastAppearance = appearance
        lastAppearanceImage = imageView?.image
        let kind: String
        switch mediaKind {
        case .photo: kind = "照片"
        case .livePhoto: kind = "Live Photo"
        case .video: kind = "视频"
        }
        let status: String
        switch thumbnailStatus {
        case .waiting: status = "待合成"
        case .running: status = "正在合成"
        case .finished: status = mediaKind == .livePhoto ? "已合成" : "媒体文件"
        case .failed: status = "合成失败"
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(representedURL.map { "\($0.lastPathComponent)，\(kind)" })
        view.setAccessibilityValue(([status, availability, isSelected ? "已选择" : "未选择"].compactMap { $0 }).joined(separator: "，"))
        view.toolTip = representedURL.map { availability == nil ? $0.lastPathComponent : "\(availability!)\n\($0.path)" }
        thumbnailView?.compositionEffect.update(image: imageView?.image, running: thumbnailStatus == .running)
        let failureText = thumbnailStatus == .failed ? "合成失败" : availability ?? ""
        let failureHidden = thumbnailStatus != .failed && availability == nil
        if let label = thumbnailView?.failureLabel,
           label.stringValue != failureText || label.isHidden != failureHidden {
            label.stringValue = failureText
            label.isHidden = failureHidden
            thumbnailView?.needsLayout = true
        }
        if isSelected {
            thumbnailView?.setRingState(.selected)
        } else if thumbnailStatus == .failed {
            thumbnailView?.setRingState(.failed)
        } else {
            thumbnailView?.setRingState(.none)
        }
    }
}

fileprivate enum ThumbnailStateRing {
    case none
    case selected
    case failed
}

final class ThumbnailStateRingView: NSView {
    fileprivate var state: ThumbnailStateRing = .none {
        didSet {
            guard state != oldValue else { return }
            isHidden = state == .none
            updateBorderColor()
        }
    }

    private var keyWindowObservers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyWindowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyWindowObservers.removeAll()

        guard let window else { return }
        let center = NotificationCenter.default
        keyWindowObservers.append(
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateBorderColor() }
            }
        )
        keyWindowObservers.append(
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateBorderColor() }
            }
        )
        updateBorderColor()
    }

    private func updateBorderColor() {
        guard let layer else { return }
        switch state {
        case .selected:
            layer.borderColor = (window?.isKeyWindow == true)
                ? NSColor.selectedContentBackgroundColor.cgColor
                : NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        case .failed:
            layer.borderColor = NSColor.systemRed.cgColor
        case .none:
            break
        }
    }
}

final class ThumbnailImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class ThumbnailBadgeLabel: NSTextField {
    // The label remains an NSTextField for native text/accessibility semantics.
    // Panning exposes new backing regions: reuse a small decoded bitmap instead
    // of asking Core Text to paint the same format/duration on every scroll tick.
    private static let bitmaps: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()
    private struct TextLayout {
        let value: String
        let text: NSString
        let attributes: [NSAttributedString.Key: Any]
        let textHeight: CGFloat
        let badgeSize: NSSize
    }
    private var cachedTextLayout: TextLayout?

    fileprivate var badgeSize: NSSize { textLayout().badgeSize }

    private func textLayout() -> TextLayout {
        let value = stringValue
        if let cachedTextLayout, cachedTextLayout.value == value { return cachedTextLayout }
        let text = value as NSString
        let font = ThumbnailBadgeStyle.font(for: value)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ThumbnailBadgeStyle.textColor,
            .paragraphStyle: paragraphStyle
        ]
        let layout = TextLayout(
            value: value,
            text: text,
            attributes: attributes,
            textHeight: ceil(text.size(withAttributes: attributes).height),
            badgeSize: NSSize(width: ceil(text.size(withAttributes: [.font: font]).width)
                + ThumbnailBadgeStyle.horizontalPadding * 2, height: ThumbnailBadgeStyle.height)
        )
        cachedTextLayout = layout
        return layout
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        layer.contentsGravity = .resize
        layer.contents = bitmap(size: bounds.size, scale: scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Also used when the zoom presentation snapshots an unattached label.
        guard let image = bitmap(size: bounds.size,
                                 scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) else { return }
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
    }

    private func bitmap(size: CGSize, scale: CGFloat) -> CGImage? {
        guard !stringValue.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let key = "\(stringValue)\n\(size.width):\(size.height):\(scale):\(opaque)" as NSString
        if let cached = Self.bitmaps.object(forKey: key) { return cached }
        let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let bounds = CGRect(origin: .zero, size: size)
        NSColor.black.withAlphaComponent(opaque ? 1 : 0.62).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: ThumbnailBadgeStyle.cornerRadius,
                     yRadius: ThumbnailBadgeStyle.cornerRadius).fill()
        let textInsets = NSEdgeInsets(
            top: 0,
            left: ThumbnailBadgeStyle.horizontalPadding,
            bottom: 0,
            right: ThumbnailBadgeStyle.horizontalPadding
        )
        let layout = textLayout()
        let textRect = NSRect(
            x: bounds.minX + textInsets.left,
            y: bounds.midY - layout.textHeight / 2,
            width: bounds.width - textInsets.left - textInsets.right,
            height: layout.textHeight
        )
        layout.text.draw(in: textRect.integral, withAttributes: layout.attributes)
        guard let image = context.makeImage() else { return nil }
        Self.bitmaps.setObject(image, forKey: key, cost: width * height * 4)
        return image
    }
}

final class ThumbnailItemView: NSView {
    let compositionEffect = ThumbnailCompositionEffect(frame: .zero)
    weak var imageView: NSImageView?
    weak var badgeLabel: NSTextField?
    weak var failureLabel: NSTextField?
    weak var placeholderLabel: NSTextField?
    weak var ringView: ThumbnailStateRingView?
    private var interactiveFrame: NSRect = .zero
    private var measuredFailureText: String?
    private var failureFittingSize: NSSize = .zero
    var onEffectiveAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChanged?()
    }

    override func layout() {
        super.layout()
        updateImageFrame(for: imageView?.image)
    }

    func containsThumbnail(at point: NSPoint) -> Bool {
        layoutSubtreeIfNeeded()
        return !interactiveFrame.isEmpty && interactiveFrame.contains(point)
    }

    func updateImageFrame(for image: NSImage?) {
        guard let imageView else { return }
        guard let image, image.size.width > 0, image.size.height > 0 else {
            interactiveFrame = .zero
            imageView.frame = .zero
            compositionEffect.frame = .zero
            ringView?.frame = .zero
            updateBadgeFrames()
            return
        }

        let maxSide = min(bounds.width, bounds.height)
        let scale = min(maxSide / image.size.width, maxSide / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        let frame = NSRect(origin: origin, size: size)
        interactiveFrame = frame
        if imageView.frame != frame { imageView.frame = frame }
        if compositionEffect.frame != frame { compositionEffect.frame = frame }
        updateRingFrame()
        updateBadgeFrames()
    }

    fileprivate func setRingState(_ state: ThumbnailStateRing) {
        ringView?.state = state
    }

    func setBadge(_ text: String?) {
        guard let badgeLabel else { return }
        guard let text, !text.isEmpty else {
            guard !badgeLabel.isHidden || !badgeLabel.stringValue.isEmpty else { return }
            badgeLabel.isHidden = true
            badgeLabel.stringValue = ""
            return
        }
        guard badgeLabel.stringValue != text || badgeLabel.isHidden else { return }
        badgeLabel.stringValue = text
        updateBadgeFrames()
    }

    func setZoomBadgeOpacity(_ opacity: CGFloat) {
        let value = min(1, max(0, opacity))
        if badgeLabel?.alphaValue != value { badgeLabel?.alphaValue = value }
    }

    private func updateRingFrame() {
        guard let ringView else { return }
        let outwardInset = ThumbnailCollectionStyle.stateRingGap + ThumbnailCollectionStyle.stateRingLineWidth
        let frame = interactiveFrame.insetBy(dx: -outwardInset, dy: -outwardInset)
        if ringView.frame != frame { ringView.frame = frame }
    }

    private func updateBadgeFrames() {
        let baseFrame = interactiveFrame.isEmpty ? bounds.insetBy(dx: 8, dy: 8) : interactiveFrame
        updateFailureFrame(in: baseFrame)
        if let placeholderLabel, !placeholderLabel.isHidden {
            let frame = NSRect(x: baseFrame.minX + 8, y: baseFrame.minY + 12, width: max(0, baseFrame.width - 16), height: 18)
            if placeholderLabel.frame != frame { placeholderLabel.frame = frame }
        }
        if let badgeLabel {
            // Format/duration text can arrive before the asynchronous image.
            // Keep it for reuse, but never position a free-standing badge on
            // the cell's fallback bounds while there is no displayed artwork.
            let showsBadge = !interactiveFrame.isEmpty && !badgeLabel.stringValue.isEmpty
            badgeLabel.isHidden = !showsBadge
            guard showsBadge else { return }
            let labelSize = (badgeLabel as? ThumbnailBadgeLabel)?.badgeSize
                ?? ThumbnailBadgeStyle.size(for: badgeLabel.stringValue)
            let origin = NSPoint(
                x: baseFrame.maxX - labelSize.width - ThumbnailBadgeStyle.inset,
                y: baseFrame.minY + ThumbnailBadgeStyle.inset
            )
            let frame = NSRect(origin: origin, size: labelSize).integral
            if badgeLabel.frame != frame { badgeLabel.frame = frame }
        }
    }

    private func updateFailureFrame(in baseFrame: NSRect) {
        guard let failureLabel, !failureLabel.isHidden else { return }
        let text = failureLabel.stringValue
        if measuredFailureText != text {
            measuredFailureText = text
            failureFittingSize = failureLabel.fittingSize
        }
        let frame = NSRect(x: baseFrame.minX + 4, y: baseFrame.maxY - failureFittingSize.height - 4,
                           width: min(failureFittingSize.width + 8, baseFrame.width - 8), height: failureFittingSize.height)
        guard failureLabel.frame != frame else { return }
        failureLabel.frame = frame
    }
}
