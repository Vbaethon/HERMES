import AppKit

final class FinderStyleSidebarController: NSViewController {
    private let coordinator: Coordinator
    private var sections: [SidebarSection]
    private var selection: SidebarSection?
    private var count: (SidebarSection) -> Int?
    private let onSelect: (SidebarSection) -> Void

    init(
        sections: [SidebarSection],
        selection: SidebarSection?,
        count: @escaping (SidebarSection) -> Int?,
        onSelect: @escaping (SidebarSection) -> Void
    ) {
        self.sections = sections
        self.selection = selection
        self.count = count
        self.onSelect = onSelect
        self.coordinator = Coordinator()
        super.init(nibName: nil, bundle: nil)
        coordinator.controller = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let tableView = FinderSidebarTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.style = .sourceList
        tableView.rowSizeStyle = .default
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.focusRingType = .none
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.action = #selector(Coordinator.rowClicked(_:))

        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        coordinator.tableView = tableView
        coordinator.startObservingSystemRowSizeChanges()
        coordinator.reloadDataAndApplySelection()
    }

    func update(
        sections: [SidebarSection],
        selection: SidebarSection?,
        count: @escaping (SidebarSection) -> Int?
    ) {
        self.sections = sections
        self.selection = selection
        self.count = count
        coordinator.reloadDataAndApplySelection()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("FinderStyleSidebarColumn")
        static let cellIdentifier = NSUserInterfaceItemIdentifier("FinderStyleSidebarCell")

        weak var controller: FinderStyleSidebarController?
        weak var tableView: NSTableView?
        private var isApplyingSelection = false
        private var userDefaultsObserver: NotificationObserver?

        deinit {
            userDefaultsObserver?.invalidate()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            controller?.sections.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let controller, controller.sections.indices.contains(row) else { return nil }

            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? FinderSidebarCellView
                ?? FinderSidebarCellView(identifier: Self.cellIdentifier)
            let section = controller.sections[row]
            cell.configure(
                title: section.title,
                symbolName: section.symbolName,
                count: controller.count(section),
                isSelected: section == controller.selection,
                rowSizeStyle: tableView.effectiveRowSizeStyle
            )
            return cell
        }

        func startObservingSystemRowSizeChanges() {
            guard userDefaultsObserver == nil else { return }
            let observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.reloadDataAndApplySelection()
                }
            }
            userDefaultsObserver = NotificationObserver(observer)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            selectRow(tableView.selectedRow, allowsRepeatedSelection: false)
        }

        @objc func rowClicked(_ sender: NSTableView) {
            selectRow(sender.clickedRow, allowsRepeatedSelection: true)
        }

        func reloadDataAndApplySelection() {
            guard let tableView else { return }
            isApplyingSelection = true
            tableView.reloadData()
            applySelection()
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingSelection = false
            }
        }

        private func applySelection() {
            guard let tableView, let controller else { return }
            let selectedIndex = controller.sections.firstIndex { $0 == controller.selection } ?? 0
            guard tableView.selectedRow != selectedIndex else { return }

            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }

        private func selectRow(_ row: Int, allowsRepeatedSelection: Bool) {
            guard let controller, controller.sections.indices.contains(row) else { return }
            let section = controller.sections[row]
            guard allowsRepeatedSelection || section != controller.selection else { return }
            controller.onSelect(section)
        }
    }
}

private final class NotificationObserver: @unchecked Sendable {
    private var observer: NSObjectProtocol?

    init(_ observer: NSObjectProtocol) {
        self.observer = observer
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
    }
}

private final class FinderSidebarTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool {
        false
    }
}

private final class FinderSidebarCellView: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private var symbolWidthConstraint: NSLayoutConstraint?
    private var symbolHeightConstraint: NSLayoutConstraint?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.imageScaling = .scaleProportionallyUpOrDown

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail

        countField.translatesAutoresizingMaskIntoConstraints = false
        countField.alignment = .right
        countField.textColor = .secondaryLabelColor
        countField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        addSubview(symbolView)
        addSubview(titleField)
        addSubview(countField)

        imageView = symbolView
        textField = titleField

        let symbolWidthConstraint = symbolView.widthAnchor.constraint(equalToConstant: 16)
        let symbolHeightConstraint = symbolView.heightAnchor.constraint(equalToConstant: 16)
        self.symbolWidthConstraint = symbolWidthConstraint
        self.symbolHeightConstraint = symbolHeightConstraint

        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolWidthConstraint,
            symbolHeightConstraint,

            titleField.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 7),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            countField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 8),
            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor),
            countField.widthAnchor.constraint(greaterThanOrEqualToConstant: 16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, symbolName: String, count: Int?, isSelected: Bool, rowSizeStyle: NSTableView.RowSizeStyle) {
        let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        symbolImage?.isTemplate = true
        symbolView.image = symbolImage
        symbolView.contentTintColor = .controlAccentColor
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: isSelected ? .semibold : .regular)
        updateSymbolMetrics(for: rowSizeStyle)

        if let count {
            countField.stringValue = count.formatted()
            countField.isHidden = false
        } else {
            countField.stringValue = ""
            countField.isHidden = true
        }
    }

    private func updateSymbolMetrics(for rowSizeStyle: NSTableView.RowSizeStyle) {
        let dimension: CGFloat
        switch rowSizeStyle {
        case .small:
            dimension = 14
        case .medium:
            dimension = 16
        case .large:
            dimension = 20
        default:
            dimension = 16
        }
        symbolWidthConstraint?.constant = dimension
        symbolHeightConstraint?.constant = dimension
    }
}
