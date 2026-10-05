import AppKit
import Combine

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "HERMESMainWindow"
    private static let preferredWindowSize = NSSize(width: 1440, height: 1080)
    private static let minimumContentHeight: CGFloat = 620

    let model: ImporterModel
    var canComposeCurrentPage: Bool { model.canComposeCurrentPage }
    private let splitViewController = MainSplitViewController()
    private let sidebarController: FinderStyleSidebarController
    private let detailController: DetailPagesController
    private let toolbarController: NativeWindowToolbarController
    let inspectorController: MediaInspectorController
    private let inspectorDefaults: UserDefaults
    private var inspectorItem: NSSplitViewItem?
    private var inspectorObservation: NSKeyValueObservation?
    static let inspectorVisibleDefaultsKey = "HERMESInspectorVisible.v1"
    var inspectorVisible: Bool { inspectorItem?.isCollapsed == false }
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var terminationProgressAlert: NSAlert?
    var requestTermination: () -> Void = { NSApp.terminate(nil) }

    init(model: ImporterModel = ImporterModel(), inspectorDefaults: UserDefaults = .standard) {
        self.model = model
        self.inspectorDefaults = inspectorDefaults
        inspectorController = MediaInspectorController(model: model)
        sidebarController = FinderStyleSidebarController(
            sections: SidebarSection.allCases,
            selection: model.selection,
            count: { [model] section in
                switch section {
                case .queue:
                    return nil
                case .downloads:
                    return model.downloadPairs.count + model.downloadPhotos.count + model.downloadVideos.count
                case .completed:
                    return model.completed.count
                }
            },
            onSelect: { [model] section in
                if section != model.selection {
                    model.selection = section
                }
            }
        )
        detailController = DetailPagesController(model: model) {
            NotificationCenter.default.post(name: .startDownload, object: nil)
        }
        toolbarController = NativeWindowToolbarController(
            model: model,
            windowTitle: "HERMES",
            windowSubtitle: model.queueSubtitle,
            clearQueue: { [model] in model.clear() },
            clearCompleted: {},
            clearDownloads: {},
            presentImportPanel: {},
            presentFolderChooser: {}
        )

        let window = NSWindow(contentViewController: splitViewController)
        window.setContentSize(Self.preferredWindowSize)
        super.init(window: window)
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        toolbarController.clearCompleted = { [weak self] in self?.presentCompletedClearConfirmation() }
        toolbarController.clearDownloads = { [weak self] in self?.presentDownloadClearConfirmation() }
        toolbarController.presentImportPanel = { [weak self] in self?.presentImportPanel() }
        toolbarController.presentFolderChooser = { [weak self] in self?.chooseCurrentFolder() }
        configureSplitView()
        configureWindow()
        bindModel()
        installNotifications()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        toolbarController.installToolbar(in: window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestTermination()
        return false
    }

    var terminationConfirmationMessage: String {
        let hasDownloads = model.isDownloading || model.downloadQueueCount > 0
        let hasProcessing = model.isProcessing || model.isProcessingDownloads
            || model.isImportingCompleted || model.isImportingDownloadMedia
        if hasDownloads && hasProcessing { return "将停止下载并清理临时文件，当前处理结束后退出。" }
        if hasDownloads { return "将停止下载并清理临时文件。" }
        if hasProcessing { return "当前处理结束后退出。" }
        return "将结束当前任务并退出。"
    }

    static func makeTerminationConfirmationAlert(message: String = "将停止下载并清理临时文件。") -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "退出 HERMES？"
        alert.informativeText = message
        alert.addButton(withTitle: "继续运行")
        alert.addButton(withTitle: "退出")
        alert.buttons[0].keyEquivalent = "\u{1b}"
        alert.buttons[1].hasDestructiveAction = true
        return alert
    }

    func confirmTermination(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        showWindow(nil)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        guard let window else { completion(false); return }
        presentAfterDismissingCurrentSheet {
            let alert = Self.makeTerminationConfirmationAlert(message: self.terminationConfirmationMessage)
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertSecondButtonReturn)
            }
        }
    }

    static func makeTerminationProgressAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "正在结束任务…"
        alert.informativeText = "任务结束后将自动退出。"
        let progress = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 240, height: 0))
        progress.style = .bar
        progress.controlSize = .regular
        progress.isIndeterminate = true
        progress.sizeToFit()
        alert.accessoryView = progress
        // An alert without explicit buttons creates an actionable OK button.
        // Keep AppKit's response-button layout while cleanup owns completion.
        let exitButton = alert.addButton(withTitle: "退出")
        exitButton.isEnabled = false
        exitButton.keyEquivalent = ""
        return alert
    }

    func showTerminationProgress() {
        guard terminationProgressAlert == nil, let window else { return }
        let alert = Self.makeTerminationProgressAlert()
        terminationProgressAlert = alert
        presentAfterDismissingCurrentSheet { [weak self, alert] in
            guard self?.terminationProgressAlert === alert else { return }
            (alert.accessoryView as? NSProgressIndicator)?.startAnimation(nil)
            alert.beginSheetModal(for: window) { [weak self, weak alert] _ in
                guard let self, let alert, self.terminationProgressAlert === alert else { return }
                (alert.accessoryView as? NSProgressIndicator)?.stopAnimation(nil)
                self.terminationProgressAlert = nil
            }
        }
    }

    func hideTerminationProgress() {
        guard let alert = terminationProgressAlert else { return }
        terminationProgressAlert = nil
        (alert.accessoryView as? NSProgressIndicator)?.stopAnimation(nil)
        let sheet = alert.window
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
    }

    private func presentAfterDismissingCurrentSheet(_ presentation: @escaping @MainActor @Sendable () -> Void) {
        guard let window else { return }
        if let sheet = window.attachedSheet {
            window.endSheet(sheet, returnCode: .cancel)
            DispatchQueue.main.async(execute: presentation)
        } else {
            // applicationShouldTerminate must return terminateLater before a reply.
            DispatchQueue.main.async(execute: presentation)
        }
    }

    private func configureSplitView() {
        splitViewController.inspectorController = inspectorController
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin

        let sidebarItem = sidebarController.makeSplitViewItem()
        let detailItem = NSSplitViewItem(viewController: detailController)
        // Native glass hugs at 250; the comfortable input width uses 251.
        // Pane widths take precedence, with the sidebar retained before the
        // content pane. Stay below AppKit's drag-resize priority of 490.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 3)
        detailItem.holdingPriority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 2)
        detailItem.minimumThickness = 520
        detailItem.canCollapse = false

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)
        let inspector = NSSplitViewItem(inspectorWithViewController: inspectorController)
        // Let AppKit allocate inspector space inside the window. Its
        // pane-preserving window resize mode adds 1pt on every round trip
        // on macOS 27, even when the split view has zero-thickness dividers.
        inspector.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        let startsInspectorCollapsed = !inspectorDefaults.bool(forKey: Self.inspectorVisibleDefaultsKey)
        inspector.isCollapsed = startsInspectorCollapsed
        inspectorItem = inspector
        splitViewController.addSplitViewItem(inspector)
        // Restore only after every pane exists. Enabling autosave on an empty
        // split view overwrites the saved divider sizes during construction.
        splitViewController.splitView.autosaveName = "HERMESMainSplitView"
        // A recently toggled inspector may have newer explicit visibility than
        // the last saved frames. Keep that preference authoritative.
        inspector.isCollapsed = startsInspectorCollapsed
        inspectorController.isInspectionEnabled = !inspector.isCollapsed
        inspectorObservation = inspector.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.inspectorVisibilityDidChange() }
        }
        // AppKit derives the window's width limits from the visible split items
        // and owns pane collapse, screen changes, zoom and fullscreen sizing.
        splitViewController.view.heightAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumContentHeight
        ).isActive = true
    }

    func setInspectorVisible(_ visible: Bool) {
        inspectorItem?.isCollapsed = !visible
    }

    private func inspectorVisibilityDidChange() {
        let visible = inspectorVisible
        inspectorDefaults.set(visible, forKey: Self.inspectorVisibleDefaultsKey)
        inspectorController.isInspectionEnabled = visible
    }

    private func configureWindow() {
        guard let window else { return }
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = pageTitle
        window.subtitle = pageSubtitle
        SystemWindowBackgroundController.configureMainWindow(window)
    }

    private var needsReload = false

    private func scheduleReload() {
        guard !needsReload else { return }
        needsReload = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.needsReload = false
            self.reloadUI()
        }
    }

    private func bindModel() {
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleReload()
            }
            .store(in: &cancellables)

        reloadUI()
    }

    private func reloadUI() {
        window?.title = pageTitle
        window?.subtitle = pageSubtitle
        sidebarController.update(
            sections: SidebarSection.allCases,
            selection: model.selection,
            count: { [model] section in
                switch section {
                case .queue:
                    return nil
                case .downloads:
                    return model.downloadPairs.count + model.downloadPhotos.count + model.downloadVideos.count
                case .completed:
                    return model.completed.count
                }
            }
        )
        toolbarController.reloadToolbarIfNeeded()
        detailController.reload()
        inspectorController.reload()
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .openImportPanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.presentImportPanel() }
        })
        observers.append(center.addObserver(forName: .startImport, object: nil, queue: .main) { [weak self] _ in
            guard let model = self?.model else { return }
            Task { await model.composeCurrentPage() }
        })
        observers.append(center.addObserver(forName: .startDownload, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startDownload() }
        })
        observers.append(center.addObserver(forName: .selectSidebarSection, object: nil, queue: .main) { [weak self] notification in
            guard let self, let section = notification.object as? SidebarSection else { return }
            Task { @MainActor in self.selectSidebarSection(section) }
        })
        observers.append(center.addObserver(forName: .refreshCurrentPage, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCurrentPage() }
        })
        observers.append(center.addObserver(forName: .openCurrentFolder, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openCurrentFolder() }
        })
        observers.append(center.addObserver(forName: .chooseCurrentFolder, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.chooseCurrentFolder() }
        })
    }

    private var pageTitle: String {
        switch model.selection ?? .queue {
        case .queue:
            "HERMES"
        case .downloads:
            "下载器"
        case .completed:
            "已完成"
        }
    }

    private var pageSubtitle: String {
        switch model.selection ?? .queue {
        case .queue:
            Self.displaySubtitle(for: model.outputFolder)
        case .downloads:
            Self.displaySubtitle(for: model.downloadOutputFolder)
        case .completed:
            Self.displaySubtitle(for: model.outputFolder)
        }
    }

    private static func displaySubtitle(for folder: URL) -> String {
        folder.path
    }

    private func selectSidebarSection(_ section: SidebarSection) {
        if section != model.selection {
            model.selection = section
        }
    }

    private func refreshCurrentPage() {
        switch model.selection ?? .queue {
        case .queue:
            break
        case .downloads:
            model.refreshDownloads()
        case .completed:
            model.refreshCompleted()
        }
    }

    private func presentImportPanel() {
        guard let urls = NativePanelPresenter.chooseImportURLs() else { return }
        Task { await model.addFiles(urls) }
    }

    private func startDownload() {
        if model.needsDewuLogAccessForCurrentDownload {
            _ = NativePanelPresenter.authorizeDewuDataRootIfNeeded()
        }
        Task { await model.downloadShare() }
    }

    private func openCurrentFolder() {
        switch model.selection ?? .queue {
        case .queue:
            model.openOutputFolder()
        case .downloads:
            model.openDownloadOutputFolder()
        case .completed:
            model.openOutputFolder()
        }
    }

    private func chooseCurrentFolder() {
        guard model.selection == .downloads || model.canMoveOutputFolder else { return }
        switch model.selection ?? .queue {
        case .queue:
            guard let folder = NativePanelPresenter.chooseOutputParentFolder() else { return }
            confirmOutputFolderMove(to: folder)
        case .downloads:
            guard let folder = NativePanelPresenter.chooseDownloadOutputFolder() else { return }
            model.selectDownloadOutputFolder(folder)
        case .completed:
            guard let folder = NativePanelPresenter.chooseOutputParentFolder() else { return }
            confirmOutputFolderMove(to: folder)
        }
    }

    private func confirmOutputFolderMove(to parent: URL) {
        let destination = parent.resolvingSymlinksInPath().appendingPathComponent("HERMES", isDirectory: true)
        guard destination.standardizedFileURL != model.outputFolder.standardizedFileURL else { return }
        let alert = NSAlert()
        alert.messageText = "移动导出文件夹？"
        alert.informativeText = "将移动现有文件夹及其中的文件，并更新相关记录。\n\n原位置：\(model.outputFolder.path)\n新位置：\(destination.path)"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移动")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.model.selectOutputParentFolder(parent) }
        }
    }

    private var completedClearTargetsSelection: Bool {
        !model.selectedCompletedIDs.isEmpty
    }

    private var downloadClearTargetsSelection: Bool {
        !model.selectedDownloadItemIDs.isEmpty
    }

    private var completedClearAlertTitle: String {
        completedClearTargetsSelection ? "移除选中的记录？" : "清空当前筛选中的记录？"
    }

    private var completedClearPrimaryButtonTitle: String {
        completedClearTargetsSelection ? "仅移除记录" : "仅清空记录"
    }

    private var completedClearAlertMessage: String {
        if completedClearTargetsSelection {
            return "“仅移除记录”会保留本地文件；“同时移到废纸篓”还会移走所选项目对应的本地导出照片和视频。"
        }
        return "“仅清空记录”会移除当前筛选中的全部记录并保留本地文件；“同时移到废纸篓”还会移走这些记录对应的本地导出照片和视频。"
    }

    private func presentCompletedClearConfirmation() {
        NativePanelPresenter.presentDestructiveConfirmation(
            in: window,
            title: completedClearAlertTitle,
            message: completedClearAlertMessage,
            primaryButtonTitle: completedClearPrimaryButtonTitle
        ) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .primary:
                self.model.clearVisibleCompleted(deleteFiles: false)
            case .deleteFiles:
                self.model.clearVisibleCompleted(deleteFiles: true)
            case .cancel:
                break
            }
        }
    }

    private func presentDownloadClearConfirmation() {
        NativePanelPresenter.presentDestructiveConfirmation(
            in: window,
            title: downloadClearTargetsSelection ? "移除选中的记录？" : "清空当前筛选中的记录？",
            message: downloadClearTargetsSelection
                ? "“仅移除记录”会保留本地文件；“同时移到废纸篓”还会移走所选项目对应的下载源文件；已合成导出文件会保留，请在“已完成”页管理。"
                : "“仅清空记录”会移除当前筛选中的全部记录并保留本地文件；“同时移到废纸篓”还会移走这些记录对应的下载源文件；已合成导出文件会保留，请在“已完成”页管理。",
            primaryButtonTitle: downloadClearTargetsSelection ? "仅移除记录" : "仅清空记录"
        ) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .primary:
                self.model.clearVisibleDownloads(deleteFiles: false)
            case .deleteFiles:
                self.model.clearVisibleDownloads(deleteFiles: true)
            case .cancel:
                break
            }
        }
    }

}

/// Keep the system pane animations, but avoid reading and wrapping the inspector
/// form while AppKit is changing the widths of the split items.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    weak var inspectorController: MediaInspectorController?

    override func loadView() {
        splitView = MainWindowSplitView()
        super.loadView()
    }

    override func toggleSidebar(_ sender: Any?) {
        animatePaneToggle { super.toggleSidebar(sender) }
    }

    override func toggleInspector(_ sender: Any?) {
        animatePaneToggle { super.toggleInspector(sender) }
    }

    private func animatePaneToggle(_ toggle: () -> Void) {
        inspectorController?.beginPaneTransition()
        NSAnimationContext.runAnimationGroup { _ in
            toggle()
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.inspectorController?.endPaneTransition() }
        }
    }
}

/// Native pane materials distinguish the sections. NSSplitView's public
/// divider hooks remove the line while preserving its layout and drag regions.
private final class MainWindowSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 0 }
    override func drawDivider(in rect: NSRect) {}
}
