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
final class HermesAppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Remove the obsolete manual login value without reading or transmitting it.
        UserDefaults.standard.removeObject(forKey: "XHSWebSessionCookie.v1")
        NSApp.mainMenu = makeMainMenu()
        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        let bundle = Bundle.main
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 8
        let credits = NSMutableAttributedString(
            string: "Live Photo 合成与媒体下载\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        credits.append(NSAttributedString(
            string: "照片与视频配对 · Live Photo 合成\n抖音、小红书、得物媒体下载\n导入“照片”图库与相簿\n\n作者：九尾大人\n适用于 macOS 27 · Apple Silicon\n媒体文件保存在你选择的本地目录。",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        ))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "HERMES",
            .applicationIcon: NSApp.applicationIconImage as Any,
            .applicationVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            .version: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
            .credits: credits
        ])
    }

    @objc private func showSettings(_ sender: Any?) {
        let controller = settingsWindowController ?? SettingsWindowController()
        settingsWindowController = controller
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    @objc private func openImportPanel(_ sender: Any?) {
        NotificationCenter.default.post(name: .openImportPanel, object: nil)
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
