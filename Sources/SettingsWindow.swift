import AppKit
import SwiftUI

private final class SettingsWindow: NSWindow {
    override func toggleToolbarShown(_ sender: Any?) {}
    override func miniaturize(_ sender: Any?) {}
    override func performMiniaturize(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleToolbarShown(_:)) || item.action == #selector(performMiniaturize(_:)) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleToolbarShown(_:)) || menuItem.action == #selector(performMiniaturize(_:)) {
            return false
        }
        return super.validateMenuItem(menuItem)
    }
}

final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    init(model: ImporterModel, defaults: UserDefaults = .standard) {
        let controller = SettingsViewController(model: model, defaults: defaults)
        let window = SettingsWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = "设置"
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .disallowed
        window.showsToolbarButton = false
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "HermesSettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        window.setContentSize(SettingsViewController.contentSize)
        controller.splitView.setPosition(SettingsViewController.sidebarWidth, ofDividerAt: 0)
        window.center()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == .sidebarTrackingSeparator,
              let controller = contentViewController as? NSSplitViewController else { return nil }
        return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: controller.splitView, dividerIndex: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class SettingsViewController: NSSplitViewController {
    static let selectedPanePreferenceKey = "SettingsSelectedPane.v1"
    static let contentSize = NSSize(width: 760, height: 460)
    static let sidebarWidth: CGFloat = 220

    enum Pane: String, CaseIterable, SidebarDestination {
        case synthesis, completed

        var title: String { self == .synthesis ? "合成与导入" : "已完成" }
        var symbolName: String {
            self == .synthesis ? AppSymbol.composeLivePhoto.normal : AppSymbol.completed.normal
        }
    }

    private let model: ImporterModel
    private let defaults: UserDefaults
    private(set) var selectedPane: Pane
    private lazy var sidebar = NativeSidebarController<Pane>(
        sections: Pane.allCases,
        selection: selectedPane,
        count: { _ in nil },
        accessibilityLabel: "设置分类",
        onSelect: { [weak self] pane in self?.selectPane(pane) }
    )
    private lazy var detail = NSHostingController(rootView: SettingsPaneView(model: model, pane: selectedPane))

    init(model: ImporterModel, defaults: UserDefaults) {
        self.model = model
        self.defaults = defaults
        selectedPane = defaults.string(forKey: Self.selectedPanePreferenceKey).flatMap(Pane.init(rawValue:)) ?? .synthesis
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        // Reuse the main window's source list, including system row-size
        // preferences and AppKit's automatic scroll-view titlebar insets.
        let navigation = sidebar.makeSplitViewItem()
        navigation.minimumThickness = Self.sidebarWidth
        navigation.maximumThickness = Self.sidebarWidth
        navigation.canCollapse = false
        navigation.canCollapseFromWindowResize = false
        addSplitViewItem(navigation)

        // AppKit owns the fixed window frame, title and toolbar. The hosting
        // controller contributes only the system-rendered grouped settings form.
        detail.sceneBridgingOptions = []
        detail.sizingOptions = []
        let content = NSSplitViewItem(viewController: detail)
        content.automaticallyAdjustsSafeAreaInsets = true
        addSplitViewItem(content)
    }

    func selectPane(_ pane: Pane) {
        guard pane != selectedPane else { return }
        selectedPane = pane
        defaults.set(pane.rawValue, forKey: Self.selectedPanePreferenceKey)
        sidebar.update(sections: Pane.allCases, selection: pane, count: { _ in nil })
        detail.rootView = SettingsPaneView(model: model, pane: pane)
        view.window?.recalculateKeyViewLoop()
    }
}

private struct SettingsPaneView: View {
    @ObservedObject var model: ImporterModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pane: SettingsViewController.Pane

    var body: some View {
        Form {
            Section(pane.title) {
                switch pane {
                case .synthesis:
                    Toggle(isOn: $model.importToPhotos) {
                        Label("合成后自动导入“照片”", systemImage: AppSymbol.importToPhotos.normal)
                    }
                    .help("将合成的 Live Photo 添加到“照片”图库。")
                    .accessibilityIdentifier("settings.importToPhotos")
                    if model.importToPhotos {
                        Toggle(isOn: $model.addToAlbum) {
                            Label("同时加入 HERMES 相簿", systemImage: AppSymbol.addToAlbum.normal)
                        }
                        .help("自动导入时，同时添加到 HERMES 相簿。")
                        .accessibilityIdentifier("settings.addToAlbum")
                    }
                case .completed:
                    Toggle(isOn: $model.completedAddToAlbum) {
                        Label("导入时加入 HERMES 相簿", systemImage: AppSymbol.addToAlbum.normal)
                    }
                    .help("从“已完成”导入时，同时添加到 HERMES 相簿。")
                    .accessibilityIdentifier("settings.completedAddToAlbum")
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .animation(reduceMotion ? nil : .default, value: model.importToPhotos)
    }
}
