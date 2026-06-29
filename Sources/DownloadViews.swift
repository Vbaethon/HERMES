import AppKit
import Combine
import Foundation

// MARK: - Download Progress Data Model

struct DownloadProgressItem: Identifiable, Equatable {
    let id: UUID
    var title: String
    var detail: String
    var completedCount: Int
    var totalCount: Int
    var currentUnitProgress: CGFloat
    var isActive: Bool

    var countText: String {
        "\(min(completedCount + (isActive ? 1 : 0), totalCount))/\(totalCount)"
    }

    var progress: CGFloat {
        guard totalCount > 0 else { return 0 }
        return (CGFloat(completedCount) + currentUnitProgress) / CGFloat(totalCount)
    }
}

// MARK: - Download Input Metrics

private enum DownloadInputMetrics {
    static let barWidth: CGFloat = 720
    static let buttonSide: CGFloat = 28
    static let leadingPadding: CGFloat = 6
    static let trailingPadding: CGFloat = 2
    static let horizontalSpacing: CGFloat = 12
    static let horizontalPagePadding: CGFloat = 44
    static let bottomPadding: CGFloat = 46
    static let lineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }()
    static let verticalInset: CGFloat = 3
    static let verticalPadding: CGFloat = 9
    static let minimumVisibleLineCount = 3
    static let maxVisibleLineCount = 8
    static let progressWidthMultiplier: CGFloat = 0.84
    static let progressMaxWidth: CGFloat = 560
    static let progressBottomSpacing: CGFloat = 6
    static let progressStackHeight: CGFloat = 68

    static func rawLineCount(for text: String) -> Int {
        max(text.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
    }

    static func inputLineCount(for rawLineCount: Int) -> Int {
        min(max(rawLineCount, minimumVisibleLineCount), maxVisibleLineCount)
    }

    static func inputHeight(for rawLineCount: Int) -> CGFloat {
        CGFloat(inputLineCount(for: rawLineCount)) * lineHeight + verticalInset * 2
    }

    static func contentHeight(for rawLineCount: Int) -> CGFloat {
        max(inputHeight(for: rawLineCount), buttonSide)
    }

    static func barHeight(for rawLineCount: Int) -> CGFloat {
        contentHeight(for: rawLineCount) + verticalPadding * 2
    }

    static func downloadCollectionBottomInset(for rawLineCount: Int) -> CGFloat {
        barHeight(for: rawLineCount) + bottomPadding * 2
    }
}

// MARK: - Download Share Text Views

final class DownloadShareClipView: NSClipView {
    var allowsDocumentScrolling = false {
        didSet {
            guard !allowsDocumentScrolling else { return }
            var bounds = self.bounds
            bounds.origin = .zero
            self.bounds = bounds
        }
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrainedBounds = super.constrainBoundsRect(proposedBounds)
        if !allowsDocumentScrolling {
            constrainedBounds.origin = .zero
        }
        return constrainedBounds
    }
}

final class DownloadShareTextContainerView: NSView {
    let scrollView = NSScrollView()

    init() {
        super.init(frame: .zero)

        wantsLayer = false
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        true
    }

}

final class DownloadShareNSTextView: NSTextView {
    var placeholder: String = "" {
        didSet {
            needsDisplay = true
        }
    }

    private var shouldDrawPlaceholder: Bool {
        string.isEmpty && !hasMarkedText()
    }

    override var string: String {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard shouldDrawPlaceholder, !placeholder.isEmpty else { return }
        let inset = textContainerInset
        let placeholderContainer = NSTextContainer(size: textContainer?.containerSize ?? NSSize(
            width: max(0, bounds.width - inset.width * 2),
            height: CGFloat.greatestFiniteMagnitude
        ))
        placeholderContainer.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        placeholderContainer.widthTracksTextView = textContainer?.widthTracksTextView ?? true

        let placeholderLayoutManager = NSLayoutManager()
        let placeholderStorage = NSTextStorage(string: placeholder, attributes: placeholderAttributes)
        placeholderLayoutManager.addTextContainer(placeholderContainer)
        placeholderStorage.addLayoutManager(placeholderLayoutManager)

        let glyphRange = placeholderLayoutManager.glyphRange(for: placeholderContainer)
        placeholderLayoutManager.drawGlyphs(forGlyphRange: glyphRange, at: textContainerOrigin)
    }

