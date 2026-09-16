import AppKit

final class SettingsWindowController: NSWindowController {
    init() {
        let controller = SettingsViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = "设置"
        window.setContentSize(NSSize(width: 460, height: 260))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class SettingsViewController: NSViewController {
    private let importToPhotosButton = NSButton(checkboxWithTitle: "合成后自动导入“照片”", target: nil, action: nil)
    private let addToAlbumButton = NSButton(checkboxWithTitle: "导入时加入 HERMES 相簿", target: nil, action: nil)
    private let completedAddToAlbumButton = NSButton(checkboxWithTitle: "从“已完成”导入时加入 HERMES 相簿", target: nil, action: nil)

    override func loadView() {
        view = SystemWindowBackgroundController.makePageBackgroundView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        let item = NSTabViewItem(identifier: "general")
        item.label = "通用"
        item.view = makeGeneralPane()
        tabView.addTabViewItem(item)
        view.addSubview(tabView)

        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            tabView.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            tabView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18)
        ])

        reloadFromDefaults()
    }

    private func makeGeneralPane() -> NSView {
        let contentView = NSView()
        let stackView = NSStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 10
        stackView.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        for button in [importToPhotosButton, addToAlbumButton, completedAddToAlbumButton] {
            button.target = self
            button.action = #selector(toggleChanged(_:))
            stackView.addArrangedSubview(button)
        }

        contentView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor)
        ])
        return contentView
    }

    private func reloadFromDefaults() {
        let defaults = UserDefaults.standard
        let importToPhotos = defaults.object(forKey: AppPreferenceKey.importToPhotos) as? Bool ?? true
        importToPhotosButton.state = importToPhotos ? .on : .off
        addToAlbumButton.state = (defaults.object(forKey: AppPreferenceKey.addToAlbum) as? Bool ?? false) ? .on : .off
        addToAlbumButton.isEnabled = importToPhotos
        completedAddToAlbumButton.state = (defaults.object(forKey: AppPreferenceKey.completedAddToAlbum) as? Bool ?? false) ? .on : .off
        completedAddToAlbumButton.isEnabled = importToPhotos
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        let defaults = UserDefaults.standard
        if sender === importToPhotosButton {
            let enabled = sender.state == .on
            defaults.set(enabled, forKey: AppPreferenceKey.importToPhotos)
            if !enabled {
                defaults.set(false, forKey: AppPreferenceKey.addToAlbum)
                defaults.set(false, forKey: AppPreferenceKey.completedAddToAlbum)
            }
        } else if sender === addToAlbumButton {
            defaults.set(sender.state == .on, forKey: AppPreferenceKey.addToAlbum)
        } else if sender === completedAddToAlbumButton {
            defaults.set(sender.state == .on, forKey: AppPreferenceKey.completedAddToAlbum)
        }
        reloadFromDefaults()
    }
}
