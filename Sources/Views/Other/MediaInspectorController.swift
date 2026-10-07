import AppKit

/// A continuous native AppKit inspector form with one scrolling document.
@MainActor
final class MediaInspectorController: NSViewController {
    let scrollView = NSScrollView()
    private let documentView = NSView()
    private let documentStack = NSStackView()
    private let messageField = NSTextField(wrappingLabelWithString: "选择一个项目以查看信息")
    private let model: ImporterModel
    private let inspectorFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var isUpdatingFormLayout = false
    private var formLayoutUpdateScheduled = false
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var currentRequest: MediaInspection.Request?
    private var currentRevision: String?
    private var lastLayoutSize: NSSize?
    private var formNeedsLayout = true
    private var isScrolledToTop = true
    private var paneTransitionCount = 0
    private var sectionContainers: [MediaInspection.Section: NSStackView] = [:]
    private var locationCard: MediaLocationCard?
    private let locationResolver: MediaLocationCard.Resolver?
    private let inspectionCache: NSCache<InspectionCacheKey, InspectionCacheSnapshot> = {
        let cache = NSCache<InspectionCacheKey, InspectionCacheSnapshot>()
        cache.countLimit = 64
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()
    var isPaneTransitioning: Bool { paneTransitionCount > 0 }
    var isLoading: Bool { loadTask != nil }
    private(set) var sectionGrids: [MediaInspection.Section: NSGridView] = [:]
    private(set) var rows: [MediaInspection.Row] = []
    private(set) var location: MediaInspection.Location?
    private(set) var statusText = "选择一个项目以查看信息"
    var isInspectionEnabled = false {
        didSet {
            guard oldValue != isInspectionEnabled else { return }
            if isInspectionEnabled {
                reload()
                locationCard?.resumeResolution()
            } else {
                cancelPendingLoad()
                locationCard?.cancelResolution()
            }
        }
    }

    init(model: ImporterModel, locationResolver: MediaLocationCard.Resolver? = nil) {
        self.model = model
        self.locationResolver = locationResolver
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // NSSplitViewItem's inspector behavior supplies the system glass.
        // A legacy sidebar material here obscures it and adds another backdrop.
        view = NSView()
        documentStack.orientation = .vertical
        documentStack.alignment = .leading
        documentStack.spacing = 20
        documentStack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        documentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.autoresizingMask = [.width]
        documentView.addSubview(documentStack)
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        messageField.translatesAutoresizingMaskIntoConstraints = false
        messageField.font = inspectorFont
        messageField.alignment = .center
        messageField.textColor = .secondaryLabelColor
        view.addSubview(scrollView)
        view.addSubview(messageField)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            documentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            documentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            documentStack.widthAnchor.constraint(equalTo: documentView.widthAnchor),
            messageField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            messageField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            messageField.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        showMessage(statusText)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateFormLayout()
    }

    @objc private func clipViewFrameDidChange(_ notification: Notification) {
        guard !formLayoutUpdateScheduled else { return }
        formLayoutUpdateScheduled = true
        // Legacy scrollers change the clip width after its parent's layout.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.formLayoutUpdateScheduled = false
            self.updateFormLayout()
        }
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard !isUpdatingFormLayout, !isPaneTransitioning,
              lastLayoutSize == scrollView.contentSize else { return }
        isScrolledToTop = abs(scrollView.contentView.bounds.maxY - documentView.bounds.height) < 0.5
    }

