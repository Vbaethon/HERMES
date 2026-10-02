import AppKit
import Foundation

@main enum UIUXRegression {
    @MainActor static func main() {
        precondition(Bundle.main.bundleIdentifier != "com.codex.Hermes")
        _ = NSApplication.shared
        Task { @MainActor in
            do {
                try await runChecks()
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("UI/UX regression failed: \(error)\n".utf8))
                exit(1)
            }
        }
        NSApp.run()
    }

    @MainActor static func runChecks() async throws {
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

        func waitUntil(_ condition: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            expect(condition(), "asynchronous UI operation timed out")
        }
        let terminationModel = ImporterModel(refreshOnInit: false)
        let terminationWindow = MainWindowController(model: terminationModel)
        var windowQuitRequests = 0
        terminationWindow.requestTermination = { windowQuitRequests += 1 }
        expect(!terminationWindow.windowShouldClose(terminationWindow.window!), "window close must defer to the application termination flow")
        terminationModel.isDownloading = true
        expect(!terminationWindow.windowShouldClose(terminationWindow.window!) && windowQuitRequests == 2, "idle and busy window closes must request the same application termination flow")
        expect(terminationWindow.terminationConfirmationMessage == "将停止下载并清理临时文件。", "download confirmation must describe cancellation and partial-file cleanup")
        terminationModel.isDownloading = false
        terminationModel.isProcessing = true
        expect(terminationWindow.terminationConfirmationMessage == "当前处理结束后退出。", "processing confirmation must describe waiting for its safe completion")
        let terminationAlert = MainWindowController.makeTerminationConfirmationAlert(message: terminationWindow.terminationConfirmationMessage)
        expect(terminationAlert.messageText == "退出 HERMES？" && terminationAlert.buttons.map(\.title) == ["继续运行", "退出"], "termination confirmation must expose the short message and both choices")
        expect(terminationAlert.buttons[0].keyEquivalent == "\u{1b}" && terminationAlert.buttons[1].hasDestructiveAction, "continue must support Escape and exit must be visibly distinct")
        let progressAlert = MainWindowController.makeTerminationProgressAlert()
        let progressAccessory = progressAlert.accessoryView as! NSProgressIndicator
        expect(progressAlert.messageText == "正在结束任务…" && progressAlert.informativeText == "任务结束后将自动退出。", "native progress alert must explain the pending automatic exit")
        expect(progressAccessory.isIndeterminate && progressAccessory.style == .bar, "cleanup must use a standard indeterminate progress accessory")
        expect(!progressAlert.buttons.isEmpty && progressAlert.buttons.allSatisfy { !$0.isEnabled }, "progress alert must not expose an actionable implicit OK or early-exit button")
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            progressAlert.window.appearance = NSAppearance(named: appearanceName)
            progressAlert.layout()
            let content = progressAlert.window.contentView!
            content.layoutSubtreeIfNeeded()
            let progressRect = content.convert(progressAccessory.bounds, from: progressAccessory)
            expect(progressRect.width > 0 && progressRect.height > 0 && content.bounds.contains(progressRect), "AppKit must allocate unclipped native progress accessory geometry")
            for button in progressAlert.buttons {
                let buttonRect = content.convert(button.bounds, from: button)
                expect(!progressRect.intersects(buttonRect), "native alert layout must separate progress from its response controls")
            }
        }
        let terminationDelegate = HermesAppDelegate(mainWindowController: terminationWindow)
        var terminationReplies: [Bool] = []
        terminationDelegate.terminationReplyHandler = { terminationReplies.append($0) }
        expect(terminationDelegate.applicationShouldTerminate(NSApp) == .terminateLater, "busy termination must defer its application reply")
        expect(terminationDelegate.applicationShouldTerminate(NSApp) == .terminateLater, "a repeated quit must join the pending confirmation")
        try await waitUntil { terminationWindow.window?.attachedSheet != nil }
        let cancelSheet = terminationWindow.window!.attachedSheet!
        terminationWindow.window!.endSheet(cancelSheet, returnCode: .alertFirstButtonReturn)
        try await waitUntil { terminationReplies == [false] }
        expect(!terminationModel.isPreparingToQuit && terminationModel.isProcessing, "continue must keep the existing operation running")
        expect(terminationDelegate.applicationShouldTerminate(NSApp) == .terminateLater, "a new quit after Continue must present confirmation again")
        try await waitUntil { terminationWindow.window?.attachedSheet != nil }
        terminationWindow.window!.endSheet(terminationWindow.window!.attachedSheet!, returnCode: .alertSecondButtonReturn)
        try await waitUntil { terminationModel.isPreparingToQuit && terminationWindow.window?.attachedSheet != nil }
        let finishingSheet = terminationWindow.window!.attachedSheet!
        expect(descendants(finishingSheet.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "正在结束任务…" }, "pending cleanup must display its concise progress state")
        expect(descendants(finishingSheet.contentView!).compactMap { $0 as? NSProgressIndicator }.count == 1, "pending cleanup must remain responsive with native progress")
        let progressExitButtons = descendants(finishingSheet.contentView!).compactMap { $0 as? NSButton }.filter { $0.title == "退出" }
        expect(progressExitButtons.count == 1 && !progressExitButtons[0].isEnabled, "pending cleanup must retain the disabled native exit response")
        progressExitButtons[0].performClick(nil)
        try await Task.sleep(for: .milliseconds(100))
        expect(terminationWindow.window!.attachedSheet === finishingSheet && terminationModel.isProcessing, "disabled progress response must not dismiss safe cleanup")
        expect(terminationReplies == [false], "Exit must not terminate before the ongoing processing boundary")
        expect(terminationDelegate.applicationShouldTerminate(NSApp) == .terminateLater && terminationWindow.window!.attachedSheet === finishingSheet, "another quit during cleanup must retain the same progress sheet")
        terminationModel.isProcessing = false
        try await waitUntil { terminationReplies == [false, true] }
        expect(terminationWindow.window!.attachedSheet == nil, "the progress sheet must finish before the application termination reply")
        terminationWindow.showTerminationProgress()
        terminationWindow.hideTerminationProgress()
        try await Task.sleep(for: .milliseconds(100))
        expect(terminationWindow.window!.attachedSheet == nil, "cleanup that finishes before deferred presentation must not leave an orphan progress sheet")
        terminationWindow.window?.orderOut(nil)
        pass("window close and Cmd-Q share native confirmation/progress alerts; Continue preserves work and Exit waits for safe cleanup")

        let settingsSuiteName = "HermesSettingsRegression.\(UUID().uuidString)"
        let settingsDefaults = UserDefaults(suiteName: settingsSuiteName)!
        defer { settingsDefaults.removePersistentDomain(forName: settingsSuiteName) }
        let settings = SettingsWindowController(model: model, defaults: settingsDefaults)
        let settingsWindow = settings.window!
        let settingsSplit = settingsWindow.contentViewController as! SettingsViewController
        // Compare against the actual main-window sidebar, so a separately
        // styled settings implementation cannot silently diverge from it.
        let referenceWindow = terminationWindow.window!
        let referenceSplit = referenceWindow.contentViewController as! NSSplitViewController
        let referenceSidebar = referenceSplit.splitViewItems[0].viewController as! FinderStyleSidebarController
        let referenceNavigation = descendants(referenceSidebar.view).compactMap { $0 as? NSTableView }.first!
        referenceWindow.orderFront(nil)
        expect(settingsSplit.splitViewItems.count == 2, "settings must use native sidebar and detail containment")
        expect(settingsSplit.selectedPane == .synthesis, "new settings must start with the synthesis category")
        expect(settingsWindow.toolbarStyle == .unifiedCompact, "settings must use the native compact window toolbar")
        expect(settingsWindow.title == "设置", "settings must have a stable window title")
        expect(!settingsWindow.styleMask.contains(.resizable), "settings must retain their fixed dimensions")
        let fixedSettingsFrame = settingsWindow.frame
        let fixedSettingsContentRect = settingsWindow.contentLayoutRect
        expect(settingsWindow.standardWindowButton(.miniaturizeButton)?.isEnabled == false && settingsWindow.standardWindowButton(.zoomButton)?.isEnabled == false, "settings must retain dimmed native minimize and zoom controls")
        settingsWindow.performMiniaturize(nil)
        settingsWindow.miniaturize(nil)
        expect(!settingsWindow.isMiniaturized, "settings must stay available when a minimize action is sent")
        for action in [#selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.toggleToolbarShown(_:))] {
            let unavailableAction = NSMenuItem(title: "Unavailable settings action", action: action, keyEquivalent: "")
            expect(!settingsWindow.validateMenuItem(unavailableAction) && !settingsWindow.validateUserInterfaceItem(unavailableAction), "settings must disable minimize and toolbar-hiding commands")
        }
        expect(!settingsWindow.toolbar!.allowsUserCustomization, "essential settings categories must remain available")
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
        let settingsRoot = settingsWindow.contentView!
        // Realize the representable's actual AppKit controls in this isolated
        // test window, using the application's native display event loop.
        settingsWindow.orderFront(nil)
        settingsRoot.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        settingsRoot.layoutSubtreeIfNeeded()
        try await waitUntil {
            descendants(settingsSplit.splitViewItems[0].viewController.view).contains { $0 is NSTableView }
        }
        let settingsNavigation = descendants(settingsSplit.splitViewItems[0].viewController.view).compactMap { $0 as? NSTableView }.first!
        expect(settingsSplit.splitView.arrangedSubviews.count == 2, "native split layout must allocate two settings panes")
        // Exercise the native sidebar and Form controls through public
        // AppKit types, without relying on SwiftUI's private backing classes.
        expect(SettingsViewController.Pane.synthesis.symbolName == AppSymbol.composeLivePhoto.normal && SettingsViewController.Pane.completed.symbolName == AppSymbol.completed.normal, "settings categories must share the main application's symbol definitions")
        func sidebarCell(_ table: NSTableView, row: Int) -> NSTableCellView {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  cell.imageView?.image != nil, cell.textField?.font != nil else {
                preconditionFailure("navigation must expose native image and title cells")
            }
            cell.layoutSubtreeIfNeeded()
            return cell
        }
        func verifySettingsNativeSidebar() {
            expect(settingsNavigation.numberOfRows == SettingsViewController.Pane.allCases.count, "the native sidebar must expose each settings category")
            expect(settingsNavigation.style == referenceNavigation.style && settingsNavigation.rowSizeStyle == referenceNavigation.rowSizeStyle && settingsNavigation.effectiveRowSizeStyle == referenceNavigation.effectiveRowSizeStyle, "settings and main navigation must use the same native sidebar style and system row-size preference")
            for (row, pane) in SettingsViewController.Pane.allCases.enumerated() {
                expect(NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title) != nil, "settings categories must use available system symbols")
                let rect = settingsNavigation.rect(ofRow: row)
                expect(rect.width > 0 && rect.height > 0, "native sidebar categories must retain usable geometry")
                let isSelected = settingsNavigation.selectedRow == row
                let referenceSection: SidebarSection = pane == .synthesis ? .queue : .completed
                let referenceRow = SidebarSection.allCases.firstIndex(of: referenceSection)!
                referenceSidebar.update(sections: SidebarSection.allCases, selection: isSelected ? referenceSection : (referenceSection == .queue ? .completed : .queue), count: { _ in nil })
                referenceSidebar.view.layoutSubtreeIfNeeded()
                let cell = sidebarCell(settingsNavigation, row: row)
                let referenceCell = sidebarCell(referenceNavigation, row: referenceRow)
                let image = cell.imageView!
                let referenceImage = referenceCell.imageView!
                let title = cell.textField!
                let referenceTitle = referenceCell.textField!
                let imageRect = image.convert(image.bounds, to: cell)
                let referenceImageRect = referenceImage.convert(referenceImage.bounds, to: referenceCell)
                let titleRect = title.convert(title.bounds, to: cell)
                let referenceTitleRect = referenceTitle.convert(referenceTitle.bounds, to: referenceCell)
                expect(cell.rowSizeStyle == referenceCell.rowSizeStyle && abs(rect.height - referenceNavigation.rect(ofRow: referenceRow).height) <= 1, "settings rows must inherit the main sidebar's native row height")
                // AppKit applies different optical insets to each SF Symbol.
                // Compare exact frames only for the same photo.stack glyph;
                // both categories still share typography and row-size checks.
                if pane == .completed {
                    expect(abs(imageRect.width - referenceImageRect.width) <= 0.5 && abs(imageRect.height - referenceImageRect.height) <= 0.5, "the same settings and main sidebar symbol must occupy the same image-view size")
                    expect(abs((imageRect.minX - cell.bounds.minX) - (referenceImageRect.minX - referenceCell.bounds.minX)) <= 0.5, "the same settings and main sidebar symbol must share leading padding")
                    expect(abs((titleRect.minX - imageRect.maxX) - (referenceTitleRect.minX - referenceImageRect.maxX)) <= 0.5, "the same settings and main sidebar symbol must share icon-to-label spacing")
                    expect(abs((imageRect.midY - cell.bounds.midY) - (referenceImageRect.midY - referenceCell.bounds.midY)) <= 0.5 && abs((titleRect.midY - cell.bounds.midY) - (referenceTitleRect.midY - referenceCell.bounds.midY)) <= 0.5, "the same settings and main sidebar symbol and title must share vertical alignment")
                }
                expect(title.font == referenceTitle.font && image.imageScaling == referenceImage.imageScaling && image.contentTintColor == referenceImage.contentTintColor, "settings typography and symbol rendering must match the main sidebar in each selection state")
                expect(image.image!.isTemplate && image.image!.accessibilityDescription == pane.title, "settings must retain native template-symbol accessibility")
                let usableContent = settingsWindow.contentLayoutRect.insetBy(dx: -1, dy: -1)
                for component in [image as NSView, title as NSView] {
                    let componentRect = component.convert(component.bounds, to: nil)
                    if !usableContent.contains(componentRect) {
                        FileHandle.standardError.write(Data("Settings sidebar clipping: pane=\(pane) row=\(row) content=\(settingsWindow.contentLayoutRect) component=\(componentRect) sidebarSafeArea=\(settingsSplit.splitViewItems[0].viewController.view.safeAreaInsets)\n".utf8))
                    }
                    expect(componentRect.width > 0 && componentRect.height > 0 && usableContent.contains(componentRect), "settings sidebar icons and titles must remain fully below the glass toolbar inside usable window content")
                }
            }
        }
        let automaticID = "settings.importToPhotos"
        let albumID = "settings.addToAlbum"
        let manualID = "settings.completedAddToAlbum"
        func settingsControls() -> [NSSwitch] {
            descendants(settingsSplit.splitViewItems[1].viewController.view)
                .compactMap { $0 as? NSSwitch }
                .sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
        }
        func settingsControl(_ identifier: String) -> NSSwitch? {
            let identifiers = settingsSplit.selectedPane == .completed ? [manualID]
                : (model.importToPhotos ? [automaticID, albumID] : [automaticID])
            guard let index = identifiers.firstIndex(of: identifier) else { return nil }
            let controls = settingsControls()
            return controls.indices.contains(index) ? controls[index] : nil
        }
        func waitForSettingsRows(_ identifiers: [String]) async throws {
            let deadline = Date().addingTimeInterval(2)
            var stableSince: Date?
            while Date() < deadline {
                settingsRoot.layoutSubtreeIfNeeded()
                let controls = settingsControls()
                let matches = controls.count == identifiers.count
                    && controls.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 }
                if matches {
                    if let stableSince, Date().timeIntervalSince(stableSince) >= 0.1 { return }
                    if stableSince == nil { stableSince = Date() }
                } else {
                    stableSince = nil
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            preconditionFailure("native settings controls did not settle to \(identifiers); actual count=\(settingsControls().count)")
        }
        func sendSettingsAction(_ identifier: String, isOn: Bool) {
            let control = settingsControl(identifier)!
            expect(control.isEnabled, "visible settings switches must accept user changes")
            control.state = isOn ? .on : .off
            expect(control.sendAction(control.action, to: control.target), "native switch must dispatch its real model-binding action")
        }
        try await waitForSettingsRows([automaticID, albumID])
        expect(settingsControl(automaticID)!.state == .on && settingsControl(albumID)!.state == .off, "native switches must reflect initial model preferences")
        sendSettingsAction(albumID, isOn: true)
        expect(model.addToAlbum && UserDefaults.standard.bool(forKey: AppPreferenceKey.addToAlbum), "native album action must update and persist its real preference")
        sendSettingsAction(automaticID, isOn: false)
        try await waitForSettingsRows([automaticID])
        expect(!model.importToPhotos && !model.addToAlbum && !UserDefaults.standard.bool(forKey: AppPreferenceKey.addToAlbum), "native import action must clear its dependent album preference")
        expect(settingsControl(albumID) == nil, "disabled automatic import must remove the album option entirely")
        settingsSplit.selectPane(.completed)
        try await waitForSettingsRows([manualID])
        sendSettingsAction(manualID, isOn: true)
        expect(model.completedAddToAlbum && !model.importToPhotos && UserDefaults.standard.bool(forKey: AppPreferenceKey.completedAddToAlbum), "native manual album action must persist independently while automatic import is off")
        settingsSplit.selectPane(.synthesis)
        try await waitForSettingsRows([automaticID])
        sendSettingsAction(automaticID, isOn: true)
        try await waitForSettingsRows([automaticID, albumID])
        expect(!model.addToAlbum && settingsControl(albumID)!.state == .off, "reenabling automatic import must reveal the cleared album option without restoring its old value")
        model.addToAlbum = true
        try await waitUntil { settingsControl(albumID)?.state == .on }
        model.importToPhotos = false
        try await waitForSettingsRows([automaticID])
        model.importToPhotos = true
        try await waitForSettingsRows([automaticID, albumID])
        expect(settingsControl(automaticID)!.state == .on && settingsControl(albumID)!.state == .off, "external model updates must synchronize native switch state and conditional visibility")
        expect(model.completedAddToAlbum, "hiding automatic album settings must not reset the manual preference")
        model.completedAddToAlbum = false
        model.addToAlbum = true
        expect(UserDefaults.standard.bool(forKey: AppPreferenceKey.addToAlbum), "automatic album preference must persist")
        model.importToPhotos = false
        expect(!model.addToAlbum, "disabling automatic import must clear its dependent album preference")
        expect(!UserDefaults.standard.bool(forKey: AppPreferenceKey.addToAlbum), "disabling automatic import must persist the cleared album preference")
        model.importToPhotos = true
        model.completedAddToAlbum = true
        settingsSplit.selectPane(.completed)
        settingsRoot.layoutSubtreeIfNeeded()
        expect(settingsSplit.selectedPane == .completed, "selecting completed settings must switch the detail category")
        expect(settingsWindow.title == "设置", "switching settings categories must preserve the window title")
        expect(settingsWindow.frame == fixedSettingsFrame && settingsWindow.contentLayoutRect == fixedSettingsContentRect, "switching settings categories must preserve window dimensions and position")
        model.completedAddToAlbum = false
        expect(model.importToPhotos, "manual album preference must not change automatic import")
        expect(!UserDefaults.standard.bool(forKey: AppPreferenceKey.completedAddToAlbum), "manual album preference must persist independently")
        let savedPaneKey = SettingsViewController.selectedPanePreferenceKey
        expect(settingsDefaults.string(forKey: savedPaneKey) == "completed", "selected settings category must persist immediately")
        let restoredSettings = SettingsWindowController(model: model, defaults: settingsDefaults)
        let restoredSplit = restoredSettings.window!.contentViewController as! SettingsViewController
        expect(restoredSplit.selectedPane == .completed && restoredSettings.window!.title == "设置", "reopening settings must restore the category while keeping the window title")
        expect(restoredSettings.window!.frame.size == fixedSettingsFrame.size && restoredSettings.window!.contentLayoutRect.size == fixedSettingsContentRect.size, "restored settings categories must use the same fixed dimensions")
        settingsDefaults.set("removed-category", forKey: savedPaneKey)
        let fallbackSettings = SettingsWindowController(model: model, defaults: settingsDefaults)
        let fallbackSplit = fallbackSettings.window!.contentViewController as! SettingsViewController
        expect(fallbackSplit.selectedPane == .synthesis && fallbackSettings.window!.title == "设置", "an invalid saved category must fall back to available settings with the fixed title")
        expect(fallbackSettings.window!.frame.size == fixedSettingsFrame.size && fallbackSettings.window!.contentLayoutRect.size == fixedSettingsContentRect.size, "fallback settings must use the same fixed dimensions")
        expect(settingsWindow.makeFirstResponder(settingsNavigation), "settings sidebar must support keyboard focus")
        try await Task.sleep(for: .milliseconds(100))
        settingsNavigation.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        expect(settingsSplit.selectedPane == .synthesis, "native sidebar selection must switch settings categories")
        try await Task.sleep(for: .milliseconds(100))
        settingsNavigation.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        expect(settingsSplit.selectedPane == .completed, "native sidebar selection must reach the manual import settings")
        func detailFitsContent(_ rect: NSRect, beside sidebarRect: NSRect, within contentRect: NSRect) -> Bool {
            rect.width > 0 && rect.height > 0
                && rect.minX >= sidebarRect.maxX - 1 && rect.maxX <= contentRect.maxX + 1
                && rect.minY >= contentRect.minY - 1 && rect.maxY <= contentRect.maxY + 1
        }
        var optionTrailingEdge: CGFloat?
        func verifySettingsOptionLayout(within detailRect: NSRect) {
            let frames = settingsControls().map { $0.convert($0.bounds, to: nil) }
            for frame in frames {
                expect(frame.width > 0 && frame.height > 0 && detailRect.insetBy(dx: -1, dy: -1).contains(frame), "native settings switches must remain inside the usable detail area")
                if let optionTrailingEdge {
                    expect(abs(frame.maxX - optionTrailingEdge) <= 1, "native settings switches must share a trailing column across categories")
                } else {
                    optionTrailingEdge = frame.maxX
                }
            }
            for (above, below) in zip(frames, frames.dropFirst()) {
                expect(above.minY > below.maxY, "native settings switches must occupy separate vertically ordered rows")
            }
        }
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            settingsWindow.appearance = NSAppearance(named: appearanceName)
            referenceWindow.appearance = NSAppearance(named: appearanceName)
            for pane in [SettingsViewController.Pane.synthesis, .completed, .synthesis, .completed] {
                settingsSplit.selectPane(pane)
                try await waitForSettingsRows(pane == .synthesis ? [automaticID, albumID] : [manualID])
                settingsRoot.layoutSubtreeIfNeeded()
                let contentRect = settingsWindow.contentLayoutRect
                expect(settingsWindow.title == "设置" && settingsWindow.frame == fixedSettingsFrame && contentRect == fixedSettingsContentRect, "repeated category and appearance changes must not move or resize settings")
                expect(!settingsSplit.splitViewItems[0].isCollapsed && abs(settingsSplit.splitViewItems[0].viewController.view.frame.width - SettingsViewController.sidebarWidth) <= 1, "settings sidebar must retain its visible fixed width")
                expect(settingsNavigation.selectedRow == (pane == .synthesis ? 0 : 1), "settings sidebar selection must follow programmatic category changes")
                let sidebarView = settingsSplit.splitView.arrangedSubviews[0]
                let detailView = settingsSplit.splitViewItems[1].viewController.view
                let sidebarRect = settingsSplit.splitView.convert(sidebarView.frame, to: nil)
                // AppKit may extend the detail background beneath the sidebar.
                // automaticallyAdjustsSafeAreaInsets defines the usable pane:
                // https://developer.apple.com/documentation/appkit/nssplitviewitem/automaticallyadjustssafeareainsets
                let detailRect = detailView.convert(detailView.safeAreaLayoutGuide.frame, to: nil)
                expect(detailRect.width > 0 && detailRect.height > 0, "settings detail containment must retain usable geometry")
                if !detailFitsContent(detailRect, beside: sidebarRect, within: contentRect) {
                    FileHandle.standardError.write(Data("Settings containment diagnostics: pane=\(pane) content=\(contentRect) allocatedSidebar=\(sidebarRect) usableDetail=\(detailRect) detailBackground=\(detailView.frame) safeAreaInsets=\(detailView.safeAreaInsets)\n".utf8))
                }
                expect(detailFitsContent(detailRect, beside: sidebarRect, within: contentRect), "settings detail's usable area must remain beside the sidebar and below the toolbar within the fixed window")
                expect(abs(sidebarRect.width - SettingsViewController.sidebarWidth) <= 1, "native split layout must allocate the fixed sidebar width")
                expect(settingsWindow.frame == fixedSettingsFrame && settingsWindow.contentLayoutRect == fixedSettingsContentRect, "settings presentation and layout must preserve the fixed window geometry")
                settingsNavigation.scrollRowToVisible(0)
                settingsRoot.layoutSubtreeIfNeeded()
                let firstRowRect = settingsNavigation.convert(settingsNavigation.rect(ofRow: 0), to: nil)
                expect(firstRowRect.maxY <= contentRect.maxY + 1, "native settings navigation must stay below the toolbar")
                verifySettingsNativeSidebar()
                verifySettingsOptionLayout(within: detailRect)
                expect(settingsControl(pane == .synthesis ? automaticID : manualID)?.state == (pane == .synthesis ? .on : .off), "native settings controls must track category-specific model values")
            }
            // Change only the isolated tables, never the user's global defaults.
            // Both sidebars must respond identically to every native row size.
            for rowSize in [NSTableView.RowSizeStyle.small, .medium, .large, .default] {
                settingsNavigation.rowSizeStyle = rowSize
                referenceNavigation.rowSizeStyle = rowSize
                settingsNavigation.reloadData()
                settingsNavigation.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<settingsNavigation.numberOfRows))
                settingsRoot.layoutSubtreeIfNeeded()
                verifySettingsNativeSidebar()
            }
        }
        settingsWindow.appearance = nil
        referenceWindow.appearance = nil
        referenceWindow.orderOut(nil)
        settingsWindow.toggleToolbarShown(nil)
        expect(settingsWindow.toolbar!.isVisible, "category navigation must remain visible when toolbar hiding is requested")
        settingsWindow.orderOut(nil)
        restoredSettings.window?.orderOut(nil)
        fallbackSettings.window?.orderOut(nil)
        pass("Native settings: shared AppKit sidebar metrics and unclipped icons, system Form controls, conditional album rows, independent preferences and fixed window layout")

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
        func rightClickMenu(_ collection: NSCollectionView, at index: Int) async throws -> NSMenu {
            let indexPath = IndexPath(item: index, section: 0)
            try await waitUntil { collection.item(at: indexPath)?.imageView?.image != nil }
            let thumbnailView = collection.item(at: indexPath)!.view as! ThumbnailItemView
            thumbnailView.layoutSubtreeIfNeeded()
            let imageFrame = thumbnailView.imageView!.frame
            let point = thumbnailView.convert(NSPoint(x: imageFrame.midX, y: imageFrame.midY), to: nil)
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
        let selectedMenu = try await rightClickMenu(menuCoordinator.collectionView!, at: pairIndex)
        expect(menuModel.selectedDownloadItemIDs == [pairID, photoID], "right click must restore the current multi-selection before building its menu")
        expect(menuSelections == [[pairID, photoID]], "opening the menu must publish selection exactly once")
        expect(selectedMenu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled), "download must leave eligible composition, Finder, import and deletion menu actions available")
        menuCoordinator.gridController!.applySelection([pairID])
        menuSelections = []
        let photoMenu = try await rightClickMenu(menuCoordinator.collectionView!, at: photoIndex)
        expect(menuModel.selectedDownloadItemIDs == [photoID] && menuSelections == [[photoID]], "right-clicking another item must atomically select it without publishing an empty selection")
        let photoActions = photoMenu.items.filter { !$0.isSeparatorItem }
        expect(!photoActions[0].isEnabled && photoActions.dropFirst().allSatisfy(\.isEnabled), "a standalone photo must retain Finder, Photos, album and deletion actions while downloading")
        menuModel.isProcessingDownloads = true
        let composingMenu = try await rightClickMenu(menuCoordinator.collectionView!, at: photoIndex)
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
        let pairMenu = try await rightClickMenu(pairMenuCoordinator.collectionView!, at: 0)
        expect(pairMenu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled), "queue actions must remain available for settled sources during download")
        menuModel.isProcessingDownloads = true
        let guardedPairMenu = try await rightClickMenu(pairMenuCoordinator.collectionView!, at: 0)
        expect(!guardedPairMenu.items[0].isEnabled, "queue menu composition must follow model eligibility when another composition is running")
        expect(guardedPairMenu.items.first { $0.title.contains("访达") }!.isEnabled, "queue Finder action must remain available during another composition")
        menuModel.isProcessingDownloads = false
        menuModel.isDownloading = false
        withExtendedLifetime(menuWindow) {}
        pass("right-click selection and eligible menu actions remain usable during downloads")

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
        for (row, section) in SidebarSection.allCases.enumerated() {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let iconView = cell.imageView,
                  let icon = iconView.image else {
                preconditionFailure("main navigation must retain native symbol cells")
            }
            expect(icon.isTemplate && iconView.contentTintColor != nil, "main navigation must retain its tintable template symbols")
            expect(icon.accessibilityDescription == section.title, "main-navigation symbols must retain their destination descriptions")
        }
        let selectedRow = table.rowView(atRow: 1, makeIfNecessary: true)!
        selectedRow.isEmphasized = true
        expect(selectedRow.isSelected && !selectedRow.isEmphasized, "focused navigation selection must retain the native neutral appearance")
        let field = NSTextField()
        sidebar.view.addSubview(field)
        expect(sidebarWindow.makeFirstResponder(field), "focus must leave sidebar")
        pass("sidebar native focus, selection and leaving focus; main navigation retains template symbols")

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
        expect((thumbnail.view.accessibilityValue() as? String)?.contains("正在合成") == true, "composition status must remain available to VoiceOver")
        expect(!descendants(thumbnail.view).compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue.contains("正在合成") }, "composition must not cover artwork with a text label")
        pass("filter recovery action and visible composition state")
        print("PASS: \(checks) UI/UX regression groups; no network, media deletion or Photos writes")
    }
}
