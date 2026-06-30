import AppKit

enum SystemWindowBackgroundController {
    static func configureMainWindow(_ window: NSWindow) {
        window.toolbarStyle = .unified
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
    }

    static func makePageBackgroundView() -> NSView {
        SystemPageBackgroundView()
    }
}

final class SystemPageBackgroundView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
