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
    private var lastIdentifiers: [NSToolbarItem.Identifier] = []
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

    init(model: ImporterModel, windowTitle: String, windowSubtitle: String, clearQueue: @escaping () -> Void, clearCompleted: @escaping () -> Void, clearDownloads: @escaping () -> Void) {
        self.model = model
        self.windowTitle = windowTitle
        self.windowSubtitle = windowSubtitle
        self.clearQueue = clearQueue
        self.clearCompleted = clearCompleted
        self.clearDownloads = clearDownloads
        super.init()
    }

    func installToolbar(in window: NSWindow?) {
            guard let window else { return }
            installedWindow = window
            configureWindowChrome(window)

            if let existingToolbar = window.toolbar {
                if toolbar !== existingToolbar {
                    lastIdentifiers = []
                    lastToolbarState = nil
                }
                existingToolbar.delegate = self
                existingToolbar.displayMode = .iconOnly
                existingToolbar.allowsUserCustomization = false
                existingToolbar.autosavesConfiguration = false
                existingToolbar.centeredItemIdentifier = ID.filter
                toolbar = existingToolbar
            } else {
                let toolbar = NSToolbar(identifier: ID.toolbar)
                toolbar.delegate = self
                toolbar.displayMode = .iconOnly
                toolbar.allowsUserCustomization = false
                toolbar.autosavesConfiguration = false
                toolbar.centeredItemIdentifier = ID.filter
                window.toolbar = toolbar
                self.toolbar = toolbar
                lastIdentifiers = []
                lastToolbarState = nil
            }
        }

        private func configureWindowChrome(_ window: NSWindow) {
            window.isRestorable = false
            SystemWindowBackgroundController.configureMainWindow(window)
        }

        func reloadToolbarIfNeeded() {
            guard let toolbar else { return }
            let identifiers = defaultIdentifiers
            toolbar.centeredItemIdentifier = identifiers.contains(ID.filter) ? ID.filter : nil
            if identifiers == lastIdentifiers {
                reloadVisibleItemState(in: toolbar)
                return
            }
            for _ in toolbar.items {
                toolbar.removeItem(at: 0)
            }
            for (index, identifier) in identifiers.enumerated() {
                toolbar.insertItem(withItemIdentifier: identifier, at: index)
            }
            lastIdentifiers = identifiers
            lastToolbarState = currentToolbarState
        }

        private func reloadVisibleItemState(in toolbar: NSToolbar) {
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
                        updateToggleItem(item, symbol: AppSymbol.importToPhotos, label: "导入照片", state: state.importToPhotos, isEnabled: true)
                    }
                case ID.addToAlbum:
                    if state.addToAlbum != previousState.addToAlbum || state.addToAlbumEnabled != previousState.addToAlbumEnabled {
                        updateToggleItem(item, symbol: AppSymbol.addToAlbum, label: "添加到相簿", state: state.addToAlbum, isEnabled: state.addToAlbumEnabled)
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
                        item.image = buttonSymbolImage(AppSymbol.importCompleted, isEnabled: state.importCompletedEnabled, label: "导入")
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
                    updateToggleItem(item, symbol: AppSymbol.importToPhotos, label: "导入照片", state: state.importToPhotos, isEnabled: true)
                case ID.addToAlbum:
                    updateToggleItem(item, symbol: AppSymbol.addToAlbum, label: "添加到相簿", state: state.addToAlbum, isEnabled: state.addToAlbumEnabled)
                case ID.clear:
                    item.isEnabled = state.clearEnabled
                    item.image = buttonSymbolImage(AppSymbol.clear, isEnabled: state.clearEnabled, label: state.clearLabel)
                    item.label = state.clearLabel
                    item.paletteLabel = state.clearLabel
                    item.toolTip = state.clearHelp
                case ID.importCompleted:
                    item.isEnabled = state.importCompletedEnabled
                    item.image = buttonSymbolImage(AppSymbol.importCompleted, isEnabled: state.importCompletedEnabled, label: "导入")
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
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            FinderStyleSidebarController.toolbarAllowedItemIdentifiers + [
                ID.filter, ID.refresh, ID.openFolder, ID.chooseFolder,
                ID.importToPhotos, ID.addToAlbum, ID.clear, ID.addFiles,
                ID.importCompleted, ID.compose, .space, .flexibleSpace
            ]
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
                return buttonItem(itemIdentifier, symbol: AppSymbol.chooseFolder, label: "选择文件夹", help: chooseFolderHelp, action: #selector(chooseFolder(_:)), isEnabled: true)
            case ID.importToPhotos:
                return toggleItem(itemIdentifier, symbol: AppSymbol.importToPhotos, label: "导入照片", help: "导入系统相册", state: model.importToPhotos, action: #selector(toggleImportToPhotos(_:)), isEnabled: true)
            case ID.addToAlbum:
                return toggleItem(itemIdentifier, symbol: AppSymbol.addToAlbum, label: "添加到相簿", help: "添加到相簿", state: addToAlbumState, action: #selector(toggleAddToAlbum(_:)), isEnabled: addToAlbumEnabled)
            case ID.clear:
                return buttonItem(itemIdentifier, symbol: AppSymbol.clear, label: clearLabel, help: clearHelp, action: #selector(clear(_:)), isEnabled: clearEnabled)
            case ID.addFiles:
                return buttonItem(itemIdentifier, symbol: AppSymbol.addFiles, label: "添加文件", help: "添加文件", action: #selector(addFiles(_:)), isEnabled: true)
            case ID.importCompleted:
                return buttonItem(itemIdentifier, symbol: AppSymbol.importCompleted, label: "导入", help: "导入所选", action: #selector(importCompleted(_:)), isEnabled: !model.selectedCompletedIDs.isEmpty && !model.isImportingCompleted)
            case ID.compose:
                return buttonItem(itemIdentifier, symbol: AppSymbol.composeLivePhoto, label: "合成 Live Photo", help: "合成所选", action: #selector(compose(_:)), isEnabled: composeEnabled)
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
            switch model.selection ?? .queue {
            case .queue:
                model.canProcessSelectedPairs
            case .downloads:
                model.canProcessDownloadPairs
            case .completed:
                false
            }
        }

        private var clearLabel: String {
            switch model.selection ?? .queue {
            case .queue:
                "清空"
            case .downloads:
                model.selectedDownloadItemIDs.isEmpty ? "清空下载项目" : "删除选中的下载项目"
            case .completed:
                model.selectedCompletedIDs.isEmpty ? "清空完成项目" : "删除选中的完成项目"
            }
        }

        private var clearHelp: String {
            switch model.selection ?? .queue {
            case .queue:
                "清空列表"
            case .downloads:
                model.selectedDownloadItemIDs.isEmpty ? "清空列表" : "删除所选"
            case .completed:
                model.selectedCompletedIDs.isEmpty ? "清空列表" : "删除所选"
            }
        }

        private var refreshHelp: String {
            switch model.selection ?? .queue {
            case .queue:
                "刷新"
            case .downloads:
                "刷新"
            case .completed:
                "刷新"
            }
        }

        private var openFolderHelp: String {
            "打开文件夹"
        }

        private var chooseFolderHelp: String {
            "选择文件夹"
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
            switch model.selection ?? .queue {
            case .queue, .completed:
                model.chooseOutputFolder()
            case .downloads:
                model.chooseDownloadOutputFolder()
            }
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
            model.chooseFiles()
        }

        @objc private func compose(_ sender: Any?) {
            switch model.selection ?? .queue {
            case .queue:
                Task { await model.processPairs() }
            case .downloads:
                Task { await model.processDownloadPairs() }
            case .completed:
                break
            }
        }

        @objc private func importCompleted(_ sender: Any?) {
            Task { await model.importCompletedToPhotos() }
        }

        @objc private func toggleImportToPhotos(_ sender: NSToolbarItem) {
            model.importToPhotos.toggle()
            updateToggleItem(sender, symbol: AppSymbol.importToPhotos, label: "导入照片", state: model.importToPhotos, isEnabled: true)
            reloadToolbarIfNeeded()
        }

        @objc private func toggleAddToAlbum(_ sender: NSToolbarItem) {
            guard addToAlbumEnabled else {
                updateToggleItem(sender, symbol: AppSymbol.addToAlbum, label: "添加到相簿", state: addToAlbumState, isEnabled: false)
                return
            }
            switch model.selection ?? .queue {
            case .completed:
                model.completedAddToAlbum.toggle()
                updateToggleItem(sender, symbol: AppSymbol.addToAlbum, label: "添加到相簿", state: model.completedAddToAlbum, isEnabled: addToAlbumEnabled)
            case .queue, .downloads:
                let newValue = model.importToPhotos && !model.addToAlbum
                model.addToAlbum = newValue
                updateToggleItem(sender, symbol: AppSymbol.addToAlbum, label: "添加到相簿", state: newValue, isEnabled: model.importToPhotos)
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