    private var placeholderAttributes: [NSAttributedString.Key: Any] {
        var attributes = typingAttributes
        attributes[.font] = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        attributes[.foregroundColor] = NSColor.placeholderTextColor
        return attributes
    }

}

// MARK: - Download Share Text Input

enum DownloadShareTextInput {
    @MainActor
    static func make(
        model: ImporterModel,
        isEditable: Bool,
        lineCount: Int,
        focusRequestID: Int,
        resetRequestID: Int
    ) -> (DownloadShareTextContainerView, Coordinator) {
        let coordinator = Coordinator()
        coordinator.model = model
        let containerView = DownloadShareTextContainerView()
        let scrollView = containerView.scrollView
        let clipView = DownloadShareClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = DownloadShareNSTextView()
        textView.delegate = coordinator
        textView.string = model.downloadShareText
        textView.placeholder = "多个链接需要换行"
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: DownloadInputMetrics.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        scrollView.documentView = textView
        coordinator.scrollView = scrollView
        coordinator.textView = textView
        update(
            containerView,
            coordinator: coordinator,
            model: model,
            isEditable: isEditable,
            lineCount: lineCount,
            focusRequestID: focusRequestID,
            resetRequestID: resetRequestID
        )
        return (containerView, coordinator)
    }

    @MainActor
    static func update(
        _ containerView: DownloadShareTextContainerView,
        coordinator: Coordinator,
        model: ImporterModel,
        isEditable: Bool,
        lineCount: Int,
        focusRequestID: Int,
        resetRequestID: Int
    ) {
        let scrollView = containerView.scrollView
        guard let textView = scrollView.documentView as? DownloadShareNSTextView else { return }
        coordinator.model = model
        let allowsTextScrolling = lineCount >= DownloadInputMetrics.maxVisibleLineCount
        coordinator.allowsTextScrolling = allowsTextScrolling
        (scrollView.contentView as? DownloadShareClipView)?.allowsDocumentScrolling = allowsTextScrolling
        scrollView.hasVerticalScroller = allowsTextScrolling
        textView.isVerticallyResizable = allowsTextScrolling
        textView.textContainer?.heightTracksTextView = false
        if coordinator.lastResetRequestID != resetRequestID {
            coordinator.lastResetRequestID = resetRequestID
            coordinator.isApplyingExternalText = true
            textView.string = ""
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            coordinator.isApplyingExternalText = false
        } else if textView.string != model.downloadShareText {
            coordinator.isApplyingExternalText = true
            textView.string = model.downloadShareText
            coordinator.isApplyingExternalText = false
        }
        textView.isEditable = isEditable
        coordinator.updateTextViewLayout(in: scrollView)

        if coordinator.lastFocusRequestID != focusRequestID {
            coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var model: ImporterModel?
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var lastFocusRequestID = 0
        var lastResetRequestID = 0
        var allowsTextScrolling = false
        var isApplyingExternalText = false

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText else { return }
            guard let textView = notification.object as? NSTextView else { return }
            model?.downloadShareText = textView.string
        }

        func updateTextViewLayout(in scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            let contentSize = scrollView.contentSize
            textView.textContainer?.containerSize = NSSize(
                width: contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.frame.size.width = contentSize.width
            if !allowsTextScrolling {
                textView.frame.size.height = contentSize.height
            }

            if allowsTextScrolling {
                if textView.window?.firstResponder === textView {
                    textView.scrollRangeToVisible(textView.selectedRange())
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }
    }

}

// MARK: - Circular Glass Icon Button

final class CircularGlassIconButton: NSView {
    private let glassSurface: NSView
    private let button = NSButton()

    weak var target: AnyObject? {
        get { button.target }
        set { button.target = newValue }
    }

    var action: Selector? {
        get { button.action }
        set { button.action = newValue }
    }

    var isEnabled: Bool {
        get { button.isEnabled }
        set {
            button.isEnabled = newValue
            button.contentTintColor = newValue ? nil : .secondaryLabelColor
        }
    }

    override var toolTip: String? {
        get { button.toolTip }
        set {
            super.toolTip = newValue
            button.toolTip = newValue
        }
    }

    @MainActor
    init(symbolName: String, accessibilityDescription: String) {
        self.glassSurface = Self.makeGlassSurface()
        super.init(frame: .zero)
        setup(symbolName: symbolName, accessibilityDescription: accessibilityDescription)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateCircularGlassRadius()
    }

    @MainActor
    private func setup(symbolName: String, accessibilityDescription: String) {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        glassSurface.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false

        // NSButton's .glass bezel chooses a rounded-rectangle system shape; keep the circle on NSGlassEffectView.
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.controlSize = .regular
        button.setButtonType(.momentaryChange)
        button.isTransparent = false
        button.wantsLayer = false
        button.focusRingType = .none
        button.setAccessibilityLabel(accessibilityDescription)

        addSubview(glassSurface)
        addSubview(button)
        NSLayoutConstraint.activate([
            glassSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassSurface.topAnchor.constraint(equalTo: topAnchor),
            glassSurface.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private static func makeGlassSurface() -> NSView {
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let view = glassClass.init(frame: .zero)
            view.setValue(0, forKey: "style")
            view.setValue(NSColor.controlBackgroundColor.withAlphaComponent(0.08), forKey: "tintColor")
            if view.responds(to: Selector(("setEffectIsInteractive:"))) {
                view.setValue(true, forKey: "effectIsInteractive")
            }
            return view
        }

        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.masksToBounds = true
        return visualEffectView
    }

    private func updateCircularGlassRadius() {
        let radius = min(bounds.width, bounds.height) / 2
        guard radius.isFinite, radius > 0 else { return }
        if glassSurface.responds(to: Selector(("setCornerRadius:"))) {
            glassSurface.setValue(radius, forKey: "cornerRadius")
        }
        glassSurface.layer?.cornerRadius = radius
        glassSurface.layer?.masksToBounds = true
    }
}

// MARK: - Download Bar View

@MainActor
final class DownloadBarView: NSView {
    private let model: ImporterModel
    private let glassSurface: NSView
    private let contentHost = NSView()
    private var textContainer: DownloadShareTextContainerView?
    private var textCoordinator: DownloadShareTextInput.Coordinator?
    private let downloadButton = CircularGlassIconButton(symbolName: AppSymbol.download.normal, accessibilityDescription: "开始下载")
    private var heightConstraint: NSLayoutConstraint?
    private var textInputHeightConstraint: NSLayoutConstraint?
    private var focusRequestID = 0

    init(model: ImporterModel) {
        self.model = model
        self.glassSurface = Self.makeGlassSurface()
        super.init(frame: .zero)
        setupGlassSurface()
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeGlassSurface() -> NSView {
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let view = glassClass.init(frame: .zero)
            view.setValue(18, forKey: "cornerRadius")
            view.setValue(NSColor.controlBackgroundColor.withAlphaComponent(0.10), forKey: "tintColor")
            view.setValue(0, forKey: "style")
            if view.responds(to: Selector(("setEffectIsInteractive:"))) {
                view.setValue(true, forKey: "effectIsInteractive")
            }
            return view
        }

        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 18
        return visualEffectView
    }

    private func setupGlassSurface() {
        glassSurface.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassSurface)
        if glassSurface.responds(to: Selector(("setContentView:"))) {
            glassSurface.setValue(contentHost, forKey: "contentView")
        } else {
            glassSurface.addSubview(contentHost)
            NSLayoutConstraint.activate([
                contentHost.leadingAnchor.constraint(equalTo: glassSurface.leadingAnchor),
                contentHost.trailingAnchor.constraint(equalTo: glassSurface.trailingAnchor),
                contentHost.topAnchor.constraint(equalTo: glassSurface.topAnchor),
                contentHost.bottomAnchor.constraint(equalTo: glassSurface.bottomAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            glassSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassSurface.topAnchor.constraint(equalTo: topAnchor),
            glassSurface.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func setupViews() {
        let rawLineCount = DownloadInputMetrics.rawLineCount(for: model.downloadShareText)
        let input = DownloadShareTextInput.make(
            model: model,
            isEditable: true,
            lineCount: rawLineCount,
            focusRequestID: focusRequestID,
            resetRequestID: model.downloadInputResetID
        )
        textContainer = input.0
        textCoordinator = input.1
        input.0.translatesAutoresizingMaskIntoConstraints = false

        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.toolTip = "开始下载"
        downloadButton.target = self
        downloadButton.action = #selector(startDownload(_:))

        contentHost.addSubview(input.0)
        contentHost.addSubview(downloadButton)
        let heightConstraint = heightAnchor.constraint(equalToConstant: DownloadInputMetrics.barHeight(for: rawLineCount))
        let textInputHeightConstraint = input.0.heightAnchor.constraint(equalToConstant: DownloadInputMetrics.inputHeight(for: rawLineCount))
        self.heightConstraint = heightConstraint
        self.textInputHeightConstraint = textInputHeightConstraint
        NSLayoutConstraint.activate([
            heightConstraint,
            input.0.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: DownloadInputMetrics.leadingPadding),
            input.0.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor, constant: -DownloadInputMetrics.horizontalSpacing),
            input.0.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
            textInputHeightConstraint,
            downloadButton.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -DownloadInputMetrics.trailingPadding - 4),
            downloadButton.bottomAnchor.constraint(equalTo: input.0.bottomAnchor),
            downloadButton.widthAnchor.constraint(equalToConstant: DownloadInputMetrics.buttonSide),
            downloadButton.heightAnchor.constraint(equalToConstant: DownloadInputMetrics.buttonSide)
        ])
    }

    func reload() {
        let rawLineCount = DownloadInputMetrics.rawLineCount(for: model.downloadShareText)
        heightConstraint?.constant = DownloadInputMetrics.barHeight(for: rawLineCount)
        if let textContainer, let textCoordinator {
            DownloadShareTextInput.update(
                textContainer,
                coordinator: textCoordinator,
                model: model,
                isEditable: true,
                lineCount: rawLineCount,
                focusRequestID: focusRequestID,
                resetRequestID: model.downloadInputResetID
            )
            textInputHeightConstraint?.constant = DownloadInputMetrics.inputHeight(for: rawLineCount)
        }
        downloadButton.isEnabled = !model.downloadShareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        downloadButton.isHidden = false
    }

    func updateButtonState() {
        downloadButton.isEnabled = !model.downloadShareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        focusRequestID += 1
        reload()
    }

    @objc private func startDownload(_ sender: Any?) {
        Task { await model.downloadShare() }
    }
}

// MARK: - Download Progress Bar Views

@MainActor
final class DownloadTaskProgressBarView: NSView {
    private let glassSurface: NSView
    private let tintOverlay = NSView()
    private let fillClipView = NSView()
    private let fillView = NSView()
    private let fillEdgeView = NSView()
    private let textLabel = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private var fillWidthConstraint: NSLayoutConstraint?
    private var representedID: UUID?
    private var representedText = ""
    private var currentProgress: CGFloat = 0
    private var displayedProgress: CGFloat = 0

    // Animation queue
    private var isAnimating = false
    private var queuedText: String?
    private var primaryTextVisible = false
    private var primaryTextDeferred = false
    var stackIndex = 0
    var isRemovingFromStack = false

    override init(frame frameRect: NSRect) {
        self.glassSurface = Self.makeGlassSurface()
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateGlassRadius()
        fillWidthConstraint?.constant = max(bounds.width * currentProgress, currentProgress > 0 ? 10 : 0)
    }

    func update(with item: DownloadProgressItem, stackIndex: Int, defersPrimaryText: Bool = false) {
        self.stackIndex = stackIndex
        isRemovingFromStack = false
        let isPrimary = stackIndex == 0
        let isSameItem = representedID == item.id
        let targetFillAlpha = (item.isActive ? 0.82 : 0.30) * [1.0, 0.55, 0.30][min(stackIndex, 2)]
        if isPrimary {
            if defersPrimaryText {
                primaryTextDeferred = true
            }
            primaryTextVisible = !primaryTextDeferred
        } else {
            primaryTextDeferred = false
            primaryTextVisible = false
        }

        // Animate all visual properties together with frame animation
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            if !self.isAnimating || !self.primaryTextVisible {
                textLabel.animator().alphaValue = self.primaryTextVisible ? 1 : 0
            }
            countField.animator().alphaValue = self.primaryTextVisible ? 1 : 0
            tintOverlay.animator().alphaValue = isPrimary ? 0.12 : 0
            fillView.animator().alphaValue = targetFillAlpha
            fillEdgeView.animator().alphaValue = targetFillAlpha
        }

        if isPrimary {
            let targetText = "\(item.title) · \(item.detail)"
            if representedID != item.id || representedText != targetText {
                setText(targetText, animated: isSameItem && primaryTextVisible && !primaryTextDeferred)
                representedID = item.id
                representedText = targetText
            }
            countField.stringValue = item.countText
        }

        let nextProgress = item.isActive ? max(item.progress, 0.04) : item.progress
        animateProgress(to: nextProgress, animated: isSameItem)
    }

    func revealPrimaryText(animated: Bool) {
        guard stackIndex == 0, !isRemovingFromStack else { return }
        primaryTextDeferred = false
        primaryTextVisible = true
        resetTextAnimation(alpha: 0)
        countField.alphaValue = 0
        guard animated else {
            textLabel.alphaValue = 1
            countField.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            textLabel.animator().alphaValue = 1
            countField.animator().alphaValue = 1
        }
    }

    // MARK: - Text animation

    private func setText(_ text: String, animated: Bool) {
        if isAnimating, animated {
            queuedText = text
            return
        }
        guard animated, !representedText.isEmpty else {
            resetTextAnimation(alpha: primaryTextVisible ? 1 : 0)
            textLabel.stringValue = text
            return
        }
        animateText(from: representedText, to: text)
    }

    private func resetTextAnimation(alpha: CGFloat? = nil) {
        isAnimating = false
        queuedText = nil
        for view in subviews where view.tag == 9999 {
            view.removeFromSuperview()
        }
        textLabel.alphaValue = alpha ?? (primaryTextVisible ? 1 : 0)
    }

    private func animateText(from oldText: String, to newText: String) {
        isAnimating = true
        // Remove any stale overlay labels (tag 9999)
        for v in subviews where v.tag == 9999 { v.removeFromSuperview() }

        let hostFrame = convert(textLabel.bounds, from: textLabel)
        let outgoing = makeOverlay(oldText, frame: hostFrame)
        let incoming = makeOverlay(newText, frame: hostFrame.offsetBy(dx: 0, dy: -hostFrame.height))
        incoming.alphaValue = 0
        textLabel.alphaValue = 0

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.50
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0)
            ctx.allowsImplicitAnimation = true
            outgoing.animator().alphaValue = 0
            outgoing.animator().frame = hostFrame.offsetBy(dx: 0, dy: hostFrame.height * 0.35)
            incoming.animator().alphaValue = 1
            incoming.animator().frame = hostFrame
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                outgoing.removeFromSuperview()
                incoming.removeFromSuperview()
                self.textLabel.stringValue = newText
                self.textLabel.alphaValue = self.primaryTextVisible ? 1 : 0
                self.isAnimating = false
                if let next = self.queuedText, self.primaryTextVisible {
                    self.queuedText = nil
                    self.animateText(from: newText, to: next)
                } else {
                    self.queuedText = nil
                }
            }
        }
    }

    private func makeOverlay(_ text: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = textLabel.font
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.wantsLayer = true
        label.frame = frame
        label.tag = 9999
        addSubview(label)
        return label
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        glassSurface.translatesAutoresizingMaskIntoConstraints = false
        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        fillClipView.translatesAutoresizingMaskIntoConstraints = false
        fillView.translatesAutoresizingMaskIntoConstraints = false
        fillEdgeView.translatesAutoresizingMaskIntoConstraints = false
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        countField.translatesAutoresizingMaskIntoConstraints = false

        tintOverlay.wantsLayer = true
        tintOverlay.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        tintOverlay.layer?.cornerRadius = 14
        tintOverlay.layer?.masksToBounds = true
        tintOverlay.alphaValue = 0

        fillClipView.wantsLayer = true
        fillClipView.layer?.backgroundColor = NSColor.clear.cgColor
        fillClipView.layer?.cornerRadius = 14
        fillClipView.layer?.masksToBounds = true

        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = NSColor.white.cgColor
        fillView.layer?.cornerRadius = 0
        fillView.layer?.masksToBounds = false
        fillView.layer?.compositingFilter = nil

        fillEdgeView.wantsLayer = true
        fillEdgeView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.58).cgColor
        fillEdgeView.layer?.compositingFilter = nil
        fillEdgeView.alphaValue = 0

        textLabel.font = .systemFont(ofSize: 12)
        textLabel.textColor = .secondaryLabelColor
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1

        countField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        countField.textColor = .secondaryLabelColor
        countField.alignment = .right
        countField.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(fillClipView)
        fillClipView.addSubview(fillView)
        fillClipView.addSubview(fillEdgeView)
        addSubview(glassSurface)
        addSubview(tintOverlay)
        addSubview(textLabel)
        addSubview(countField)

        let fillWidthConstraint = fillView.widthAnchor.constraint(equalToConstant: 0)
        self.fillWidthConstraint = fillWidthConstraint
        NSLayoutConstraint.activate([
            glassSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassSurface.topAnchor.constraint(equalTo: topAnchor),
            glassSurface.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            tintOverlay.topAnchor.constraint(equalTo: topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            fillClipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fillClipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fillClipView.topAnchor.constraint(equalTo: topAnchor),
            fillClipView.bottomAnchor.constraint(equalTo: bottomAnchor),

            fillView.leadingAnchor.constraint(equalTo: fillClipView.leadingAnchor),
            fillView.topAnchor.constraint(equalTo: fillClipView.topAnchor),
            fillView.bottomAnchor.constraint(equalTo: fillClipView.bottomAnchor),
            fillWidthConstraint,

            fillEdgeView.leadingAnchor.constraint(equalTo: fillView.trailingAnchor, constant: -1.5),
            fillEdgeView.topAnchor.constraint(equalTo: fillClipView.topAnchor),
            fillEdgeView.bottomAnchor.constraint(equalTo: fillClipView.bottomAnchor),
            fillEdgeView.widthAnchor.constraint(equalToConstant: 1.5),

            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textLabel.trailingAnchor.constraint(equalTo: countField.leadingAnchor, constant: -8),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.widthAnchor.constraint(equalToConstant: 52)
        ])
    }

    private static func makeGlassSurface() -> NSView {
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let view = glassClass.init(frame: .zero)
            view.setValue(14, forKey: "cornerRadius")
            view.setValue(NSColor.controlBackgroundColor.withAlphaComponent(0.045), forKey: "tintColor")
            view.setValue(0, forKey: "style")
            return view
        }

        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14
        visualEffectView.layer?.masksToBounds = true
        return visualEffectView
    }

    private func updateGlassRadius() {
        let radius = min(bounds.height / 2, 14)
        if glassSurface.responds(to: Selector(("setCornerRadius:"))) {
            glassSurface.setValue(radius, forKey: "cornerRadius")
        }
        glassSurface.layer?.cornerRadius = radius
        tintOverlay.layer?.cornerRadius = radius
        fillClipView.layer?.cornerRadius = radius
        fillView.layer?.cornerRadius = 0
    }

    private func animateProgress(to progress: CGFloat, animated: Bool) {
        let clampedProgress = min(max(progress, 0), 1)
        currentProgress = clampedProgress
        let width = max(bounds.width * clampedProgress, clampedProgress > 0 ? 10 : 0)
        guard animated else {
            displayedProgress = clampedProgress
            fillWidthConstraint?.constant = width
            layoutSubtreeIfNeeded()
            return
        }
        guard abs(clampedProgress - displayedProgress) > 0.002 else { return }
        displayedProgress = clampedProgress
        fillWidthConstraint?.constant = width
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.82, 0.2, 1)
            context.allowsImplicitAnimation = true
            self.layoutSubtreeIfNeeded()
        }
    }
}

