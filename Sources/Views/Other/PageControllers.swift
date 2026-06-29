import AppKit
import Combine

final class ThemedBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

final class DetailPagesController: NSViewController {
    private let model: ImporterModel
    private let queueController: QueuePageController
    private let downloadController: DownloadPageController
    private let completedController: CompletedPageController
    private var cancellables = Set<AnyCancellable>()

    init(model: ImporterModel) {
        self.model = model
        self.queueController = QueuePageController(model: model)
        self.downloadController = DownloadPageController(model: model)
        self.completedController = CompletedPageController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let rootView = ThemedBackgroundView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        for controller in [queueController, downloadController, completedController] {
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
        reload()

        model.$selection
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    func reload() {
        let selection = model.selection ?? .queue
        queueController.setVisible(selection == .queue)
        downloadController.setVisible(selection == .downloads)
        completedController.setVisible(selection == .completed)
        switch selection {
        case .queue:
            queueController.reload()
        case .downloads:
            downloadController.reload()
        case .completed:
            completedController.reload()
        }
    }
}

final class QueuePageController: NSViewController {
    private let model: ImporterModel
    private var scrollView: NSScrollView?
    private var coordinator: PairCollectionView.Coordinator?
    private let emptyView: DropZoneView
    private var isVisible = false
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
        let rootView = ThemedBackgroundView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        let pair = PairCollectionView.make(
            items: model.pairs,
            model: model,
            scrollToTopRequestID: model.queueScrollToTopRequestID,
            isVisible: isVisible
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
        isVisible = visible
        view.isHidden = !visible
        coordinator?.scrollPosition.setActive(visible)
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
            model: model,
            scrollToTopRequestID: model.queueScrollToTopRequestID,
            isVisible: isVisible
        )
    }
}

final class CompletedPageController: NSViewController {
    private let model: ImporterModel
    private let emptyView = EmptyStateView(title: "还没有完成项目", symbolName: AppSymbol.completed.normal, message: "合成完成后会显示在这里。")
    private var scrollView: NSScrollView?
    private var coordinator: CompletedCollectionView.Coordinator?
    private var isVisible = false
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
        let rootView = ThemedBackgroundView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        let pair = CompletedCollectionView.make(
            items: model.visibleCompleted,
            filter: model.completedFilter,
            model: model,
            scrollToTopRequestID: model.completedScrollToTopRequestID,
            isVisible: isVisible
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
        isVisible = visible
        view.isHidden = !visible
        coordinator?.scrollPosition.setActive(visible)
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
            model: model,
            scrollToTopRequestID: model.completedScrollToTopRequestID,
            isVisible: isVisible
        )
    }
}
