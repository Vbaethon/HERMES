import AppKit

class EmptyStateView: NSView {
    private let symbolView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let messageField = NSTextField(labelWithString: "")

    var message: String {
        get { messageField.stringValue }
        set {
            messageField.stringValue = newValue
            messageField.isHidden = newValue.isEmpty
        }
    }

    init(title: String, symbolName: String, message: String) {
        super.init(frame: .zero)
        symbolView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        messageField.stringValue = message
        messageField.isHidden = message.isEmpty
        messageField.textColor = .secondaryLabelColor
        messageField.alignment = .center
        messageField.lineBreakMode = .byTruncatingTail
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayout() {
        let stackView = NSStackView(views: [symbolView, titleField, messageField])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 10
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            symbolView.widthAnchor.constraint(equalToConstant: 54),
            symbolView.heightAnchor.constraint(equalToConstant: 54)
        ])
    }
}

final class DropZoneView: EmptyStateView {
    private weak var model: ImporterModel?
    private var isDragTargeted = false {
        didSet {
            needsDisplay = true
        }
    }

    override var message: String {
        get { "" }
        set { }
    }

    init(model: ImporterModel) {
        self.model = model
        super.init(title: "拖入文件或者手动添加", symbolName: AppSymbol.dropZone, message: "")
        registerForDraggedTypes([.fileURL])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let borderWidth = min(420, max(260, bounds.width - 56))
        let borderHeight = min(240, max(180, bounds.height - 56))
        let borderRect = NSRect(
            x: bounds.midX - borderWidth / 2,
            y: bounds.midY - borderHeight / 2,
            width: borderWidth,
            height: borderHeight
        )
        let path = NSBezierPath(roundedRect: borderRect, xRadius: 14, yRadius: 14)
        let dashPattern: [CGFloat] = [7, 5]
        path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        path.lineWidth = isDragTargeted ? 2 : 1

        let borderColor = isDragTargeted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
        borderColor.setStroke()
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsFileURLs(from: sender) else {
            return []
        }
        isDragTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragTargeted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDragTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted = false
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else {
            return false
        }
        model?.addFiles(urls)
        return true
    }

    private func acceptsFileURLs(from sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }
}
