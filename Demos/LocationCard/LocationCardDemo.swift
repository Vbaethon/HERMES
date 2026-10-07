import AppKit
import MapKit

@main
@MainActor
final class LocationDemo: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private struct Sample {
        let name: String
        let detail: String
        let coordinate: MediaLocationCard.Coordinate?
        var fails = false
    }

    private let samples: [Sample] = [
        Sample(name: "国内示例", detail: "查看中文地点与地址", coordinate: .init(latitude: 31.3064, longitude: 120.7051)),
        Sample(name: "海外示例", detail: "查看系统的海外地址格式", coordinate: .init(latitude: 37.3349, longitude: -122.0090)),
        Sample(name: "解析失败", detail: "地图和失败提示仍在同一张卡片", coordinate: .init(latitude: 31.3064, longitude: 120.7051), fails: true),
        Sample(name: "无位置信息", detail: "整张位置卡片一同隐藏", coordinate: nil)
    ]
    private var window: NSWindow!
    private let card = MediaLocationCard()
    private let table = NSTableView()
    private let sampleName = NSTextField(wrappingLabelWithString: "国内示例")
    private let locationHeading = NSTextField(labelWithString: "位置")
    private let inspector = NSView()
    private let inspectorStack = NSStackView()
    private var inspectorWidth: NSLayoutConstraint!
    private var appearanceControl: NSSegmentedControl!

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = LocationDemo()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        if CommandLine.arguments.contains("--self-test") {
            window.orderOut(nil)
            Task { @MainActor in
                do {
                    try await self.checkBindingAndLayout()
                    print("PASS: location binding, late response, no-GPS clearing, wrapping and appearances")
                    NSApp.terminate(nil)
                } catch {
                    print("FAIL: \(error)")
                    exit(1)
                }
            }
        } else {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 HERMES 位置 Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "HERMES 位置 Demo"
        window.minSize = NSSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        window.center()
        let root = NSView()
        window.contentView = root

        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 16
        controls.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        controls.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(wrappingLabelWithString: "查看位置信息")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "选择示例，查看地图与文字如何一起显示。")
        subtitle.textColor = .secondaryLabelColor
        controls.addArrangedSubview(title)
        controls.addArrangedSubview(subtitle)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Sample"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 58
        table.style = .inset
        table.allowsEmptySelection = false
        table.setAccessibilityLabel("位置展示示例")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        controls.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 254).isActive = true

        let sizingLabel = NSTextField(labelWithString: "检查器宽度")
        sizingLabel.textColor = .secondaryLabelColor
        controls.addArrangedSubview(sizingLabel)
        let sizing = NSSegmentedControl(labels: ["280", "320", "400"], trackingMode: .selectOne,
            target: self, action: #selector(changeWidth(_:)))
        sizing.selectedSegment = 1
        sizing.setAccessibilityLabel("检查器宽度")
        controls.addArrangedSubview(sizing)
        appearanceControl = NSSegmentedControl(labels: ["系统", "浅色", "深色"], trackingMode: .selectOne,
            target: self, action: #selector(changeAppearance(_:)))
        appearanceControl.selectedSegment = 0
        appearanceControl.setAccessibilityLabel("Demo 外观")
        controls.addArrangedSubview(appearanceControl)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        inspector.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(controls)
        root.addSubview(divider)
        root.addSubview(inspector)
        inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controls.topAnchor.constraint(equalTo: root.topAnchor),
            controls.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspector.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: root.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspectorWidth,
            scroll.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -48),
            subtitle.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -48)
        ])

        inspectorStack.orientation = .vertical
        inspectorStack.alignment = .leading
        inspectorStack.spacing = 10
        inspectorStack.translatesAutoresizingMaskIntoConstraints = false
        inspector.addSubview(inspectorStack)
        let infoHeading = NSTextField(labelWithString: "信息")
        infoHeading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        sampleName.font = .systemFont(ofSize: NSFont.systemFontSize)
        let sampleDescription = NSTextField(wrappingLabelWithString: "照片 · 位置展示示例")
        sampleDescription.textColor = .secondaryLabelColor
        let gap = NSView()
        gap.heightAnchor.constraint(equalToConstant: 10).isActive = true
        locationHeading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        [infoHeading, sampleName, sampleDescription, gap, locationHeading, card].forEach {
            inspectorStack.addArrangedSubview($0)
        }
        NSLayoutConstraint.activate([
            inspectorStack.leadingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: 16),
            inspectorStack.trailingAnchor.constraint(equalTo: inspector.trailingAnchor, constant: -16),
            inspectorStack.topAnchor.constraint(equalTo: inspector.topAnchor, constant: 20),
            sampleName.widthAnchor.constraint(equalTo: inspectorStack.widthAnchor),
            card.widthAnchor.constraint(equalTo: inspectorStack.widthAnchor)
        ])
    }

    func numberOfRows(in tableView: NSTableView) -> Int { samples.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let name = NSTextField(labelWithString: samples[row].name)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let detail = NSTextField(wrappingLabelWithString: samples[row].detail)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        [name, detail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview($0)
        }
        cell.textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 9),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard samples.indices.contains(table.selectedRow) else { return }
        let sample = samples[table.selectedRow]
        sampleName.stringValue = sample.name
        locationHeading.isHidden = sample.coordinate == nil
        card.show(sample.coordinate, simulateFailure: sample.fails)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func changeWidth(_ sender: NSSegmentedControl) {
        inspectorWidth.constant = [CGFloat(280), 320, 400][sender.selectedSegment]
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func changeAppearance(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1: window.appearance = NSAppearance(named: .aqua)
        case 2: window.appearance = NSAppearance(named: .darkAqua)
        default: window.appearance = nil
        }
    }

    private struct CheckError: Error { let message: String }

    private func checkBindingAndLayout() async throws {
        let a = samples[0].coordinate!
        let b = samples[1].coordinate!
        // Deliberately let a cancelled provider deliver a late result.
        let probe = MediaLocationCard { coordinate in
            if coordinate == a {
                try? await Task.sleep(for: .milliseconds(120))
                return .init(title: "旧地点", address: "旧地址")
            }
            try? await Task.sleep(for: .milliseconds(20))
            return .init(title: "新地点", address: "一条足够长的系统格式地址，用于检查窄检查器中的换行和完整显示")
        }
        inspectorStack.addArrangedSubview(probe)
        probe.widthAnchor.constraint(equalTo: inspectorStack.widthAnchor).isActive = true
        card.isHidden = true
        probe.show(a)
        try await Task.sleep(for: .milliseconds(5))
        probe.show(b)
        try await Task.sleep(for: .milliseconds(160))
        guard probe.coordinate == b, probe.displayedTitle == "新地点",
              probe.mapView.annotations.count == 1,
              probe.mapView.annotations.first?.coordinate.latitude == b.latitude,
              probe.resolutionSucceeded else {
            throw CheckError(message: "Late geocoding response mismatched the selected pin and text")
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for width in [CGFloat(280), 320, 400] {
                inspectorWidth.constant = width
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
                for field in probe.textFields {
                    let rect = field.convert(field.bounds, to: probe)
                    guard rect.minX >= 0, rect.maxX <= probe.bounds.width + 0.5,
                          field.frame.height + 0.5 >= field.fittingSize.height else {
                        throw CheckError(message: "Caption clipped at inspector width \(width)")
                    }
                }
            }
        }
        probe.show(a, simulateFailure: true)
        guard !probe.resolutionSucceeded, probe.displayedTitle == "拍摄位置",
              probe.displayedAddress == "暂时无法获取地点名称",
              probe.mapView.annotations.first?.coordinate.latitude == a.latitude else {
            throw CheckError(message: "Failure state retained an old place")
        }
        probe.show(nil)
        guard probe.isHidden, probe.coordinate == nil, probe.mapView.annotations.isEmpty,
              probe.displayedTitle.isEmpty, probe.displayedAddress == nil else {
            throw CheckError(message: "No-GPS state retained a previous location")
        }
    }
}
