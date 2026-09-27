import AppKit
import Combine

final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    init(model: ImporterModel) {
        let controller = SettingsViewController(model: model)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "合成与导入"
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 780, height: 480))
        window.contentMinSize = NSSize(width: 680, height: 360)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "HermesSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        controller.splitView.setPosition(220, ofDividerAt: 0)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        FinderStyleSidebarController.toolbarDefaultItemIdentifiers + [.flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == .sidebarTrackingSeparator,
              let controller = contentViewController as? NSSplitViewController else { return nil }
        return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: controller.splitView, dividerIndex: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class SettingsViewController: NSSplitViewController {
    private enum Category: Int, CaseIterable, SidebarDestination {
        case synthesis, completed
        var title: String { self == .synthesis ? "合成与导入" : "已完成" }
        var symbolName: String { self == .synthesis ? "photo.badge.plus" : "checkmark.circle" }
    }

    private let model: ImporterModel
    private lazy var sidebar = NativeSidebarController<Category>(
        sections: Category.allCases, selection: .synthesis, count: { _ in nil }, accessibilityLabel: "设置分类",
        onSelect: { [weak self] category in self?.showCategory(category) }
    )
    private let importToPhotos = NSSwitch()
    private let addToAlbum = NSSwitch()
    private let completedAddToAlbum = NSSwitch()
    private var panes: [Category: NSView] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(model: ImporterModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarItem = sidebar.makeSplitViewItem()
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 280
        sidebarItem.preferredThicknessFraction = 0.28
        sidebarItem.canCollapseFromWindowResize = false
        addSplitViewItem(sidebarItem)

        let detail = NSViewController()
        detail.view = NSView()
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 460
        detailItem.automaticallyAdjustsSafeAreaInsets = true
        addSplitViewItem(detailItem)
        for category in Category.allCases {
            let pane = makePane(category)
            pane.translatesAutoresizingMaskIntoConstraints = false
            detail.view.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.topAnchor, constant: 28),
                pane.leadingAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
                pane.trailingAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
                pane.bottomAnchor.constraint(lessThanOrEqualTo: detail.view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
            ])
            panes[category] = pane
        }
        showCategory(.synthesis)
        reloadFromModel()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadFromModel() }
            .store(in: &cancellables)
    }

    private func showCategory(_ category: Category) {
        sidebar.update(sections: Category.allCases, selection: category, count: { _ in nil })
        panes.forEach { $0.value.isHidden = $0.key != category }
        view.window?.title = category.title
    }

    private func makePane(_ category: Category) -> NSView {
        let rows: [[NSView]]
        switch category {
        case .synthesis:
            rows = [
                makeRow("合成后自动导入“照片”", help: "将合成的 Live Photo 添加到“照片”图库。", control: importToPhotos, identifier: "settings.importToPhotos"),
                makeRow("加入 HERMES 相簿", help: "自动导入时，同时添加到 HERMES 相簿。", control: addToAlbum, identifier: "settings.addToAlbum")
            ]
        case .completed:
            rows = [makeRow("加入 HERMES 相簿", help: "从“已完成”导入时，同时添加到 HERMES 相簿。", control: completedAddToAlbum, identifier: "settings.completedAddToAlbum")]
        }
        var gridRows: [[NSView]] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
                gridRows.append([separator, NSGridCell.emptyContentView])
            }
            gridRows.append(row)
        }
        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 16
        grid.columnSpacing = 24
        grid.column(at: 0).xPlacement = .fill
        grid.column(at: 1).xPlacement = .trailing
        // Reserve only the switch's intrinsic width. Otherwise NSGridView gives
        // the control column spare space and wraps the explanation prematurely.
        grid.column(at: 1).width = rows[0][1].fittingSize.width
        for row in stride(from: 1, to: gridRows.count, by: 2) {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: row, length: 1))
        }
        grid.yPlacement = .center
        grid.translatesAutoresizingMaskIntoConstraints = false
        // NSBox.primary draws the platform's standard group; no custom fill,
        // borders, rounded paths, layers or drawing overrides are used.
        let group = NSBox()
        group.title = "照片"
        group.titlePosition = .noTitle
        group.boxType = .primary
        let content = group.contentView!
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        let heading = NSTextField(labelWithString: "照片")
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let section = NSStackView(views: [heading, group])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        group.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makeRow(_ title: String, help: String, control: NSSwitch, identifier: String) -> [NSView] {
        let label = NSTextField(wrappingLabelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        let description = NSTextField(wrappingLabelWithString: help)
        description.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        description.textColor = .secondaryLabelColor
        let text = NSStackView(views: [label, description])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        description.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        description.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        control.identifier = NSUserInterfaceItemIdentifier(identifier)
        control.setAccessibilityLabel(title)
        control.setAccessibilityHelp(help)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.target = self
        control.action = #selector(toggleChanged(_:))
        return [text, control]
    }

    private func reloadFromModel() {
        importToPhotos.state = model.importToPhotos ? .on : .off
        addToAlbum.state = model.addToAlbum ? .on : .off
        addToAlbum.isEnabled = model.importToPhotos
        completedAddToAlbum.state = model.completedAddToAlbum ? .on : .off
    }

    @objc private func toggleChanged(_ sender: NSSwitch) {
        switch sender {
        case importToPhotos: model.importToPhotos = sender.state == .on
        case addToAlbum: model.addToAlbum = sender.state == .on
        case completedAddToAlbum: model.completedAddToAlbum = sender.state == .on
        default: return
        }
        reloadFromModel()
    }
}
