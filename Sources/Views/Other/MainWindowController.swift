import AppKit
import Combine

final class MainWindowController: NSWindowController {
    private static let frameAutosaveName = "HERMESMainWindow"
    private static let preferredWindowSize = NSSize(width: 1120, height: 720)
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
                if section == model.selection {
                    model.resetSelectedPageScrollToTop()
                } else {
                    model.selection = section
                }
            }
        )
        detailController = DetailPagesController(model: model)
        toolbarController = NativeWindowToolbarController(
            model: model,
            windowTitle: "HERMES",
            windowSubtitle: model.queueSubtitle,
            clearQueue: { [model] in model.clear() },
            clearCompleted: {},
            clearDownloads: {}
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

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = false
        sidebarItem.holdingPriority = .defaultLow

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
        window.toolbarStyle = .unified
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
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
            Task { @MainActor in self?.model.chooseFiles() }
        })
        observers.append(center.addObserver(forName: .startImport, object: nil, queue: .main) { [weak self] _ in
            guard let model = self?.model else { return }
            Task { await model.processPairs() }
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
        if section == model.selection {
            model.resetSelectedPageScrollToTop()
        } else {
            model.selection = section
        }
    }

    private func refreshCurrentPage() {
        switch model.selection ?? .queue {
        case .queue:
            model.resetSelectedPageScrollToTop()
        case .downloads:
            model.refreshDownloads()
        case .completed:
            model.refreshCompleted()
        }
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
            model.chooseOutputFolder()
        case .downloads:
            model.chooseDownloadOutputFolder()
        case .completed:
            model.chooseOutputFolder()
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
        let alert = NSAlert()
        alert.messageText = completedClearAlertTitle
        alert.informativeText = completedClearAlertMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: completedClearPrimaryButtonTitle)
        alert.addButton(withTitle: "同时移到废纸篓")
        alert.addButton(withTitle: "取消")

        if alert.buttons.indices.contains(1) {
            alert.buttons[1].hasDestructiveAction = true
        }

        if let cancelButton = alert.buttons.last {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                self.model.clearVisibleCompleted(deleteFiles: false)
            case .alertSecondButtonReturn:
                self.model.clearVisibleCompleted(deleteFiles: true)
            default:
                break
            }
        }

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func presentDownloadClearConfirmation() {
        let alert = NSAlert()
        alert.messageText = downloadClearTargetsSelection ? "确定要删除选中的照片吗？" : "确定要清空吗？"
        alert.informativeText = downloadClearTargetsSelection
            ? "删除会移除选中照片的记录；同时删除源文件会一并将本地下载和合成的照片、视频文件移到废纸篓。"
            : "清空会移除当前筛选中的全部记录；同时删除源文件会一并将本地下载和合成的照片、视频文件移到废纸篓。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: downloadClearTargetsSelection ? "删除" : "清空")
        alert.addButton(withTitle: "同时移到废纸篓")
        alert.addButton(withTitle: "取消")

        if alert.buttons.indices.contains(1) {
            alert.buttons[1].hasDestructiveAction = true
        }

        if let cancelButton = alert.buttons.last {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                self.model.clearVisibleDownloads(deleteFiles: false)
            case .alertSecondButtonReturn:
                self.model.clearVisibleDownloads(deleteFiles: true)
            default:
                break
            }
        }

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

}