@MainActor
final class DownloadProgressStackView: NSView {
    private var barViewsByID: [UUID: DownloadTaskProgressBarView] = [:]
    private var isAnimatingStackLayout = false
    private let maximumVisibleBars = 3
    private let barHeight: CGFloat = 28
    private let slotYOffset: CGFloat = 10
    private let slotWidthStep: CGFloat = 52
    private let verticalTransitionOffset: CGFloat = 16
    private let slotAlphas: [CGFloat] = [1.0, 0.66, 0.42]

    func update(with items: [DownloadProgressItem], animated: Bool = true) {
        let visibleItems = Array(items.prefix(maximumVisibleBars))
        let visibleIDs = Set(visibleItems.map(\.id))
        var insertedIDs = Set<UUID>()

        for (index, item) in visibleItems.enumerated() where barViewsByID[item.id] == nil {
            let barView = DownloadTaskProgressBarView()
            barView.frame = animated ? initialFrameForBar(at: index) : frameForBar(at: index)
            barView.alphaValue = 0
            barView.isHidden = false
            addSubview(barView)
            barViewsByID[item.id] = barView
            insertedIDs.insert(item.id)
        }

        let removedViews = barViewsByID.filter { !visibleIDs.contains($0.key) }
        for (id, barView) in removedViews {
            barViewsByID[id] = nil
            animateRemoval(of: barView, animated: animated)
        }

        layoutSubtreeIfNeeded()

        var deferredTextIDs: [UUID] = []
        for (index, item) in visibleItems.enumerated() {
            guard let barView = barViewsByID[item.id] else { continue }
            let shouldDeferPrimaryText = animated && index == 0 && (insertedIDs.contains(item.id) || barView.stackIndex != 0)
            if insertedIDs.contains(item.id) {
                barView.frame = initialFrameForBar(at: index)
            }
            barView.update(with: item, stackIndex: index, defersPrimaryText: shouldDeferPrimaryText)
            if shouldDeferPrimaryText {
                deferredTextIDs.append(item.id)
            }
        }

        orderVisibleBars(visibleItems)
        let orderedViews = visibleItems.compactMap { barViewsByID[$0.id] }
        let applyLayout = { (animated: Bool) in
            self.alphaValue = visibleItems.isEmpty ? 0 : 1
            self.isHidden = false
            for (index, barView) in orderedViews.enumerated() {
                let targetFrame = self.frameForBar(at: index)
                let targetAlpha = self.alphaForBar(at: index)
                if animated {
                    barView.animator().frame = targetFrame
                    barView.animator().alphaValue = targetAlpha
                } else {
                    barView.frame = targetFrame
                    barView.alphaValue = targetAlpha
                }
            }
        }

        let shouldHide = visibleItems.isEmpty
        let idsToReveal = deferredTextIDs
        if animated {
            isAnimatingStackLayout = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.36
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.86, 0.22, 1)
                context.allowsImplicitAnimation = true
                applyLayout(true)
            } completionHandler: { [weak self, idsToReveal] in
                Task { @MainActor [weak self, idsToReveal] in
                    guard let self else { return }
                    self.isAnimatingStackLayout = false
                    for id in idsToReveal {
                        self.barViewsByID[id]?.revealPrimaryText(animated: true)
                    }
                    self.isHidden = shouldHide
                }
            }
        } else {
            applyLayout(false)
            for id in idsToReveal {
                barViewsByID[id]?.revealPrimaryText(animated: false)
            }
            isHidden = shouldHide
        }
    }

    override func layout() {
        super.layout()
        guard !isAnimatingStackLayout else { return }
        let orderedBars = subviews.compactMap { $0 as? DownloadTaskProgressBarView }
            .filter { !$0.isRemovingFromStack }
            .sorted { $0.stackIndex < $1.stackIndex }
        for (index, barView) in orderedBars.enumerated() {
            barView.frame = frameForBar(at: index)
        }
    }

    private func frameForBar(at index: Int) -> CGRect {
        let width = max(bounds.width - CGFloat(index) * slotWidthStep, 180)
        let originX = bounds.midX - width / 2
        let originY = CGFloat(index) * slotYOffset
        return CGRect(x: originX, y: originY, width: width, height: barHeight)
    }

    private func initialFrameForBar(at index: Int) -> CGRect {
        frameForBar(at: index).offsetBy(dx: 0, dy: -verticalTransitionOffset)
    }

    private func alphaForBar(at index: Int) -> CGFloat {
        slotAlphas[min(index, slotAlphas.count - 1)]
    }

    private func orderVisibleBars(_ items: [DownloadProgressItem]) {
        for item in items.reversed() {
            guard let barView = barViewsByID[item.id] else { continue }
            addSubview(barView, positioned: .above, relativeTo: nil)
        }
    }

    private func animateRemoval(of barView: DownloadTaskProgressBarView, animated: Bool) {
        barView.isRemovingFromStack = true
        let removedFrame = barView.frame.offsetBy(dx: 0, dy: -verticalTransitionOffset)
        let applyRemoval = { (animated: Bool) in
            if animated {
                barView.animator().alphaValue = 0
                barView.animator().frame = removedFrame
            } else {
                barView.alphaValue = 0
                barView.frame = removedFrame
            }
        }
        guard animated else {
            applyRemoval(false)
            barView.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0, 0.67, 0)
            context.allowsImplicitAnimation = true
            applyRemoval(true)
        } completionHandler: {
            DispatchQueue.main.async {
                barView.removeFromSuperview()
            }
        }
    }
}

