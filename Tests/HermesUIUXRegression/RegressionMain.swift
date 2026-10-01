import AppKit
import Foundation

@main enum UIUXRegression {
    @MainActor static func main() async throws {
        precondition(Bundle.main.bundleIdentifier != "com.codex.Hermes")
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults.standard.set(root.path, forKey: "OutputFolderPath")
        UserDefaults.standard.set(root.appendingPathComponent("downloads").path, forKey: "DownloadOutputFolderPath.v1")
        for key in ["OutputFolderBookmark.v1", "DownloadOutputFolderBookmark.v1", "CompletedRecords.v1", "DownloadCompletedRecords.v1"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let model = ImporterModel(refreshOnInit: false)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
        var checks = 0
        func pass(_ message: String) { checks += 1; print("PASS: \(message)") }

        let settings = SettingsWindowController(model: model)
        expect(settings.window!.contentViewController is NSSplitViewController, "settings must use AppKit split-view containment")
        expect(settings.window!.styleMask.contains(.resizable), "settings must support resizing")
        model.importToPhotos = true
        model.addToAlbum = true
        model.completedAddToAlbum = true
        model.importToPhotos = false
        expect(!model.addToAlbum, "automatic album preference follows automatic import")
        expect(model.completedAddToAlbum, "manual album preference is independent")
        expect(UserDefaults.standard.bool(forKey: AppPreferenceKey.completedAddToAlbum), "manual preference must persist")
        expect(!UserDefaults.standard.bool(forKey: AppPreferenceKey.importToPhotos), "automatic preference must persist")
        model.importToPhotos = true
        model.completedAddToAlbum = false
        let settingsRoot = settings.window!.contentView!
        settingsRoot.layoutSubtreeIfNeeded()
        let settingsControls = descendants(settingsRoot).compactMap { $0 as? NSSwitch }
        let automatic = settingsControls.first { $0.identifier?.rawValue == "settings.importToPhotos" }!
        let automaticAlbum = settingsControls.first { $0.identifier?.rawValue == "settings.addToAlbum" }!
        let manualAlbum = settingsControls.first { $0.identifier?.rawValue == "settings.completedAddToAlbum" }!
        automatic.state = .off
        NSApp.sendAction(automatic.action!, to: automatic.target, from: automatic)
        expect(!model.importToPhotos && !automaticAlbum.isEnabled, "native switch must update model and dependent control immediately")
        model.importToPhotos = true
        model.completedAddToAlbum = true
        try await Task.sleep(for: .milliseconds(100))
        expect(automatic.state == .on && manualAlbum.state == .on, "model changes must refresh native controls")
        let settingsNavigation = descendants(settingsRoot).compactMap { $0 as? NSTableView }.first!
        settingsNavigation.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        expect(!manualAlbum.isHiddenOrHasHiddenAncestor && automatic.isHiddenOrHasHiddenAncestor, "native navigation switches the visible settings")
        expect(settings.window!.title == "已完成", "single window title follows navigation")
        settingsNavigation.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        expect(settings.window!.makeFirstResponder(settingsNavigation), "settings sidebar must support keyboard focus")
        let focusedSettingsRow = settingsNavigation.rowView(atRow: 0, makeIfNecessary: true)!
        focusedSettingsRow.isEmphasized = true
        expect(focusedSettingsRow.isSelected && !focusedSettingsRow.isEmphasized, "settings must retain the main sidebar's native gray selection with keyboard focus")
        let navigationScroll = settingsNavigation.enclosingScrollView!
        expect(navigationScroll.automaticallyAdjustsContentInsets, "AppKit must manage the toolbar content inset")
        for size in [NSSize(width: 780, height: 480), NSSize(width: 680, height: 360)] {
            settings.window!.setContentSize(size)
            settingsRoot.layoutSubtreeIfNeeded()
            settingsNavigation.scrollRowToVisible(0)
            settingsRoot.layoutSubtreeIfNeeded()
            let rowRect = settingsNavigation.convert(settingsNavigation.rect(ofRow: 0), to: nil)
            expect(rowRect.maxY <= settings.window!.contentLayoutRect.maxY + 1, "first sidebar row must be below native toolbar")
            let switchRect = automatic.convert(automatic.bounds, to: nil)
            expect(switchRect.maxY <= settings.window!.contentLayoutRect.maxY + 1, "settings controls must be below native toolbar")
            expect(switchRect.maxX <= settings.window!.contentLayoutRect.maxX, "switch must fit at the minimum width")
        }
        var previousFontSize: CGFloat = 0
        for size in [NSTableView.RowSizeStyle.small, .medium, .large] {
            settingsNavigation.rowSizeStyle = size
            settingsRoot.layoutSubtreeIfNeeded()
            let first = settingsNavigation.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSTableCellView
            let second = settingsNavigation.view(atColumn: 0, row: 1, makeIfNecessary: true) as! NSTableCellView
            first.layoutSubtreeIfNeeded()
            second.layoutSubtreeIfNeeded()
            let firstFontSize = first.textField!.font!.pointSize
            expect(firstFontSize == second.textField!.font!.pointSize, "selected and unselected sidebar rows must use the same point size")
            expect(firstFontSize > previousFontSize, "sidebar text must follow the system row size")
            let firstSymbolSlot = first.imageView!.alignmentRect(forFrame: first.imageView!.frame)
            let secondSymbolSlot = second.imageView!.alignmentRect(forFrame: second.imageView!.frame)
            expect(firstSymbolSlot.size == secondSymbolSlot.size, "sidebar symbols must share their Auto Layout size, allowing native SF Symbol optical insets")
            expect(first.textField!.frame.minX == second.textField!.frame.minX, "sidebar labels must align across different symbol shapes")
            expect(first.imageView!.symbolConfiguration != nil && second.imageView!.symbolConfiguration != nil, "SF Symbols must have an explicit matching typographic scale")
            previousFontSize = firstFontSize
        }
        settingsNavigation.rowSizeStyle = .default
        let toolbarIDs = settings.window!.toolbar!.items.map(\.itemIdentifier)
        expect(toolbarIDs.prefix(3).elementsEqual([.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator]), "sidebar button must sit at the end of its toolbar region")
        pass("AppKit settings: native navigation, switch bindings, persistence and titlebar-safe layout")

        model.downloadPhotos = [root.appendingPathComponent("existing.jpg")]
        model.downloadShareText = "这是一段没有链接的文本"
        await model.downloadShare()
        expect(model.operationNotices[.downloads]?.contains("没有识别") == true, "invalid input feedback with a nonempty library")
        let first = model.operationNotices[.downloads]
        await model.downloadShare()
        expect(first == model.operationNotices[.downloads], "duplicate errors must not accumulate")
        pass("invalid-share feedback is independent of library emptiness and deduplicates")

        let missing = root.appendingPathComponent("missing.jpg")
        model.downloadPhotos = [missing]
        model.selectedDownloadItemIDs = ["photo:\(missing.standardizedFileURL.path)"]
        await model.importSelectedDownloadMediaToPhotos(addToAlbum: false)
        expect(model.operationNotices[.downloads]?.contains("未找到源文件") == true, "missing download source feedback")
        model.completed = [CompletedItem(imagePath: missing.path, moviePath: root.appendingPathComponent("missing.mov").path, modifiedTime: 0)]
        model.selectedCompletedIDs = [model.completed[0].id]
        await model.importCompletedToPhotos()
        expect(model.operationNotices[.completed]?.contains("未找到源文件") == true, "missing completed source feedback")
        model.isProcessing = true
        expect(!model.canImportCompleted && model.hasActiveWork && !model.canMoveOutputFolder, "busy state must disable import, move and exit")
        model.isProcessing = false
        model.isImportingDownloadMedia = true
        expect(model.hasActiveWork, "media import must protect exit")
        model.isImportingDownloadMedia = false
        expect(!model.hasActiveWork, "idle state must allow exit")
        pass("missing sources visible on both pages; busy guards protect operations")

        let menuModel = ImporterModel(refreshOnInit: false)
        let menuPhoto = root.appendingPathComponent("menu-photo.png")
        let menuCover = root.appendingPathComponent("menu-cover.png")
        let menuVideo = root.appendingPathComponent("menu-video.mov")
        for url in [menuPhoto, menuCover, menuVideo] { try Data([0]).write(to: url) }
        let menuPair = PairItem(imageURL: menuCover, videoURL: menuVideo)
        menuModel.downloadPairs = [menuPair]
        menuModel.downloadPhotos = [menuPhoto]
        menuModel.downloadFilter = .notComposed
        menuModel.isDownloading = true
        let menuItems = menuModel.visibleDownloadItems
        let (menuScroll, menuCoordinator) = DownloadCollectionView.make(
            items: menuItems, filter: .notComposed, model: menuModel, bottomContentInset: 0
        )
        let menuWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        menuWindow.contentView = menuScroll
        menuScroll.layoutSubtreeIfNeeded()
        menuCoordinator.collectionView!.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func rightClickMenu(_ collection: NSCollectionView, at index: Int) -> NSMenu {
            let frame = collection.collectionViewLayout!.layoutAttributesForItem(at: IndexPath(item: index, section: 0))!.frame
            let point = collection.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: collection.window!.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!
            return collection.menu(for: event)!
        }
        let photoID = "photo:\(menuPhoto.standardizedFileURL.path)"
        let pairID = "pair:\(menuPair.id)"
        let pairIndex = menuItems.firstIndex { $0.id == pairID }!
        let photoIndex = menuItems.firstIndex { $0.id == photoID }!
        var menuSelections: [Set<String>] = []
        menuCoordinator.gridController!.setSelectionHandler { ids in
            menuSelections.append(ids)
            menuModel.selectedDownloadItemIDs = ids
        }
        menuCoordinator.gridController!.applySelection([pairID, photoID])
        menuModel.selectedDownloadItemIDs = []
        let selectedMenu = rightClickMenu(menuCoordinator.collectionView!, at: pairIndex)
        expect(menuModel.selectedDownloadItemIDs == [pairID, photoID], "right click must restore the current multi-selection before building its menu")
        expect(menuSelections == [[pairID, photoID]], "opening the menu must publish selection exactly once")
        expect(selectedMenu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled), "download must leave eligible composition, Finder, import and deletion menu actions available")
        menuCoordinator.gridController!.applySelection([pairID])
        menuSelections = []
        let photoMenu = rightClickMenu(menuCoordinator.collectionView!, at: photoIndex)
        expect(menuModel.selectedDownloadItemIDs == [photoID] && menuSelections == [[photoID]], "right-clicking another item must atomically select it without publishing an empty selection")
        let photoActions = photoMenu.items.filter { !$0.isSeparatorItem }
        expect(!photoActions[0].isEnabled && photoActions.dropFirst().allSatisfy(\.isEnabled), "a standalone photo must retain Finder, Photos, album and deletion actions while downloading")
        menuModel.isProcessingDownloads = true
        let composingMenu = rightClickMenu(menuCoordinator.collectionView!, at: photoIndex)
        expect(composingMenu.items.first { $0.title.contains("访达") }!.isEnabled, "Finder must remain available during composition")
        expect(!composingMenu.items.first { $0.title.contains("导入“照片”") }!.isEnabled, "conflicting media import must remain guarded during composition")
        menuModel.isProcessingDownloads = false
        menuModel.files = [menuCover, menuVideo]
        menuModel.pairs = [menuPair]
        let (pairMenuScroll, pairMenuCoordinator) = PairCollectionView.make(items: [menuPair], model: menuModel)
        menuWindow.contentView = pairMenuScroll
        pairMenuScroll.layoutSubtreeIfNeeded()
        pairMenuCoordinator.collectionView!.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let pairMenu = rightClickMenu(pairMenuCoordinator.collectionView!, at: 0)
        expect(pairMenu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled), "queue actions must remain available for settled sources during download")
        menuModel.isProcessingDownloads = true
        let guardedPairMenu = rightClickMenu(pairMenuCoordinator.collectionView!, at: 0)
        expect(!guardedPairMenu.items[0].isEnabled, "queue menu composition must follow model eligibility when another composition is running")
        expect(guardedPairMenu.items.first { $0.title.contains("访达") }!.isEnabled, "queue Finder action must remain available during another composition")
        menuModel.isProcessingDownloads = false
        menuModel.isDownloading = false
        withExtendedLifetime(menuWindow) {}
        pass("right-click selection and eligible menu actions remain usable during downloads")

