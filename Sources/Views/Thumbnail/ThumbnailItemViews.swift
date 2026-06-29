import AppKit

final class ThumbnailCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailCollectionItem")
    private var representedURL: URL?
    private var thumbnailStatus: PairItem.Status = .finished
    private var mediaKind: ThumbnailMediaKind = .photo
    private var thumbnailTask: Task<Void, Never>?
    private var badgeTask: Task<Void, Never>?
    private var thumbnailView: ThumbnailItemView? { view as? ThumbnailItemView }

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

        let ringView = ThumbnailStateRingView(frame: .zero)
        ringView.isHidden = true
        rootView.addSubview(ringView)
        rootView.ringView = ringView

        let badgeLabel = ThumbnailBadgeLabel(labelWithString: "")
        badgeLabel.alignment = .center
        badgeLabel.font = ThumbnailBadgeStyle.font
        badgeLabel.textColor = ThumbnailBadgeStyle.textColor
        badgeLabel.isBordered = false
        badgeLabel.drawsBackground = false
        badgeLabel.lineBreakMode = .byClipping
        badgeLabel.isHidden = true
        rootView.addSubview(badgeLabel)
        rootView.badgeLabel = badgeLabel
        rootView.onEffectiveAppearanceChanged = { [weak self] in
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
        imageView?.image = nil
        imageView?.alphaValue = 0
        thumbnailView?.setBadge(nil)
        thumbnailView?.updateImageFrame(for: nil)
    }

    override var isSelected: Bool {
        didSet {
            updateBorderAppearance(isSelected: isSelected)
        }
    }

    func setSelectedAppearance(_ selected: Bool) {
        updateBorderAppearance(isSelected: selected)
    }

    func configure(with url: URL, status: PairItem.Status = .finished, mediaKind: ThumbnailMediaKind = .photo) {
        if representedURL == url {
            thumbnailStatus = status
            self.mediaKind = mediaKind
            loadBadgeIfNeeded(for: url, mediaKind: mediaKind)
            updateBorderAppearance(isSelected: isSelected)
            view.toolTip = url.lastPathComponent
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
        thumbnailStatus = status
        self.mediaKind = mediaKind
        let cachedImage = thumbnailCache.image(for: url)
        if let cachedImage {
            showLoadedThumbnail(cachedImage, animated: true)
        } else {
            imageView?.alphaValue = 0
            imageView?.image = nil
            thumbnailView?.updateImageFrame(for: nil)
        }
        loadBadgeIfNeeded(for: url, mediaKind: mediaKind)
        updateBorderAppearance(isSelected: isSelected)
        view.toolTip = url.lastPathComponent

        guard cachedImage == nil else { return }
        startThumbnailLoad(for: url)
    }

    private func startThumbnailLoad(for url: URL) {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled else { return }
            let image = await loadThumbnailImage(from: url, maxPixelSize: ThumbnailCollectionStyle.thumbnailMaxPixelSize)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.representedURL == url, !Task.isCancelled else { return }
                let shouldFadeIn = self.imageView?.image == nil
                if let image {
                    self.showLoadedThumbnail(image, animated: shouldFadeIn)
                } else {
                    self.imageView?.image = nil
                    self.thumbnailView?.updateImageFrame(for: nil)
                    self.imageView?.alphaValue = 0
                }
            }
        }
    }

    @MainActor
    private func showLoadedThumbnail(_ image: NSImage, animated: Bool) {
        guard let imageView else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            imageView.alphaValue = 0
            imageView.image = image
            thumbnailView?.updateImageFrame(for: image)
            NSAnimationContext.runAnimationGroup { context in
                context.allowsImplicitAnimation = true
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

        badgeTask?.cancel()
        badgeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            await thumbnailScrollActivity.waitUntilIdle()
            guard !Task.isCancelled else { return }
            let durationText = await loadVideoDurationText(from: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.representedURL == url, self.mediaKind == mediaKind, !Task.isCancelled else { return }
                self.thumbnailView?.setBadge(durationText)
            }
        }
    }

    private func updateBorderAppearance(isSelected: Bool) {
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
            isHidden = state == .none
            needsDisplay = true
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
                self?.needsDisplay = true
            }
        )
        keyWindowObservers.append(
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            }
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard state != .none else { return }
        let lineWidth = ThumbnailCollectionStyle.stateRingLineWidth
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = ThumbnailCollectionStyle.imageCornerRadius + ThumbnailCollectionStyle.stateRingGap
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        switch state {
        case .selected:
            let color = (window?.isKeyWindow == true)
                ? NSColor.selectedContentBackgroundColor
                : NSColor.unemphasizedSelectedContentBackgroundColor
            color.setStroke()
            path.lineWidth = lineWidth
            path.stroke()
        case .failed:
            NSColor.systemRed.setStroke()
            path.lineWidth = lineWidth
            path.stroke()
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
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !stringValue.isEmpty else { return }
        let textInsets = NSEdgeInsets(
            top: 0,
            left: ThumbnailBadgeStyle.horizontalPadding,
            bottom: 0,
            right: ThumbnailBadgeStyle.horizontalPadding
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ThumbnailBadgeStyle.font,
            .foregroundColor: ThumbnailBadgeStyle.textColor,
            .paragraphStyle: paragraphStyle
        ]
        let textSize = (stringValue as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: bounds.minX + textInsets.left,
            y: bounds.midY - ceil(textSize.height) / 2,
            width: bounds.width - textInsets.left - textInsets.right,
            height: ceil(textSize.height)
        )
        (stringValue as NSString).draw(in: textRect.integral, withAttributes: attributes)
    }
}

final class ThumbnailItemView: NSView {
    weak var imageView: NSImageView?
    weak var badgeLabel: NSTextField?
    weak var ringView: ThumbnailStateRingView?
    private var interactiveFrame: NSRect = .zero
    var onEffectiveAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChanged?()
    }

    override func layout() {
        super.layout()
        updateImageFrame(for: imageView?.image)
        updateBadgeFrames()
    }

    func updateImageFrame(for image: NSImage?) {
        guard let imageView else { return }
        guard let image, image.size.width > 0, image.size.height > 0 else {
            interactiveFrame = .zero
            imageView.frame = .zero
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
        imageView.frame = frame
        updateRingFrame()
        updateBadgeFrames()
    }

    fileprivate func setRingState(_ state: ThumbnailStateRing) {
        ringView?.state = state
    }

    func setBadge(_ text: String?) {
        guard let badgeLabel else { return }
        guard let text, !text.isEmpty else {
            badgeLabel.isHidden = true
            badgeLabel.stringValue = ""
            return
        }
        badgeLabel.stringValue = text
        badgeLabel.isHidden = false
        updateBadgeFrames()
    }

    private func updateRingFrame() {
        guard let ringView else { return }
        let outwardInset = ThumbnailCollectionStyle.stateRingGap + ThumbnailCollectionStyle.stateRingLineWidth
        ringView.frame = interactiveFrame.insetBy(dx: -outwardInset, dy: -outwardInset)
    }

    private func updateBadgeFrames() {
        let baseFrame = interactiveFrame.isEmpty ? bounds.insetBy(dx: 8, dy: 8) : interactiveFrame
        if let badgeLabel, !badgeLabel.isHidden {
            let labelSize = ThumbnailBadgeStyle.size(for: badgeLabel.stringValue)
            let origin = NSPoint(
                x: baseFrame.maxX - labelSize.width - ThumbnailBadgeStyle.inset,
                y: baseFrame.minY + ThumbnailBadgeStyle.inset
            )
            badgeLabel.frame = NSRect(origin: origin, size: labelSize).integral
        }
    }
}
