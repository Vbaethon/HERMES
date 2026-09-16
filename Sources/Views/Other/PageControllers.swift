import AppKit
import Combine

@MainActor
protocol ThumbnailPageController: AnyObject {
    func setVisible(_ visible: Bool)
    func reload()
}

final class DetailPagesController: NSViewController {
    private let model: ImporterModel
    private let queueController: QueuePageController
    private let downloadController: DownloadPageController
    private let completedController: CompletedPageController
    private var activeSelection: SidebarSection?
    private let noticeButton = NSButton(title: "查看操作详情", target: nil, action: nil)
    private var noticeHeight: NSLayoutConstraint!
    private var cancellables = Set<AnyCancellable>()

    init(model: ImporterModel, startDownload: @escaping () -> Void) {
        self.model = model
        self.queueController = QueuePageController(model: model)
        self.downloadController = DownloadPageController(model: model, startDownload: startDownload)
        self.completedController = CompletedPageController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = SystemWindowBackgroundController.makePageBackgroundView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        noticeButton.target = self
        noticeButton.action = #selector(showOperationNotice)
        noticeButton.bezelStyle = .inline
        noticeButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        noticeButton.cell?.lineBreakMode = .byTruncatingTail
        noticeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noticeButton)
        noticeHeight = noticeButton.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            noticeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            noticeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            noticeButton.topAnchor.constraint(equalTo: view.topAnchor), noticeHeight
        ])
        for controller in [queueController, downloadController, completedController] {
            addChild(controller)
            let page = controller.view
            page.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                page.topAnchor.constraint(equalTo: noticeButton.bottomAnchor),
                page.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        for controller in thumbnailPageControllers {
            controller.setVisible(false)
        }
        reload()

        model.$selection
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        let selection = model.selection ?? .queue
        let notice = model.operationNotices[selection]
        noticeButton.isHidden = notice == nil
        noticeHeight?.constant = notice == nil ? 0 : 32
        noticeButton.title = notice.map { String(($0.components(separatedBy: "\n").first ?? "操作提示").prefix(48)) + " · 查看详情" } ?? "查看操作详情"
        noticeButton.setAccessibilityLabel(noticeButton.title)
        let selectionChanged = activeSelection != selection
        if selectionChanged {
            controller(for: activeSelection)?.setVisible(false)
            activeSelection = selection
        }
        switch selection {
        case .queue:
            queueController.reload()
        case .downloads:
            downloadController.reload()
        case .completed:
            completedController.reload()
        }
        if selectionChanged {
            controller(for: selection)?.setVisible(true)
        }
    }

    @objc private func showOperationNotice() {
        let page = model.selection ?? .queue
        guard let message = model.operationNotices[page], let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "操作详情"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.string = message
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "保留提示")
        alert.addButton(withTitle: "关闭提示")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.model.dismissOperationNotice(for: page) }
        }
    }

    private func controller(for selection: SidebarSection?) -> (any ThumbnailPageController)? {
        guard let selection else { return nil }
        switch selection {
        case .queue:
            return queueController
        case .downloads:
            return downloadController
        case .completed:
            return completedController
        }
    }

    private var thumbnailPageControllers: [any ThumbnailPageController] {
        [queueController, downloadController, completedController]
    }
}

private extension NSView {
    func addPinnedSubview(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: trailingAnchor),
            subview.topAnchor.constraint(equalTo: topAnchor),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

final class QueuePageController: NSViewController, ThumbnailPageController {
    private let model: ImporterModel
    private var scrollView: NSScrollView?
    private var coordinator: PairCollectionView.Coordinator?
    private let emptyView: DropZoneView
    private var cancellables = Set<AnyCancellable>()

    init(model: ImporterModel) {
        self.model = model
        self.emptyView = DropZoneView(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = SystemWindowBackgroundController.makePageBackgroundView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        let pair = PairCollectionView.make(
            items: model.pairs,
            model: model
        )
        scrollView = pair.0
        coordinator = pair.1
        pair.0.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(emptyView)
        view.addSubview(pair.0, positioned: .below, relativeTo: emptyView)

        NSLayoutConstraint.activate([
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pair.0.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pair.0.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pair.0.topAnchor.constraint(equalTo: view.topAnchor),
            pair.0.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        scrollView?.isHidden = model.pairs.isEmpty
        emptyView.isHidden = !model.pairs.isEmpty

        model.$pairs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func setVisible(_ visible: Bool) {
        view.isHidden = !visible
    }

    func reload() {
        if model.pairs.isEmpty {
            scrollView?.isHidden = true
            emptyView.isHidden = false
            emptyView.message = model.statusText
            return
        }
        emptyView.isHidden = true
        scrollView?.isHidden = false
        guard let scrollView, let coordinator else { return }
        PairCollectionView.update(
            scrollView: scrollView,
            coordinator: coordinator,
            items: model.pairs,
            model: model
        )
    }
}

final class CompletedPageController: NSViewController, ThumbnailPageController {
    private let model: ImporterModel
    private let emptyView = EmptyStateView(title: "还没有完成项目", symbolName: AppSymbol.completed.normal, message: "合成完成后会显示在这里。")
    private var scrollView: NSScrollView?
    private var coordinator: CompletedCollectionView.Coordinator?
    private var cancellables = Set<AnyCancellable>()

    init(model: ImporterModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = SystemWindowBackgroundController.makePageBackgroundView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        let pair = CompletedCollectionView.make(
            items: model.visibleCompleted,
            filter: model.completedFilter,
            model: model
        )
        scrollView = pair.0
        coordinator = pair.1
        pair.0.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(emptyView)
        view.addSubview(pair.0, positioned: .below, relativeTo: emptyView)

        NSLayoutConstraint.activate([
            emptyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pair.0.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pair.0.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pair.0.topAnchor.constraint(equalTo: view.topAnchor),
            pair.0.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        scrollView?.isHidden = model.completed.isEmpty
        emptyView.isHidden = !model.completed.isEmpty

        model.$completed
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)

        model.$completedFilter
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func setVisible(_ visible: Bool) {
        view.isHidden = !visible
    }

    func reload() {
        let visibleCompleted = model.visibleCompleted
        if visibleCompleted.isEmpty {
            scrollView?.isHidden = true
            emptyView.isHidden = false
            switch model.completedFilter {
            case .all:
                emptyView.message = "合成完成后会显示在这里。"
            case .notAdded:
                emptyView.message = "没有未导入的项目。"
            case .added:
                emptyView.message = "没有已导入的项目。"
            }
            return
        }
        emptyView.isHidden = true
        scrollView?.isHidden = false
        guard let scrollView, let coordinator else { return }
        CompletedCollectionView.update(
            scrollView: scrollView,
            coordinator: coordinator,
            items: visibleCompleted,
            filter: model.completedFilter,
            model: model
        )
    }
}