        var selected: SidebarSection?
        let sidebar = FinderStyleSidebarController(sections: SidebarSection.allCases, selection: .queue, count: { _ in nil }, onSelect: { selected = $0 })
        let table = descendants(sidebar.view).compactMap { $0 as? NSTableView }.first!
        expect(type(of: settingsNavigation) == type(of: table), "both sidebars must share the same table implementation")
        expect(settingsNavigation.intercellSpacing == table.intercellSpacing, "both sidebars must share row spacing")
        expect(navigationScroll.hasVerticalScroller == table.enclosingScrollView!.hasVerticalScroller, "both sidebars must share native scrolling behavior")
        expect(type(of: focusedSettingsRow) == type(of: table.rowView(atRow: 0, makeIfNecessary: true)!), "both sidebars must share AppKit selection rendering")
        let sidebarWindow = NSWindow(contentViewController: sidebar)
        sidebarWindow.setContentSize(NSSize(width: 220, height: 300))
        expect(sidebarWindow.makeFirstResponder(table), "sidebar must accept keyboard focus")
        try await Task.sleep(for: .milliseconds(100))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        expect(selected == .downloads, "native selection must switch page")
        sidebar.view.layoutSubtreeIfNeeded()
        let selectedRow = table.rowView(atRow: 1, makeIfNecessary: true)!
        selectedRow.isEmphasized = true
        expect(selectedRow.isSelected && !selectedRow.isEmphasized, "focused navigation selection must retain the native neutral appearance")
        let field = NSTextField()
        sidebar.view.addSubview(field)
        expect(sidebarWindow.makeFirstResponder(field), "focus must leave sidebar")
        pass("sidebar native focus, selection and leaving focus")

