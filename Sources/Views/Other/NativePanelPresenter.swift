import AppKit

@MainActor
enum NativePanelPresenter {
    enum DestructiveConfirmationChoice {
        case primary
        case deleteFiles
        case cancel
    }

    static func chooseImportURLs() -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = "选择照片、视频或文件夹"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.urls : nil
    }

    static func chooseOutputParentFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择新的导出位置"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    static func chooseDownloadOutputFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择下载文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
    }

    /// Trigger macOS native TCC privacy prompt by directly reading the Dewu database.
    /// macOS shows "App wants to access data from other apps" — user clicks Allow.
    static func authorizeDewuDataRootIfNeeded() -> Bool {
        guard !DewuLogStore.hasDataRootAccess() else { return true }

        guard let candidate = DewuLogStore.dataRoots().first else { return false }
        let dbDir = candidate.appendingPathComponent(
            "Library/DUCaches/logger/sqlite3/never/com.shizhuang.Logger.v2",
            isDirectory: true
        )
        guard let enumerator = FileManager.default.enumerator(
            at: dbDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        // Walk into a date subdirectory and read a .db file to trigger TCC
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent.hasSuffix(".db"),
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            _ = try? handle.readToEnd()
            try? handle.close()
            return DewuLogStore.authorizeDataRoot(candidate)
        }
        return false
    }

    static func presentDestructiveConfirmation(
        in window: NSWindow?,
        title: String,
        message: String,
        primaryButtonTitle: String,
        completion: @escaping (DestructiveConfirmationChoice) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: primaryButtonTitle)
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
                completion(.primary)
            case .alertSecondButtonReturn:
                completion(.deleteFiles)
            default:
                completion(.cancel)
            }
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }
}