    private func clearForm() {
        documentStack.arrangedSubviews.forEach {
            documentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        sectionGrids.removeAll()
        sectionContainers.removeAll()
        locationCard?.show(nil)
        locationCard = nil
        formNeedsLayout = true
    }

    private func fields(for row: MediaInspection.Row) -> [NSView] {
        let key = NSTextField(wrappingLabelWithString: row.key)
        key.font = inspectorFont
        key.textColor = .secondaryLabelColor
        key.alignment = .right
        let value = NSTextField(wrappingLabelWithString: row.value)
        value.font = inspectorFont
        value.isSelectable = true
        value.toolTip = row.value
        for field in [key, value] {
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byCharWrapping
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        return [key, value]
    }

    private func updateForm() {
        for kind in MediaInspection.Section.allCases {
            let sectionRows = rows.filter { $0.section == kind }
            // Every section requires actual content, regardless of file kind,
            // metadata format, loading state or whether this is a cached load.
            guard !sectionRows.isEmpty || (kind == .location && location != nil) else {
                removeSection(kind)
                continue
            }
            if kind == .location {
                updateLocationSection()
                continue
            }
            if let grid = sectionGrids[kind] {
                for (index, row) in sectionRows.enumerated() {
                    if let existing = (0..<grid.numberOfRows).first(where: {
                        (grid.cell(atColumnIndex: 0, rowIndex: $0).contentView as? NSTextField)?.stringValue == row.key
                    }) {
                        if existing != index { grid.moveRow(at: existing, to: index) }
                        let value = grid.cell(atColumnIndex: 1, rowIndex: index).contentView as! NSTextField
                        if value.stringValue != row.value { value.stringValue = row.value }
                        value.toolTip = row.value
                    } else {
                        grid.insertRow(at: index, with: fields(for: row))
                    }
                }
                while grid.numberOfRows > sectionRows.count {
                    let index = grid.numberOfRows - 1
                    let removedViews = (0..<grid.numberOfColumns).compactMap {
                        grid.cell(atColumnIndex: $0, rowIndex: index).contentView
                    }
                    grid.removeRow(at: index)
                    // Removing an NSGridView row releases its placement
                    // constraints but leaves its content views in the grid.
                    // Detach them so a reused form cannot draw obsolete text.
                    removedViews.forEach { $0.removeFromSuperview() }
                }
                continue
            }
            let grid = NSGridView(views: sectionRows.map(fields(for:)))
            grid.columnSpacing = 12
            grid.rowSpacing = 8
            grid.xPlacement = .fill
            grid.yPlacement = .top
            grid.rowAlignment = .firstBaseline
            grid.column(at: 0).width = 100
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.setAccessibilityLabel("\(kind.title)详细信息")
            let container = sectionContainers[kind] ?? makeSectionContainer(kind)
            container.addArrangedSubview(grid)
            sectionGrids[kind] = grid
            grid.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
        formNeedsLayout = true
    }

    private func removeSection(_ kind: MediaInspection.Section) {
        if let container = sectionContainers.removeValue(forKey: kind) {
            documentStack.removeArrangedSubview(container)
            container.removeFromSuperview()
        }
        sectionGrids.removeValue(forKey: kind)
        if kind == .location {
            locationCard?.show(nil)
            locationCard = nil
        }
    }

    private func makeSectionContainer(_ kind: MediaInspection.Section) -> NSStackView {
        let label = NSTextField(labelWithString: kind.title)
        label.font = NSFont.systemFont(ofSize: inspectorFont.pointSize, weight: .semibold)
        let container = NSStackView(views: [label])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false
        let index = MediaInspection.Section.allCases.prefix { $0 != kind }
            .filter { sectionContainers[$0] != nil }.count
        documentStack.insertArrangedSubview(container, at: index)
        sectionContainers[kind] = container
        container.widthAnchor.constraint(equalTo: documentStack.widthAnchor, constant: -32).isActive = true
        return container
    }

    private func updateLocationSection() {
        guard let location else { return }
        let container = sectionContainers[.location] ?? makeSectionContainer(.location)
        let card: MediaLocationCard
        if let existing = locationCard {
            card = existing
        } else {
            card = MediaLocationCard(resolver: locationResolver)
            card.onContentChange = { [weak self, weak card] in
                guard let self, self.locationCard === card else { return }
                self.formNeedsLayout = true
                self.updateFormLayout()
            }
            locationCard = card
        }
        card.show(.init(latitude: location.latitude, longitude: location.longitude))
        guard container.arrangedSubviews.last !== card else { return }
        for old in container.arrangedSubviews.dropFirst() {
            container.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        container.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func display(_ result: MediaInspection.Snapshot, isComplete: Bool) {
        rows = result.inspectorRows
        location = result.location
        statusText = isComplete ? "" : "正在读取文件信息…"
        messageField.isHidden = true
        documentStack.isHidden = false
        updateForm()
        updateFormLayout()
        scrollToTop()
    }

    private func updateFormLayout() {
        guard !isUpdatingFormLayout, !isPaneTransitioning, isInspectionEnabled,
              !view.isHiddenOrHasHiddenAncestor else { return }
        let size = scrollView.contentSize
        // A collapsing split passes through very narrow widths. Do not wrap
        // every value into a tall one-character column on those frames.
        guard size.width >= 240, size.height > 0,
              formNeedsLayout || lastLayoutSize != size else { return }
        isUpdatingFormLayout = true
        defer { isUpdatingFormLayout = false }
        formNeedsLayout = false
        lastLayoutSize = size
        // NSClipView can adjust its bounds before a resize finishes. Preserve
        // the user's preceding scroll position, not that intermediate geometry.
        let wasAtTop = isScrolledToTop
        let width = size.width
        documentView.setFrameSize(NSSize(width: width, height: max(documentView.frame.height, scrollView.contentSize.height)))
        let valueWidth = max(1, width - 32 - 100 - 12)
        for grid in sectionGrids.values {
            for row in 0..<grid.numberOfRows {
                for column in 0..<2 {
                    guard let field = grid.cell(atColumnIndex: column, rowIndex: row).contentView as? NSTextField else { continue }
                    let preferredWidth = column == 0 ? CGFloat(100) : valueWidth
                    if field.preferredMaxLayoutWidth != preferredWidth {
                        field.preferredMaxLayoutWidth = preferredWidth
                        field.invalidateIntrinsicContentSize()
                    }
                }
            }
        }
        documentView.layoutSubtreeIfNeeded()
        documentView.setFrameSize(NSSize(width: width, height: max(scrollView.contentSize.height, documentStack.fittingSize.height)))
        documentView.layoutSubtreeIfNeeded()
        if wasAtTop { scrollToTop() }
    }

    private func scrollToTop() {
        isScrolledToTop = true
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, documentView.bounds.height - scrollView.contentSize.height)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func reload(force: Bool = false) {
        guard isInspectionEnabled, !isPaneTransitioning else { return }
        _ = view
        let count: Int
        switch model.selection ?? .queue {
        case .queue: count = model.selectedPairIDs.count
        case .downloads: count = model.selectedDownloadItemIDs.count
        case .completed: count = model.selectedCompletedIDs.count
        }
        guard count == 1 else {
            cancelLoad()
            currentRequest = nil
            currentRevision = nil
            showMessage(count > 1 ? "已选择多个项目，\n请选择一个项目查看信息。" : "选择一个项目以查看信息")
            return
        }
        guard let request = inspectionRequest else {
            cancelLoad()
            currentRequest = nil
            currentRevision = nil
            showMessage("所选项目已不可用")
            return
        }
        let revision = MediaInspection.revision(for: request)
        guard force || request != currentRequest || revision != currentRevision else { return }
        cancelLoad()
        currentRequest = request
        currentRevision = revision
        let cacheKey = InspectionCacheKey(request: request, revision: revision)
        if !force, let cached = inspectionCache.object(forKey: cacheKey) {
            display(cached.snapshot, isComplete: true)
            return
        }
        display(.init(rows: MediaInspection.preview(request)), isComplete: false)
        let token = generation
        loadTask = Task { [weak self] in
            let result = await MediaInspection.loadSnapshot(request)
            guard !Task.isCancelled, let self, self.generation == token, self.isInspectionEnabled else { return }
            guard MediaInspection.revision(for: request) == revision else {
                self.reload(force: true)
                return
            }
            self.loadTask = nil
            let cached = InspectionCacheSnapshot(result)
            self.inspectionCache.setObject(cached, forKey: cacheKey, cost: cached.cost)
            self.display(result, isComplete: true)
        }
    }

    private func cancelLoad() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
    }

    private func cancelPendingLoad() {
        guard loadTask != nil else { return }
        cancelLoad()
        currentRequest = nil
        currentRevision = nil
    }

    func beginPaneTransition() {
        paneTransitionCount += 1
        cancelPendingLoad()
        locationCard?.cancelResolution()
    }

    func endPaneTransition() {
        paneTransitionCount = max(0, paneTransitionCount - 1)
        guard !isPaneTransitioning else { return }
        reload()
        locationCard?.resumeResolution()
        updateFormLayout()
    }

    private func showMessage(_ text: String) {
        guard statusText != text || !rows.isEmpty || location != nil || messageField.isHidden || !documentStack.isHidden else { return }
        rows = []
        location = nil
        statusText = text
        messageField.stringValue = text
        messageField.isHidden = false
        documentStack.isHidden = true
        clearForm()
        updateFormLayout()
    }

    private var inspectionRequest: MediaInspection.Request? {
        switch model.selection ?? .queue {
        case .queue:
            guard let item = model.selectedPairs.first else { return nil }
            let state: String
            switch item.status {
            case .waiting: state = "未合成"
            case .running: state = "合成中"
            case .finished: state = "已合成"
            case .failed: state = "合成失败"
            }
            return .init(name: item.imageURL.deletingPathExtension().lastPathComponent,
                sourceURLs: [item.imageURL, item.videoURL], displayedURLs: [item.imageURL, item.videoURL],
                kind: "Live Photo 配对", compositionState: state)
        case .downloads:
            guard let item = model.visibleDownloadItems.first(where: { model.selectedDownloadItemIDs.contains($0.id) }) else { return nil }
            let urls: [URL]
            switch item.kind {
            case .pair(let pairID):
                guard let pair = model.downloadPairs.first(where: { $0.id == pairID }) else { return nil }
                urls = [pair.imageURL, pair.videoURL]
            case .photo, .video: urls = [item.imageURL]
            }
            let kind = item.mediaKind == .livePhoto ? "Live Photo 配对" : (item.mediaKind == .video ? "视频" : "照片")
            let state = item.mediaKind == .livePhoto ? (item.isCompleted ? "已合成" : (item.status == .running ? "合成中" : "未合成")) : "不适用"
            return .init(name: item.imageURL.lastPathComponent, sourceURLs: urls, displayedURLs: urls,
                kind: kind, compositionState: state)
        case .completed:
            guard let item = model.selectedCompletedItems.first else { return nil }
            let outputs = [item.imageURL] + (item.movieURL.map { [$0] } ?? [])
            let sources = [item.sourceImagePath, item.sourceVideoPath].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
            let kind = item.mediaKind == .livePhoto ? "Live Photo" : (item.mediaKind == .video ? "视频" : "照片")
            let hasCompositionRecord = item.movieURL != nil && item.sourceImagePath != nil && item.sourceVideoPath != nil
            let currentOutput = item.outputIsCurrent
            let currentSource = sources.count == 2 && item.sourceRevision != nil
                && item.sourceRevision == MediaPairRevision(image: sources[0], movie: sources[1])
            // Paths can be reused for another post. Only matching revisions
            // establish that these source files still belong to this output.
            let evidence = hasCompositionRecord ? (currentSource && currentOutput ? sources : []) : outputs
            return .init(name: item.imageURL.lastPathComponent, sourceURLs: evidence,
                displayedURLs: outputs, kind: kind,
                compositionState: item.movieURL == nil ? "不适用" : (hasCompositionRecord
                    ? (currentOutput ? "已合成" : "文件已变化，合成状态待确认") : "未记录合成状态"),
                isCompositionOutput: hasCompositionRecord && currentOutput, importedToPhotos: item.importedToPhotos)
        }
    }

}

private final class InspectionCacheKey: NSObject {
    let request: MediaInspection.Request
    let revision: String

    init(request: MediaInspection.Request, revision: String) {
        self.request = request
        self.revision = revision
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(request)
        hasher.combine(revision)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? InspectionCacheKey else { return false }
        return request == other.request && revision == other.revision
    }
}

private final class InspectionCacheSnapshot: NSObject {
    let snapshot: MediaInspection.Snapshot
    var cost: Int { snapshot.rows.reduce(32) { $0 + $1.key.utf8.count + $1.value.utf8.count } }
    init(_ snapshot: MediaInspection.Snapshot) { self.snapshot = snapshot }
}