        model.downloadShareText = String(repeating: "这是一个没有换行的分享文本链接abcdef12345", count: 80)
        let bar = DownloadBarView(model: model, startDownload: {})
        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        host.view.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        let width = bar.widthAnchor.constraint(equalToConstant: 600)
        NSLayoutConstraint.activate([width, bar.leadingAnchor.constraint(equalTo: host.view.leadingAnchor), bar.topAnchor.constraint(equalTo: host.view.topAnchor)])
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 700, height: 400))
        host.view.layoutSubtreeIfNeeded()
        bar.reload()
        host.view.layoutSubtreeIfNeeded()
        let text = descendants(bar).compactMap { $0 as? DownloadShareNSTextView }.first!
        let scroll = text.enclosingScrollView!
        expect(scroll.hasVerticalScroller && text.isVerticallyResizable, "wrapped long text must scroll")
        expect(text.frame.height > scroll.contentSize.height, "entire long document must be accessible")
        let longHeight = bar.frame.height
        width.constant = 350
        host.view.layoutSubtreeIfNeeded()
        expect(scroll.hasVerticalScroller, "narrow window must retain scrolling")
        let original = text.string
        text.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
        bar.reload()
        expect(text.string == original && text.selectedRange().location == (original as NSString).length, "relayout must preserve text and caret")
        text.setMarkedText("输入中", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let composingText = text.string
        bar.reload()
        expect(text.hasMarkedText() && text.string == composingText, "relayout must preserve IME composition")
        text.unmarkText()
        model.downloadShareText = "短文本"
        bar.reload()
        host.view.layoutSubtreeIfNeeded()
        expect(!scroll.hasVerticalScroller && bar.frame.height < longHeight, "short text must shrink input")
        pass("wrapped long input at wide and narrow widths; scroll, caret and height recovery")
        let empty = EmptyStateView(title: "当前筛选下没有项目", symbolName: "photo", message: "")
        model.completedFilter = .added
        empty.showAllAction = { model.completedFilter = .all }
        let showAll = descendants(empty).compactMap { $0 as? NSButton }.first!
        NSApp.sendAction(showAll.action!, to: showAll.target, from: showAll)
        expect(model.completedFilter == .all, "empty-state recovery must clear the filter")
        let thumbnail = ThumbnailCollectionItem()
        thumbnail.configure(with: missing, status: .running, mediaKind: .livePhoto)
        expect(descendants(thumbnail.view).compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue == "正在合成…" }, "running status must be visible")
        pass("filter recovery action and visible composition state")
        print("PASS: \(checks) UI/UX regression groups; no network, media deletion or Photos writes")
    }
}