// MARK: - Download Page Controller

@MainActor
final class DownloadPageController: NSViewController {
    private let model: ImporterModel
    private let emptyView: EmptyStateView
    private let downloadBar: DownloadBarView
    private let progressStack = DownloadProgressStackView()
    private var scrollView: NSScrollView?
    private var coordinator: DownloadCollectionView.Coordinator?
    private var isVisible = false
    private var cancellables = Set<AnyCancellable>()

    init(model: ImporterModel) {
        self.model = model
        self.emptyView = EmptyStateView(title: "还没有下载内容", symbolName: AppSymbol.download.normal, message: model.downloadStatusText)
        self.downloadBar = DownloadBarView(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = ThemedBackgroundView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        downloadBar.translatesAutoresizingMaskIntoConstraints = false
        progressStack.translatesAutoresizingMaskIntoConstraints = false

        let bottomInset = DownloadInputMetrics.downloadCollectionBottomInset(
            for: DownloadInputMetrics.rawLineCount(for: model.downloadShareText)
        )
        let pair = DownloadCollectionView.make(
            items: model.visibleDownloadItems,
            filter: model.downloadFilter,
            model: model,
            scrollToTopRequestID: model.downloadScrollToTopRequestID,
            bottomContentInset: bottomInset,
            isVisible: isVisible
        )
        scrollView = pair.0
        coordinator = pair.1
        pair.0.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(emptyView)
        view.addSubview(pair.0, positioned: .below, relativeTo: emptyView)
        view.addSubview(progressStack)
        view.addSubview(downloadBar)

        let preferredDownloadBarWidth = downloadBar.widthAnchor.constraint(equalToConstant: DownloadInputMetrics.barWidth)
        preferredDownloadBarWidth.priority = .defaultHigh
        let preferredProgressWidth = progressStack.widthAnchor.constraint(equalTo: downloadBar.widthAnchor, multiplier: DownloadInputMetrics.progressWidthMultiplier)
        preferredProgressWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pair.0.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pair.0.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pair.0.topAnchor.constraint(equalTo: view.topAnchor),
            pair.0.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            downloadBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            downloadBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -DownloadInputMetrics.bottomPadding),
            preferredDownloadBarWidth,
            downloadBar.widthAnchor.constraint(lessThanOrEqualToConstant: DownloadInputMetrics.barWidth),
            downloadBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: DownloadInputMetrics.horizontalPagePadding),
            downloadBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -DownloadInputMetrics.horizontalPagePadding),
            progressStack.centerXAnchor.constraint(equalTo: downloadBar.centerXAnchor),
            progressStack.bottomAnchor.constraint(equalTo: downloadBar.topAnchor, constant: -DownloadInputMetrics.progressBottomSpacing),
            preferredProgressWidth,
            progressStack.widthAnchor.constraint(lessThanOrEqualToConstant: DownloadInputMetrics.progressMaxWidth),
            progressStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: DownloadInputMetrics.horizontalPagePadding),
            progressStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -DownloadInputMetrics.horizontalPagePadding),
            progressStack.heightAnchor.constraint(equalToConstant: DownloadInputMetrics.progressStackHeight)
        ])
        progressStack.update(with: model.downloadProgressItems, animated: false)

        scrollView?.isHidden = model.visibleDownloadItems.isEmpty
        emptyView.isHidden = !model.visibleDownloadItems.isEmpty

        model.$visibleDownloadItemsCache
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        model.$downloadShareText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        model.$isDownloading
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.downloadBar.reload() }
            .store(in: &cancellables)

        model.$downloadProgressItems
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadProgress() }
            .store(in: &cancellables)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        view.isHidden = !visible
        coordinator?.scrollPosition.setActive(visible)
    }

    func reload() {
        downloadBar.reload()
        emptyView.message = model.downloadStatusText
        let rawLineCount = DownloadInputMetrics.rawLineCount(for: model.downloadShareText)
        let bottomInset = DownloadInputMetrics.downloadCollectionBottomInset(
            for: rawLineCount
        )

        if model.visibleDownloadItems.isEmpty {
            scrollView?.isHidden = true
            emptyView.isHidden = false
        } else {
            emptyView.isHidden = true
            scrollView?.isHidden = false
            guard let scrollView, let coordinator else { return }
            DownloadCollectionView.update(
                scrollView: scrollView,
                coordinator: coordinator,
                items: model.visibleDownloadItems,
                filter: model.downloadFilter,
                model: model,
                scrollToTopRequestID: model.downloadScrollToTopRequestID,
                bottomContentInset: bottomInset,
                isVisible: isVisible
            )
        }
    }

    private func reloadProgress() {
        progressStack.update(with: model.downloadProgressItems, animated: true)
    }
}
