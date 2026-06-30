import AppKit
import Combine

final class MainWindowController: NSWindowController {
    private static let frameAutosaveName = "HERMESMainWindow"
    private static let preferredWindowSize = NSSize(width: 1440, height: 1080)
    private static let minimumWindowSize = NSSize(width: 920, height: 620)

    private let model = ImporterModel()
    private let splitViewController = NSSplitViewController()
    private let sidebarController: FinderStyleSidebarController
    private let detailController: DetailPagesController
    private let toolbarController: NativeWindowToolbarController
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []

    init() {
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
        window.minSize = Self.minimumWindowSize
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
        updateWindowSizeLimits()
    }

    private func configureSplitView() {
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin

        let sidebarItem = sidebarController.makeSplitViewItem()
        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 520
        detailItem.canCollapse = false

        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)
        splitViewController.splitView.setPosition(220, ofDividerAt: 0)
    }

    private func configureWindow() {
        guard let window else { return }
        window.isRestorable = false
        window.title = pageTitle
        window.subtitle = pageSubtitle
        SystemWindowBackgroundController.configureMainWindow(window)
        updateWindowSizeLimits()
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
    }

    private func updateWindowSizeLimits() {
        guard let window else { return }
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        guard !visibleFrame.isEmpty else { return }

        let maxSize = NSSize(
            width: floor(visibleFrame.width),
            height: floor(visibleFrame.height)
        )
        if window.maxSize != maxSize {
            window.maxSize = maxSize
        }
        if window.contentMaxSize != maxSize {
            window.contentMaxSize = maxSize
        }

        let minSize = NSSize(
            width: min(Self.minimumWindowSize.width, maxSize.width),
            height: min(Self.minimumWindowSize.height, maxSize.height)
        )
        if window.minSize != minSize {
            window.minSize = minSize
        }
        if window.contentMinSize != minSize {
            window.contentMinSize = minSize
        }

        clampWindowFrame(visibleFrame: visibleFrame)
    }

    private func clampWindowToScreen() {
        guard let window else { return }
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        guard !visibleFrame.isEmpty else { return }

        let maxSize = NSSize(
            width: floor(visibleFrame.width),
            height: floor(visibleFrame.height)
        )
        if window.maxSize != maxSize {
            window.maxSize = maxSize
        }
        if window.contentMaxSize != maxSize {
            window.contentMaxSize = maxSize
        }

        clampWindowFrame(visibleFrame: visibleFrame)
    }

    private func clampWindowFrame(visibleFrame: NSRect) {
        guard let window else { return }
        var frame = window.frame
        var shouldClampFrame = false
        if frame.width > visibleFrame.width {
            frame.size.width = visibleFrame.width
            shouldClampFrame = true
        }
        if frame.height > visibleFrame.height {
            frame.size.height = visibleFrame.height
            shouldClampFrame = true
        }
        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
            shouldClampFrame = true
        }
        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
            shouldClampFrame = true
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = visibleFrame.maxY - frame.height
            shouldClampFrame = true
        }
        if frame.minY < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
            shouldClampFrame = true
        }
        if shouldClampFrame {
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private func installNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .openImportPanel, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.presentImportPanel() }
        })
        observers.append(center.addObserver(forName: .startImport, object: nil, queue: .main) { [weak self] _ in
            guard let model = self?.model else { return }
            Task { await model.processPairs() }
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
        observers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) { [weak self] notification in
            guard let changedWindow = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self, weak changedWindow] in
                guard let self, let changedWindow, changedWindow === self.window else { return }
                self.updateWindowSizeLimits()
            }
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
        model.addFiles(urls)
    }

    private func startDownload() {
        if model.needsDewuLogAccessForCurrentDownload,
           let dataRoot = NativePanelPresenter.chooseDewuDataRoot() {
            _ = DewuLogStore.authorizeDataRoot(dataRoot)
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
        switch model.selection ?? .queue {
        case .queue:
            guard let folder = NativePanelPresenter.chooseOutputParentFolder() else { return }
            model.selectOutputParentFolder(folder)
        case .downloads:
            guard let folder = NativePanelPresenter.chooseDownloadOutputFolder() else { return }
            model.selectDownloadOutputFolder(folder)
        case .completed:
            guard let folder = NativePanelPresenter.chooseOutputParentFolder() else { return }
            model.selectOutputParentFolder(folder)
        }
    }

    private var completedClearTargetsSelection: Bool {
        !model.selectedCompletedIDs.isEmpty
    }

    private var downloadClearTargetsSelection: Bool {
        !model.selectedDownloadItemIDs.isEmpty
    }

    private var completedClearAlertTitle: String {
        completedClearTargetsSelection ? "确定要删除选中的照片吗？" : "确定要清空吗？"
    }

    private var completedClearPrimaryButtonTitle: String {
        completedClearTargetsSelection ? "删除" : "清空"
    }

    private var completedClearAlertMessage: String {
        if completedClearTargetsSelection {
            return "删除会移除选中照片的完成记录；同时删除源文件会一并将本地导出的照片和视频文件移到废纸篓。"
        }
        return "清空会移除当前筛选中的全部完成记录；同时删除源文件会一并将本地导出的照片和视频文件移到废纸篓。"
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
            title: downloadClearTargetsSelection ? "确定要删除选中的照片吗？" : "确定要清空吗？",
            message: downloadClearTargetsSelection
                ? "删除会移除选中照片的记录；同时删除源文件会一并将本地下载和合成的照片、视频文件移到废纸篓。"
                : "清空会移除当前筛选中的全部记录；同时删除源文件会一并将本地下载和合成的照片、视频文件移到废纸篓。",
            primaryButtonTitle: downloadClearTargetsSelection ? "删除" : "清空"
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
