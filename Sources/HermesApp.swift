import AppKit

@main
enum HermesApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = HermesAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        _ = delegate
    }
}

@MainActor
final class HermesAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var aboutWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Remove the obsolete manual login value without reading or transmitting it.
        UserDefaults.standard.removeObject(forKey: "XHSWebSessionCookie.v1")
        NSApp.mainMenu = makeMainMenu()
        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mainWindowController?.model.hasActiveWork == true else { return .terminateNow }
        mainWindowController?.showActiveWorkNotice()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    @objc private func showAbout(_ sender: Any?) {
        if let controller = aboutWindowController {
            controller.showWindow(sender)
            controller.window?.makeKeyAndOrderFront(sender)
            return
        }
        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72)
        ])
        stack.addArrangedSubview(icon)
        func addLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: size, weight: weight)
            label.textColor = secondary ? .secondaryLabelColor : .labelColor
            label.alignment = .center
            stack.addArrangedSubview(label)
        }
        addLabel("H E R M E S", size: 22, weight: .semibold)
        addLabel(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—", size: 12, secondary: true)
        addLabel("一个有趣的工具。", size: 14, weight: .semibold)
        addLabel("带着一点好奇，去发现它。", size: 13)
        addLabel("✦", size: 16, secondary: true)
        addLabel("不急着定义，先开始探索。", size: 12, secondary: true)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24)
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 370),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "关于 HERMES"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        aboutWindowController = controller
        controller.showWindow(sender)
        window.makeKeyAndOrderFront(sender)
    }

    @objc private func showSettings(_ sender: Any?) {
        guard let model = mainWindowController?.model else { return }
        let controller = settingsWindowController ?? SettingsWindowController(model: model)
        settingsWindowController = controller
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    @objc private func openImportPanel(_ sender: Any?) {
        NotificationCenter.default.post(name: .openImportPanel, object: nil)
    }

    @objc private func startDownload(_ sender: Any?) {
        NotificationCenter.default.post(name: .startDownload, object: nil)
    }

    @objc private func importToPhotos(_ sender: Any?) {
        guard let model = mainWindowController?.model else { return }
        Task {
            if model.selection == .completed { await model.importCompletedToPhotos() }
            else if model.selection == .downloads { await model.importSelectedDownloadMediaToPhotos(addToAlbum: model.addToAlbum) }
        }
    }

    @objc private func showMainWindow(_ sender: Any?) {
        mainWindowController?.showWindow(sender)
        mainWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc private func startImport(_ sender: Any?) {
        NotificationCenter.default.post(name: .startImport, object: nil)
    }

    @objc private func selectQueue(_ sender: Any?) {
        NotificationCenter.default.post(name: .selectSidebarSection, object: SidebarSection.queue)
    }

    @objc private func selectDownloads(_ sender: Any?) {
        NotificationCenter.default.post(name: .selectSidebarSection, object: SidebarSection.downloads)
    }

    @objc private func selectCompleted(_ sender: Any?) {
        NotificationCenter.default.post(name: .selectSidebarSection, object: SidebarSection.completed)
    }

    @objc private func refreshCurrentPage(_ sender: Any?) {
        NotificationCenter.default.post(name: .refreshCurrentPage, object: nil)
    }

    @objc private func openCurrentFolder(_ sender: Any?) {
        NotificationCenter.default.post(name: .openCurrentFolder, object: nil)
    }

    @objc private func chooseCurrentFolder(_ sender: Any?) {
        NotificationCenter.default.post(name: .chooseCurrentFolder, object: nil)
    }

    @objc private func toggleToolbarLabels(_ sender: NSMenuItem) {
        guard let toolbar = mainWindowController?.window?.toolbar else { return }
        toolbar.displayMode = toolbar.displayMode == .iconOnly ? .iconAndLabel : .iconOnly
    }

    @objc private func customizeToolbar(_ sender: NSMenuItem) {
        mainWindowController?.window?.toolbar?.runCustomizationPalette(sender)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let model = mainWindowController?.model
        if menuItem.action == #selector(refreshCurrentPage(_:)) {
            return model?.selection != .queue && model?.selection != nil
        }
        if menuItem.action == #selector(startDownload(_:)) {
            return model?.selection == .downloads && !(model?.downloadShareText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        if menuItem.action == #selector(importToPhotos(_:)) {
            return model?.selection == .completed ? (model?.canImportCompleted ?? false)
                : model?.selection == .downloads && (model?.canImportSelectedDownloadMedia ?? false)
        }
        if menuItem.action == #selector(chooseCurrentFolder(_:)) {
            let downloads = model?.selection == .downloads
            menuItem.title = downloads ? "更改下载文件夹…" : "移动导出文件夹…"
            return downloads || (model?.canMoveOutputFolder ?? false)
        }
        if menuItem.action == #selector(startImport(_:)) {
            return mainWindowController?.canComposeCurrentPage ?? false
        }
        if menuItem.action == #selector(toggleToolbarLabels(_:)) {
            guard let toolbar = mainWindowController?.window?.toolbar else { return false }
            menuItem.state = toolbar.displayMode == .iconOnly ? .off : .on
            return true
        }
        if menuItem.action == #selector(customizeToolbar(_:)) {
            return mainWindowController?.window?.toolbar != nil
        }
        return true
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let aboutItem = NSMenuItem(title: "关于 HERMES", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置...", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 HERMES", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
        appMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(NSMenuItem(title: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 HERMES", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        let addItem = NSMenuItem(title: "添加文件或文件夹...", action: #selector(openImportPanel(_:)), keyEquivalent: "o")
        addItem.target = self
        fileMenu.addItem(addItem)
        let composeItem = NSMenuItem(title: "合成 Live Photo", action: #selector(startImport(_:)), keyEquivalent: "\r")
        composeItem.target = self
        fileMenu.addItem(composeItem)
        let downloadItem = NSMenuItem(title: "开始下载", action: #selector(startDownload(_:)), keyEquivalent: "")
        downloadItem.target = self
        fileMenu.addItem(downloadItem)
        let importItem = NSMenuItem(title: "导入“照片”", action: #selector(importToPhotos(_:)), keyEquivalent: "")
        importItem.target = self
        fileMenu.addItem(importItem)
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileMenu.addItem(.separator())
        let openFolderItem = NSMenuItem(title: "打开当前文件夹", action: #selector(openCurrentFolder(_:)), keyEquivalent: "o")
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        openFolderItem.target = self
        fileMenu.addItem(openFolderItem)
        let chooseFolderItem = NSMenuItem(title: "更改当前保存位置…", action: #selector(chooseCurrentFolder(_:)), keyEquivalent: "")
        chooseFolderItem.target = self
        fileMenu.addItem(chooseFolderItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "显示")
        viewMenuItem.submenu = viewMenu
        let queueItem = NSMenuItem(title: "开始", action: #selector(selectQueue(_:)), keyEquivalent: "1")
        queueItem.target = self
        viewMenu.addItem(queueItem)
        let downloadsItem = NSMenuItem(title: "下载器", action: #selector(selectDownloads(_:)), keyEquivalent: "2")
        downloadsItem.target = self
        viewMenu.addItem(downloadsItem)
        let completedItem = NSMenuItem(title: "已完成", action: #selector(selectCompleted(_:)), keyEquivalent: "3")
        completedItem.target = self
        viewMenu.addItem(completedItem)
        viewMenu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "刷新当前页面", action: #selector(refreshCurrentPage(_:)), keyEquivalent: "r")
        refreshItem.target = self
        viewMenu.addItem(refreshItem)
        viewMenu.addItem(.separator())
        let labelsItem = NSMenuItem(title: "显示工具栏按钮名称", action: #selector(toggleToolbarLabels(_:)), keyEquivalent: "")
        labelsItem.target = self
        viewMenu.addItem(labelsItem)
        let customizeItem = NSMenuItem(title: "自定义工具栏…", action: #selector(customizeToolbar(_:)), keyEquivalent: "")
        customizeItem.target = self
        viewMenu.addItem(customizeItem)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        let mainWindowItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow(_:)), keyEquivalent: "")
        mainWindowItem.target = self
        windowMenu.addItem(mainWindowItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }
}

extension Notification.Name {
    static let openImportPanel = Notification.Name("OpenImportPanel")
    static let startImport = Notification.Name("StartImport")
    static let startDownload = Notification.Name("StartDownload")
    static let selectSidebarSection = Notification.Name("SelectSidebarSection")
    static let refreshCurrentPage = Notification.Name("RefreshCurrentPage")
    static let openCurrentFolder = Notification.Name("OpenCurrentFolder")
    static let chooseCurrentFolder = Notification.Name("ChooseCurrentFolder")
}
