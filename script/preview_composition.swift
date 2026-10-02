import AppKit

/// Offline native preview using the production collection and thumbnail cells. Read sample paths from
/// the preview bundle's samples.json; this executable never creates an ImporterModel.
@main @MainActor
final class CompositionPreview: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let grid = ThumbnailGridController()
    private var items: [ThumbnailGridItem] = []
    private var running = true
    private var fastCompletion: Task<Void, Never>?

    static func main() {
        let app = NSApplication.shared
        let delegate = CompositionPreview()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let data = try! Data(contentsOf: Bundle.main.url(forResource: "samples", withExtension: "json")!)
        let paths = try! JSONDecoder().decode([String].self, from: data)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "HERMES · 合成效果预览"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let title = NSTextField(labelWithString: "缩略图的颜色，缓缓流动")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        title.frame = NSRect(x: 32, y: 350, width: 680, height: 34)
        content.addSubview(title)
        let note = NSTextField(labelWithString: "点击完成，查看缩略图恢复。")
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 32, y: 321, width: 680, height: 22)
        content.addSubview(note)
        let scroll = NSScrollView(frame: NSRect(x: 90, y: 112, width: 610, height: 184))
        ThumbnailCollectionStyle.prepare(scroll, documentView: grid.nsCollectionView)
        content.addSubview(scroll)
        items = paths.prefix(3).enumerated().map { index, path in
            ThumbnailGridItem(id: "sample-\(index)", url: URL(fileURLWithPath: path),
                              status: .running, mediaKind: .livePhoto, contentVersion: 1)
        }
        grid.updateItems(items, animatingDifferences: false)
        let button = NSButton(title: "合成完成", target: self, action: #selector(toggle(_:)))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 225, y: 55, width: 150, height: 36)
        content.addSubview(button)
        let fastButton = NSButton(title: "快速合成（0.1 秒）", target: self, action: #selector(runFastCompletion))
        fastButton.bezelStyle = .rounded
        fastButton.frame = NSRect(x: 400, y: 55, width: 180, height: 36)
        content.addSubview(fastButton)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func toggle(_ sender: NSButton) {
        fastCompletion?.cancel()
        running.toggle()
        updateStatus(running ? .running : .finished)
        sender.title = running ? "合成完成" : "重新预览"
    }

    @objc private func runFastCompletion() {
        fastCompletion?.cancel()
        running = true
        updateStatus(.running)
        fastCompletion = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            self?.running = false
            self?.updateStatus(.finished)
        }
    }

    private func updateStatus(_ status: PairItem.Status) {
        grid.updateItems(items.map { ThumbnailGridItem(id: $0.id, url: $0.url, status: status,
            mediaKind: $0.mediaKind, contentVersion: $0.contentVersion) })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
