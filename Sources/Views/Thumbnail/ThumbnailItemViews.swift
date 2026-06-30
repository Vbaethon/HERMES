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
        imageView.imageFrameStyle = .photo
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        rootView.addSubview(imageView)
        rootView.imageView = imageView
        self.imageView = imageView

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
        badgeLabel.isHidden = true
        rootView.addSubview(badgeLabel)
        rootView.badgeLabel = badgeLabel
        rootView.onEffectiveAppearanceChanged = { [weak self] in
            self?.updateBorderAppearance()
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
        thumbnailView?.setBadge(nil)
    }

    override var isSelected: Bool {
        didSet {
            updateBorderAppearance()
        }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet {
            updateBorderAppearance()
        }
    }

    func setSelectedAppearance(_ selected: Bool) {
        thumbnailView?.setRingState(ringState(isSelected: selected))
    }

    func configure(with url: URL, status: PairItem.Status = .finished, mediaKind: ThumbnailMediaKind = .photo) {
        if representedURL == url {
            thumbnailStatus = status
            self.mediaKind = mediaKind
            loadBadgeIfNeeded(for: url, mediaKind: mediaKind)
            updateBorderAppearance()
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
        imageView?.image = nil
        loadBadgeIfNeeded(for: url, mediaKind: mediaKind)
        updateBorderAppearance()
        view.toolTip = url.lastPathComponent
        startThumbnailLoad(for: url)
    }

    private func startThumbnailLoad(for url: URL) {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let image = await SystemThumbnailProvider.shared.thumbnail(
                for: url,
                maxPixelSize: ThumbnailCollectionStyle.thumbnailMaxPixelSize
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.representedURL == url, !Task.isCancelled else { return }
                self.showLoadedThumbnail(image)
            }
        }
    }

    @MainActor
    private func showLoadedThumbnail(_ image: NSImage) {
        imageView?.image = image
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
            guard !Task.isCancelled else { return }
            let durationText = await loadVideoDurationText(from: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.representedURL == url, self.mediaKind == mediaKind, !Task.isCancelled else { return }
                self.thumbnailView?.setBadge(durationText)
            }
        }
    }

    private func updateBorderAppearance() {
        thumbnailView?.setRingState(ringState(isSelected: isSelected))
    }

    private func ringState(isSelected: Bool) -> ThumbnailStateRing {
        if isSelected || highlightState != .none {
            return .selected
        } else if thumbnailStatus == .failed {
            return .failed
        } else {
            return .none
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
            layer.borderColor = resolvedBorderColor(
                activeColor: .selectedContentBackgroundColor,
                inactiveColor: .unemphasizedSelectedContentBackgroundColor
            ).cgColor
        case .failed:
            layer.borderColor = resolvedBorderColor(activeColor: .systemRed).cgColor
        case .none:
            break
        }
    }

    private func resolvedBorderColor(activeColor: NSColor, inactiveColor: NSColor? = nil) -> NSColor {
        guard window?.isKeyWindow != true else {
            return activeColor
        }
        return inactiveColor ?? activeColor.withSystemEffect(.disabled)
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
        updateImageFrame()
        updateBadgeFrames()
    }

    private func updateImageFrame() {
        guard let imageView else { return }
        let frame = bounds
        imageView.frame = frame
        interactiveFrame = frame
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
