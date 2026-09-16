import AppKit
import Combine

@MainActor
final class NativeWindowToolbarController: NSObject, NSToolbarDelegate {
    var model: ImporterModel
    var windowTitle: String
    var windowSubtitle: String
    let clearQueue: () -> Void
    var clearCompleted: () -> Void
    var clearDownloads: () -> Void
    var presentImportPanel: () -> Void
    var presentFolderChooser: () -> Void

    private enum ID {
        static let toolbar = "HermesNativeToolbar"
        static let filter = NSToolbarItem.Identifier("Hermes.Filter")
        static let refresh = NSToolbarItem.Identifier("Hermes.Refresh")
        static let openFolder = NSToolbarItem.Identifier("Hermes.OpenFolder")
        static let chooseFolder = NSToolbarItem.Identifier("Hermes.ChooseFolder")
        static let importToPhotos = NSToolbarItem.Identifier("Hermes.ImportToPhotos")
        static let addToAlbum = NSToolbarItem.Identifier("Hermes.AddToAlbum")
        static let clear = NSToolbarItem.Identifier("Hermes.Clear")
        static let addFiles = NSToolbarItem.Identifier("Hermes.AddFiles")
        static let importCompleted = NSToolbarItem.Identifier("Hermes.ImportCompleted")
        static let compose = NSToolbarItem.Identifier("Hermes.Compose")
    }

    private weak var toolbar: NSToolbar?
    private var installedWindow: NSWindow?
    private var lastToolbarState: ToolbarState?

    private struct ToolbarState: Equatable {
            var importToPhotos: Bool
            var addToAlbum: Bool
            var addToAlbumEnabled: Bool
            var clearEnabled: Bool
            var clearLabel: String
            var clearHelp: String
            var importCompletedEnabled: Bool
            var composeEnabled: Bool
            var completedFilter: CompletedFilter
            var downloadFilter: DownloadFilter
        }

    init(
        model: ImporterModel,
        windowTitle: String,
        windowSubtitle: String,
        clearQueue: @escaping () -> Void,
        clearCompleted: @escaping () -> Void,
        clearDownloads: @escaping () -> Void,
        presentImportPanel: @escaping () -> Void,
        presentFolderChooser: @escaping () -> Void
    ) {
        self.model = model
        self.windowTitle = windowTitle
        self.windowSubtitle = windowSubtitle
        self.clearQueue = clearQueue
        self.clearCompleted = clearCompleted
        self.clearDownloads = clearDownloads
        self.presentImportPanel = presentImportPanel
        self.presentFolderChooser = presentFolderChooser
        super.init()
    }

    private var pageToolbarIdentifier: NSToolbar.Identifier {
        let page: String
        switch model.selection ?? .queue {
        case .queue: page = "Queue"
        case .downloads: page = "Downloads"
        case .completed: page = "Completed"
        }
        return NSToolbar.Identifier("\(ID.toolbar).\(page)")
    }

    func installToolbar(in window: NSWindow?) {
        guard let window else { return }
        installedWindow = window
        configureWindowChrome(window)
        if let existing = window.toolbar, existing.identifier == pageToolbarIdentifier {
            toolbar = existing
            existing.delegate = self
        } else {
            let next = NSToolbar(identifier: pageToolbarIdentifier)
            next.delegate = self
            next.displayMode = .iconOnly
            next.allowsUserCustomization = true
            next.autosavesConfiguration = true
            next.centeredItemIdentifier = defaultIdentifiers.contains(ID.filter) ? ID.filter : nil
            window.toolbar = next
            toolbar = next
        }
        lastToolbarState = nil
        if let toolbar { reloadVisibleItemState(in: toolbar) }
    }

    private func configureWindowChrome(_ window: NSWindow) {
        window.isRestorable = false
        SystemWindowBackgroundController.configureMainWindow(window)
    }

    func reloadToolbarIfNeeded() {
        guard let window = installedWindow else { return }
        guard let toolbar, toolbar.identifier == pageToolbarIdentifier else {
            installToolbar(in: window)
            return
        }
        reloadVisibleItemState(in: toolbar)
    }

