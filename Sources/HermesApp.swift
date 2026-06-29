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

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "关于 HERMES", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
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

        let navMenuItem = NSMenuItem()
        mainMenu.addItem(navMenuItem)
        let navMenu = NSMenu(title: "导航")
        navMenuItem.submenu = navMenu
        let queueItem = NSMenuItem(title: "开始", action: #selector(selectQueue(_:)), keyEquivalent: "1")
        queueItem.target = self
        navMenu.addItem(queueItem)
        let downloadsItem = NSMenuItem(title: "下载器", action: #selector(selectDownloads(_:)), keyEquivalent: "2")
        downloadsItem.target = self
        navMenu.addItem(downloadsItem)
        let completedItem = NSMenuItem(title: "已完成", action: #selector(selectCompleted(_:)), keyEquivalent: "3")
        completedItem.target = self
        navMenu.addItem(completedItem)

        let actionMenuItem = NSMenuItem()
        mainMenu.addItem(actionMenuItem)
        let actionMenu = NSMenu(title: "操作")
        actionMenuItem.submenu = actionMenu
        let refreshItem = NSMenuItem(title: "刷新当前页面", action: #selector(refreshCurrentPage(_:)), keyEquivalent: "r")
        refreshItem.target = self
        actionMenu.addItem(refreshItem)
        let openFolderItem = NSMenuItem(title: "打开当前文件夹", action: #selector(openCurrentFolder(_:)), keyEquivalent: "o")
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        openFolderItem.target = self
        actionMenu.addItem(openFolderItem)
        let chooseFolderItem = NSMenuItem(title: "选择当前文件夹...", action: #selector(chooseCurrentFolder(_:)), keyEquivalent: "")
        chooseFolderItem.target = self
        actionMenu.addItem(chooseFolderItem)

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
    static let selectSidebarSection = Notification.Name("SelectSidebarSection")
    static let refreshCurrentPage = Notification.Name("RefreshCurrentPage")
    static let openCurrentFolder = Notification.Name("OpenCurrentFolder")
    static let chooseCurrentFolder = Notification.Name("ChooseCurrentFolder")
}
