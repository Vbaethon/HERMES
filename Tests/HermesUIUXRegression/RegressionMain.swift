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
        let buttons = descendants(settings.window!.contentView!).compactMap { $0 as? NSButton }
        let automatic = buttons.first { $0.title == "合成后自动导入“照片”" }!
        let album = buttons.first { $0.title == "从“已完成”导入时加入 HERMES 相簿" }!
        model.importToPhotos = true
        model.completedAddToAlbum = true
        automatic.state = .off
        NSApp.sendAction(automatic.action!, to: automatic.target, from: automatic)
        expect(!model.importToPhotos, "settings must update execution model synchronously")
        expect(model.completedAddToAlbum && album.isEnabled, "manual album preference must survive disabling automatic import")
        expect(UserDefaults.standard.bool(forKey: AppPreferenceKey.completedAddToAlbum), "manual preference must persist")
        model.importToPhotos = true
        model.completedAddToAlbum = false
        try await Task.sleep(for: .milliseconds(100))
        expect(automatic.state == .on && album.state == .off, "model changes must refresh cached settings window")
        expect(settings.window?.title == "HERMES 设置", "settings title")
        pass("settings/model two-way synchronization and independent manual album preference")

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

        var selected: SidebarSection?
        let sidebar = FinderStyleSidebarController(sections: SidebarSection.allCases, selection: .queue, count: { _ in nil }, onSelect: { selected = $0 })
        let table = descendants(sidebar.view).compactMap { $0 as? NSTableView }.first!
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