        private func reloadVisibleItemState(in toolbar: NSToolbar) {
            for item in toolbar.items where item.itemIdentifier == ID.compose {
                item.toolTip = composeHelp
            }
            let state = currentToolbarState
            guard let previousState = lastToolbarState else {
                updateAllVisibleItemState(in: toolbar, state: state)
                lastToolbarState = state
                return
            }

            for item in toolbar.items {
                switch item.itemIdentifier {
                case ID.importToPhotos:
                    if state.importToPhotos != previousState.importToPhotos {
                        updateToggleItem(item, symbol: AppSymbol.importToPhotos, label: "合成后自动导入“照片”", state: state.importToPhotos, isEnabled: true)
                    }
                case ID.addToAlbum:
                    if state.addToAlbum != previousState.addToAlbum || state.addToAlbumEnabled != previousState.addToAlbumEnabled {
                        updateToggleItem(item, symbol: AppSymbol.addToAlbum, label: "导入时加入 HERMES 相簿", state: state.addToAlbum, isEnabled: state.addToAlbumEnabled)
                    }
                case ID.clear:
                    if state.clearEnabled != previousState.clearEnabled {
                        item.isEnabled = state.clearEnabled
                        item.image = buttonSymbolImage(AppSymbol.clear, isEnabled: state.clearEnabled, label: state.clearLabel)
                    }
                    if state.clearLabel != previousState.clearLabel {
                        item.label = state.clearLabel
                        item.paletteLabel = state.clearLabel
                    }
                    if state.clearHelp != previousState.clearHelp {
                        item.toolTip = state.clearHelp
                    }
                case ID.importCompleted:
                    if state.importCompletedEnabled != previousState.importCompletedEnabled {
                        item.isEnabled = state.importCompletedEnabled
                        item.image = buttonSymbolImage(AppSymbol.importCompleted, isEnabled: state.importCompletedEnabled, label: "导入“照片”")
                    }
                case ID.compose:
                    if state.composeEnabled != previousState.composeEnabled {
                        item.isEnabled = state.composeEnabled
                        item.image = buttonSymbolImage(AppSymbol.composeLivePhoto, isEnabled: state.composeEnabled, label: "合成 Live Photo")
                    }
                case ID.filter:
                    if state.completedFilter != previousState.completedFilter || state.downloadFilter != previousState.downloadFilter {
                        updateFilterControl(item.view, state: state)
                    }
                default:
                    break
                }
            }
            lastToolbarState = state
        }

        private func updateAllVisibleItemState(in toolbar: NSToolbar, state: ToolbarState) {
            for item in toolbar.items {
                switch item.itemIdentifier {
                case ID.importToPhotos:
                    updateToggleItem(item, symbol: AppSymbol.importToPhotos, label: "合成后自动导入“照片”", state: state.importToPhotos, isEnabled: true)
                case ID.addToAlbum:
                    updateToggleItem(item, symbol: AppSymbol.addToAlbum, label: "导入时加入 HERMES 相簿", state: state.addToAlbum, isEnabled: state.addToAlbumEnabled)
                case ID.clear:
                    item.isEnabled = state.clearEnabled
                    item.image = buttonSymbolImage(AppSymbol.clear, isEnabled: state.clearEnabled, label: state.clearLabel)
                    item.label = state.clearLabel
                    item.paletteLabel = state.clearLabel
                    item.toolTip = state.clearHelp
                case ID.importCompleted:
                    item.isEnabled = state.importCompletedEnabled
                    item.image = buttonSymbolImage(AppSymbol.importCompleted, isEnabled: state.importCompletedEnabled, label: "导入“照片”")
                case ID.compose:
                    item.isEnabled = state.composeEnabled
                    item.image = buttonSymbolImage(AppSymbol.composeLivePhoto, isEnabled: state.composeEnabled, label: "合成 Live Photo")
                case ID.filter:
                    updateFilterControl(item.view, state: state)
                default:
                    break
                }
            }
        }

        private var currentToolbarState: ToolbarState {
            ToolbarState(
                importToPhotos: model.importToPhotos,
                addToAlbum: addToAlbumState,
                addToAlbumEnabled: addToAlbumEnabled,
                clearEnabled: clearEnabled,
                clearLabel: clearLabel,
                clearHelp: clearHelp,
                importCompletedEnabled: !model.selectedCompletedIDs.isEmpty && !model.isImportingCompleted,
                composeEnabled: composeEnabled,
                completedFilter: model.completedFilter,
                downloadFilter: model.downloadFilter
            )
        }

