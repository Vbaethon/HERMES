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

    static func chooseDewuDataRoot() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择得物数据文件夹"
        panel.message = "请选择得物容器里的 Data 文件夹，用于读取本机日志中的 Live Photo 视频记录。"
        panel.prompt = "授权"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
        return panel.runModal() == .OK ? panel.url?.standardizedFileURL : nil
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