        private func updateFilterControl(_ view: NSView?, state: ToolbarState) {
            guard let control = view as? NSSegmentedControl else { return }
            switch model.selection ?? .queue {
            case .completed:
                control.selectedSegment = CompletedFilter.allCases.firstIndex(of: state.completedFilter) ?? 0
            case .downloads:
                control.selectedSegment = DownloadFilter.allCases.firstIndex(of: state.downloadFilter) ?? 0
            case .queue:
                break
            }
        }

        private func updateToggleItem(_ item: NSToolbarItem, symbol: AppSymbol.Stateful, label: String, state: Bool, isEnabled: Bool) {
            item.isEnabled = isEnabled
            item.image = symbolImage(symbol, isActive: state, isEnabled: isEnabled, label: label)
            item.toolTip = "\(label)：\(state ? "已开启" : "已关闭")"
            if let button = item.view as? NSButton {
                button.image = item.image
                button.state = state ? .on : .off
                button.isEnabled = isEnabled
                button.toolTip = item.toolTip
                button.setAccessibilityLabel(label)
            }
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            Array(Set(defaultIdentifiers + [.space, .flexibleSpace]))
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            defaultIdentifiers
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            switch itemIdentifier {
            case ID.filter:
                return filterItem()
            case ID.refresh:
                return buttonItem(itemIdentifier, symbol: AppSymbol.refresh, label: "刷新", help: refreshHelp, action: #selector(refresh(_:)), isEnabled: true)
            case ID.openFolder:
                return buttonItem(itemIdentifier, symbol: AppSymbol.openFolder, label: "打开文件夹", help: openFolderHelp, action: #selector(openFolder(_:)), isEnabled: true)
            case ID.chooseFolder:
                return buttonItem(itemIdentifier, symbol: AppSymbol.chooseFolder, label: chooseFolderHelp, help: chooseFolderHelp, action: #selector(chooseFolder(_:)), isEnabled: true)
            case ID.importToPhotos:
                return toggleItem(itemIdentifier, symbol: AppSymbol.importToPhotos, label: "合成后自动导入“照片”", help: "导入系统相册", state: model.importToPhotos, action: #selector(toggleImportToPhotos(_:)), isEnabled: true)
            case ID.addToAlbum:
                return toggleItem(itemIdentifier, symbol: AppSymbol.addToAlbum, label: "导入时加入 HERMES 相簿", help: "添加到相簿", state: addToAlbumState, action: #selector(toggleAddToAlbum(_:)), isEnabled: addToAlbumEnabled)
            case ID.clear:
                return buttonItem(itemIdentifier, symbol: AppSymbol.clear, label: clearLabel, help: clearHelp, action: #selector(clear(_:)), isEnabled: clearEnabled)
            case ID.addFiles:
                return buttonItem(itemIdentifier, symbol: AppSymbol.addFiles, label: "添加文件…", help: "选择要添加的照片、视频或文件夹", action: #selector(addFiles(_:)), isEnabled: true)
            case ID.importCompleted:
                return buttonItem(itemIdentifier, symbol: AppSymbol.importCompleted, label: "导入“照片”", help: "将选中的项目导入系统“照片”App", action: #selector(importCompleted(_:)), isEnabled: !model.selectedCompletedIDs.isEmpty && !model.isImportingCompleted)
            case ID.compose:
                return buttonItem(itemIdentifier, symbol: AppSymbol.composeLivePhoto, label: "合成 Live Photo", help: composeHelp, action: #selector(compose(_:)), isEnabled: composeEnabled)
            default:
                return nil
            }
        }

        private var defaultIdentifiers: [NSToolbarItem.Identifier] {
            switch model.selection ?? .queue {
            case .queue:
                FinderStyleSidebarController.toolbarDefaultItemIdentifiers + [.flexibleSpace, ID.addFiles, .space, ID.importToPhotos, ID.addToAlbum, .space, ID.clear, ID.compose]
            case .downloads:
                FinderStyleSidebarController.toolbarDefaultItemIdentifiers + [ID.filter, .flexibleSpace, ID.refresh, ID.openFolder, ID.chooseFolder, .space, ID.importToPhotos, ID.addToAlbum, .space, ID.clear, ID.compose]
            case .completed:
                FinderStyleSidebarController.toolbarDefaultItemIdentifiers + [ID.filter, .flexibleSpace, ID.refresh, ID.openFolder, ID.chooseFolder, .space, ID.addToAlbum, .space, ID.clear, ID.importCompleted]
            }
        }

        private func buttonItem(_ identifier: NSToolbarItem.Identifier, symbol: AppSymbol.Stateful, label: String, help: String, action: Selector, isEnabled: Bool) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.paletteLabel = label
            item.toolTip = help
            item.image = buttonSymbolImage(symbol, isEnabled: isEnabled, label: label)
            item.target = self
            item.action = action
            item.isEnabled = isEnabled
            return item
        }

        private func toggleItem(_ identifier: NSToolbarItem.Identifier, symbol: AppSymbol.Stateful, label: String, help: String, state: Bool, action: Selector, isEnabled: Bool) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = label
            item.paletteLabel = label
            item.toolTip = help
            item.image = symbolImage(symbol, isActive: state, isEnabled: isEnabled, label: label)
            item.target = self
            item.action = action
            item.isEnabled = isEnabled
            let button = ToolbarToggleButton()
            button.toolbarItem = item
            button.actionTarget = self
            button.forwardedAction = action
            button.setButtonType(.toggle)
            button.bezelStyle = .texturedRounded
            button.imagePosition = .imageOnly
            button.target = button
            button.action = #selector(ToolbarToggleButton.forwardAction(_:))
            button.frame.size = NSSize(width: 32, height: 28)
            item.view = button
            updateToggleItem(item, symbol: symbol, label: label, state: state, isEnabled: isEnabled)
            return item
        }

        private func symbolImage(_ symbol: AppSymbol.Stateful, isActive: Bool, isEnabled: Bool, label: String) -> NSImage {
            let symbolName = symbol.name(isActive: isActive, isEnabled: isEnabled)
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
                ?? NSImage(systemSymbolName: symbol.normal, accessibilityDescription: label)
                ?? NSImage()
            guard isEnabled else {
                let configuration = NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
                return image.withSymbolConfiguration(configuration) ?? image
            }
            return image
        }

        private func buttonSymbolImage(_ symbol: AppSymbol.Stateful, isEnabled: Bool, label: String) -> NSImage {
            let image = NSImage(systemSymbolName: symbol.normal, accessibilityDescription: label)
                ?? NSImage()
            guard isEnabled else {
                let configuration = NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])
                return image.withSymbolConfiguration(configuration) ?? image
            }
            return image
        }

        private func filterItem() -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: ID.filter)
            item.label = "筛选"
            item.paletteLabel = "筛选"
            item.view = makeFilterControl()
            return item
        }

        private func makeFilterControl() -> NSSegmentedControl {
            switch model.selection ?? .queue {
            case .completed:
                let control = NSSegmentedControl(labels: CompletedFilter.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(completedFilterChanged(_:)))
                control.selectedSegment = CompletedFilter.allCases.firstIndex(of: model.completedFilter) ?? 0
                control.setAccessibilityLabel("筛选")
                control.frame.size = control.fittingSize
                return control
            case .downloads:
                let control = NSSegmentedControl(labels: DownloadFilter.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(downloadFilterChanged(_:)))
                control.selectedSegment = DownloadFilter.allCases.firstIndex(of: model.downloadFilter) ?? 0
                control.setAccessibilityLabel("筛选")
                control.frame.size = control.fittingSize
                return control
            case .queue:
                return NSSegmentedControl()
            }
        }

        private var addToAlbumState: Bool {
            switch model.selection ?? .queue {
            case .completed:
                model.completedAddToAlbum
            case .queue, .downloads:
                model.addToAlbum
            }
        }

        private var addToAlbumEnabled: Bool {
            switch model.selection ?? .queue {
            case .queue, .downloads, .completed:
                model.importToPhotos
            }
        }

        private var clearEnabled: Bool {
            switch model.selection ?? .queue {
            case .queue:
                model.canClearQueue
            case .downloads:
                model.canClearVisibleDownloads
            case .completed:
                model.canClearVisibleCompleted
            }
        }

        private var composeEnabled: Bool {
            model.canComposeCurrentPage
        }

        private var clearLabel: String {
            switch model.selection ?? .queue {
            case .queue:
                model.selectedPairIDs.isEmpty ? "清空列表" : "移除选中项目"
            case .downloads:
                model.selectedDownloadItemIDs.isEmpty ? "清空当前筛选记录…" : "移除选中记录…"
            case .completed:
                model.selectedCompletedIDs.isEmpty ? "清空当前筛选记录…" : "移除选中记录…"
            }
        }

        private var clearHelp: String {
            if model.selection == .queue || model.selection == nil {
                return model.selectedPairIDs.isEmpty
                    ? "移除列表中的全部项目，保留本地文件"
                    : "移除选中的项目，保留本地文件"
            }
            return "移除记录；下一步可选择保留本地文件或将文件移到废纸篓"
        }

        private var composeHelp: String {
            if model.selection == .downloads {
                return model.selectedDownloadItemIDs.isEmpty
                    ? "合成当前筛选中所有可合成的照片与视频配对"
                    : "合成选中项目中的照片与视频配对"
            }
            return model.selectedPairIDs.isEmpty
                ? "将列表中的全部照片与视频配对合成为 Live Photo"
                : "将选中的照片与视频配对合成为 Live Photo"
        }

        private var refreshHelp: String { "重新扫描当前文件夹并更新列表" }

        private var openFolderHelp: String {
            model.selection == .downloads ? "在访达中打开下载文件夹" : "在访达中打开导出文件夹"
        }

        private var chooseFolderHelp: String {
            model.selection == .downloads ? "更改下载文件夹…" : "更改导出位置…"
        }

        @objc private func refresh(_ sender: Any?) {
            switch model.selection ?? .queue {
            case .queue:
                break
            case .downloads:
                model.refreshDownloads()
            case .completed:
                model.refreshCompleted()
            }
        }

        @objc private func openFolder(_ sender: Any?) {
            switch model.selection ?? .queue {
            case .queue, .completed:
                model.openOutputFolder()
            case .downloads:
                model.openDownloadOutputFolder()
            }
        }

        @objc private func chooseFolder(_ sender: Any?) {
            presentFolderChooser()
        }

        @objc private func clear(_ sender: Any?) {
            switch model.selection ?? .queue {
            case .queue:
                clearQueue()
            case .downloads:
                clearDownloads()
            case .completed:
                clearCompleted()
            }
        }

        @objc private func addFiles(_ sender: Any?) {
            presentImportPanel()
        }

        @objc private func compose(_ sender: Any?) {
            Task { await model.composeCurrentPage() }
        }

        @objc private func importCompleted(_ sender: Any?) {
            Task { await model.importCompletedToPhotos() }
        }

        @objc private func toggleImportToPhotos(_ sender: NSToolbarItem) {
            model.importToPhotos.toggle()
            updateToggleItem(sender, symbol: AppSymbol.importToPhotos, label: "合成后自动导入“照片”", state: model.importToPhotos, isEnabled: true)
            reloadToolbarIfNeeded()
        }

        @objc private func toggleAddToAlbum(_ sender: NSToolbarItem) {
            guard addToAlbumEnabled else {
                updateToggleItem(sender, symbol: AppSymbol.addToAlbum, label: "导入时加入 HERMES 相簿", state: addToAlbumState, isEnabled: false)
                return
            }
            switch model.selection ?? .queue {
            case .completed:
                model.completedAddToAlbum.toggle()
                updateToggleItem(sender, symbol: AppSymbol.addToAlbum, label: "导入时加入 HERMES 相簿", state: model.completedAddToAlbum, isEnabled: addToAlbumEnabled)
            case .queue, .downloads:
                let newValue = model.importToPhotos && !model.addToAlbum
                model.addToAlbum = newValue
                updateToggleItem(sender, symbol: AppSymbol.addToAlbum, label: "导入时加入 HERMES 相簿", state: newValue, isEnabled: model.importToPhotos)
            }
        }

        @objc private func completedFilterChanged(_ sender: NSSegmentedControl) {
            let filters = CompletedFilter.allCases
            guard filters.indices.contains(sender.selectedSegment) else { return }
            let selected = filters[sender.selectedSegment]
            if selected != model.completedFilter {
                model.completedFilter = selected
            }
        }

        @objc private func downloadFilterChanged(_ sender: NSSegmentedControl) {
            let filters = DownloadFilter.allCases
            guard filters.indices.contains(sender.selectedSegment) else { return }
            let selected = filters[sender.selectedSegment]
            if selected != model.downloadFilter {
                model.downloadFilter = selected
            }
        }
    }

@MainActor
private final class ToolbarToggleButton: NSButton {
    weak var toolbarItem: NSToolbarItem?
    weak var actionTarget: AnyObject?
    var forwardedAction: Selector?

    @objc func forwardAction(_ sender: Any?) {
        guard let item = toolbarItem, let action = forwardedAction else { return }
        NSApp.sendAction(action, to: actionTarget, from: item)
    }
}
